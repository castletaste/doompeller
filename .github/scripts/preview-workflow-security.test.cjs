'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const repositoryRoot = path.resolve(__dirname, '../..');
const workflow = fs.readFileSync(
  path.join(repositoryRoot, '.github/workflows/deploy-pr-preview.yml'),
  'utf8',
);
const productionWorkflow = fs.readFileSync(
  path.join(repositoryRoot, '.github/workflows/deploy-web.yml'),
  'utf8',
);
const lockfile = JSON.parse(fs.readFileSync(
  path.join(repositoryRoot, '.github/preview-tools/package-lock.json'),
  'utf8',
));

test('publishes only successful PR runs through a trusted default-branch policy', () => {
  assert.match(workflow, /on:\s*\n\s*workflow_run:/);
  assert.match(workflow, /workflows:\s*\n\s*- Verify and deploy Doompeller web/);
  assert.doesNotMatch(workflow, /- Deploy Doompeller web/);
  assert.match(workflow, /github\.event\.workflow_run\.event == 'pull_request'/);
  assert.match(workflow, /github\.event\.workflow_run\.conclusion == 'success'/);
  assert.match(workflow, /workflow_id: 'deploy-web\.yml'/);
  assert.match(workflow, /expectedWorkflow[\s\S]*validatePreviewSource/);
  assert.equal(
    workflow.match(/ref: \$\{\{ github\.event\.repository\.default_branch \}\}/g)?.length,
    3,
  );
  assert.equal(workflow.match(/persist-credentials: false/g)?.length, 3);
});

test('shares deployment credentials only after unprivileged validation', () => {
  const validateJob = workflow.indexOf('\n  validate:');
  const deployJob = workflow.indexOf('\n  deploy:');
  assert.ok(validateJob >= 0);
  assert.ok(deployJob > validateJob);
  const validation = workflow.slice(validateJob, deployJob);
  const deployment = workflow.slice(deployJob);
  assert.doesNotMatch(validation, /environment:|secrets\.CLOUDFLARE_/);
  assert.match(deployment, /needs: validate/);
  assert.match(deployment, /environment:\s*\n\s*name: production\s*\n/);
  assert.match(deployment, /apiToken: \$\{\{ secrets\.CLOUDFLARE_API_TOKEN \}\}/);
  assert.match(deployment, /--branch=pr-\$\{\{ needs\.validate\.outputs\.pr_number \}\}/);
  assert.doesNotMatch(deployment, /--branch[= ]main\b/);
});

test('sanitizes the sole tar archive and preserves only its approved hidden file', () => {
  assert.match(
    workflow,
    /preview-artifact-policy\.cjs sanitize-archive[\s\S]*"\$SOURCE_DIRECTORY" "\$SANITIZED_DIRECTORY" "\$BUILD_SHA"/,
  );
  assert.match(workflow, /include-hidden-files: true/);
  assert.doesNotMatch(workflow, /\btar\s|\bunzip\s|npm (?:run|exec)|npx /);
  assert.equal(workflow.match(/digest-mismatch: error/g)?.length, 2);
});

test('installs locked Wrangler before any Cloudflare credential is referenced', () => {
  const installStep = workflow.indexOf(
    '- name: Install pinned Wrangler without deployment credentials',
  );
  const credential = workflow.indexOf('secrets.CLOUDFLARE_API_TOKEN');
  const deployAction = workflow.indexOf(
    'cloudflare/wrangler-action@ebbaa1584979971c8614a24965b4405ff95890e0',
  );
  assert.ok(installStep >= 0);
  assert.ok(credential > installStep);
  assert.ok(deployAction > installStep);
  assert.match(
    workflow.slice(installStep, deployAction),
    /working-directory: trusted-source\/\.github\/preview-tools[\s\S]*npm ci --ignore-scripts --no-audit --no-fund/,
  );
  assert.match(
    workflow.slice(deployAction),
    /workingDirectory: trusted-source\/\.github\/preview-tools[\s\S]*wranglerVersion: 4\.125\.0/,
  );
  assert.match(workflow.slice(deployAction), /NPM_CONFIG_OFFLINE: "true"/);
  assert.match(
    workflow.slice(installStep, deployAction),
    /Recheck current PR head immediately before deployment[\s\S]*validateCurrentPullRequest/,
  );
});

test('locks Wrangler and every fetched package by registry integrity', () => {
  assert.equal(lockfile.lockfileVersion, 3);
  assert.equal(lockfile.packages[''].dependencies.wrangler, '4.125.0');
  assert.equal(lockfile.packages['node_modules/wrangler'].version, '4.125.0');
  for (const [name, descriptor] of Object.entries(lockfile.packages)) {
    if (name === '' || descriptor.link) continue;
    assert.match(descriptor.resolved, /^https:\/\/registry\.npmjs\.org\//);
    assert.match(descriptor.integrity, /^sha512-/);
  }
});

test('the source workflow builds PRs and uploads the exact single-file archive', () => {
  assert.match(productionWorkflow, /\n  pull_request:\s*\n/);
  assert.match(
    productionWorkflow,
    /python3 tool\/ci_web_artifact\.py pack build\/web\s+artifacts\/doompeller-web-\$\{\{ github\.sha \}\}\.tar\.gz/,
  );
  assert.match(
    productionWorkflow,
    /name: doompeller-web-\$\{\{ github\.sha \}\}[\s\S]*path: artifacts\/doompeller-web-\$\{\{ github\.sha \}\}\.tar\.gz/,
  );
});

test('production uses the same locked tools and archive contract only from main', () => {
  const installStep = productionWorkflow.indexOf(
    '- name: Install pinned Wrangler without deployment credentials',
  );
  const credential = productionWorkflow.indexOf('secrets.CLOUDFLARE_API_TOKEN');
  const deployAction = productionWorkflow.indexOf(
    'cloudflare/wrangler-action@ebbaa1584979971c8614a24965b4405ff95890e0',
  );
  assert.match(
    productionWorkflow,
    /if: github\.event_name != 'pull_request' && github\.ref == 'refs\/heads\/main'/,
  );
  assert.ok(installStep >= 0);
  assert.ok(credential > installStep);
  assert.ok(deployAction > installStep);
  assert.match(productionWorkflow, /digest-mismatch: error/);
  assert.match(
    productionWorkflow,
    /ci_web_artifact\.py extract[\s\S]*doompeller-web-\$\{\{ github\.sha \}\}\.tar\.gz/,
  );
  assert.match(
    productionWorkflow.slice(installStep, deployAction),
    /working-directory: trusted-source\/\.github\/preview-tools[\s\S]*npm ci --ignore-scripts --no-audit --no-fund/,
  );
  assert.match(
    productionWorkflow.slice(deployAction),
    /NPM_CONFIG_OFFLINE: "true"[\s\S]*wranglerVersion: 4\.125\.0/,
  );
});

test('uses the PR-number alias while reporting the immutable deployment URL', () => {
  assert.match(workflow, /--project-name=castletaste-doompeller/);
  assert.match(workflow, /target_url: preview\.deploymentUrl/);
  assert.match(workflow, /\[{data: 'Branch alias', header: true}, preview\.aliasUrl\]/);
  assert.doesNotMatch(workflow, /deployments:\s*write/);
});

test('preview comments are isolated, bot-owned, serialized, and credential-free', () => {
  const commentJob = workflow.indexOf('\n  comment:');
  assert.ok(commentJob > workflow.indexOf('\n  deploy:'));
  const comment = workflow.slice(commentJob);
  assert.match(comment, /needs: \[validate, deploy\]/);
  assert.match(
    comment,
    /group: doompeller-preview-comment-pr-\$\{\{ needs\.validate\.outputs\.pr_number \}\}/,
  );
  assert.match(comment, /cancel-in-progress: false/);
  assert.match(
    comment,
    /permissions:\s*\n\s*contents: read\s*\n\s*statuses: read\s*\n\s*pull-requests: write\s*\n\s*steps:/,
  );
  assert.doesNotMatch(comment, /environment:|secrets\.|download-artifact@|wrangler|\n\s*run:/);
  assert.doesNotMatch(workflow.slice(0, commentJob), /pull-requests: write/);
});

test('inline scripts receive expressions only through environment variables', () => {
  for (const match of workflow.matchAll(/script: \|\n([\s\S]*?)(?=\n\s{6}- name:|\n\s{2}\w|$)/g)) {
    assert.doesNotMatch(match[1], /\$\{\{/);
  }
});
