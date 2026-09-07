'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const test = require('node:test');

const repositoryRoot = path.resolve(__dirname, '../..');
const workflow = fs.readFileSync(
  path.join(repositoryRoot, '.github/workflows/deploy-web.yml'),
  'utf8',
);
const flutterUrl =
  'https://storage.googleapis.com/flutter_infra_release/releases/stable/' +
  'linux/flutter_linux_3.44.4-stable.tar.xz';
const flutterSha256 =
  'c853cda0312a162854c481fe6a1bc286d84fbb74bfab7037c39750061dc9b466';

function shellStep(name) {
  const stepMarker = `      - name: ${name}\n`;
  const stepStart = workflow.indexOf(stepMarker);
  assert.ok(stepStart >= 0, `missing workflow step: ${name}`);
  const runMarker = '        run: |\n';
  const scriptStart = workflow.indexOf(runMarker, stepStart);
  assert.ok(scriptStart >= 0, `missing shell block: ${name}`);
  const bodyStart = scriptStart + runMarker.length;
  const nextStep = workflow.indexOf('\n      - name:', bodyStart);
  const indented = workflow.slice(
    bodyStart,
    nextStep < 0 ? workflow.length : nextStep + 1,
  );
  return indented
    .split('\n')
    .map((line) => line.startsWith('          ') ? line.slice(10) : line)
    .join('\n');
}

const setupScript = shellStep('Set up Flutter 3.44.4');

test('installs the exact official Flutter archive without a composite action', () => {
  assert.doesNotMatch(workflow, /flutter-action@/);
  assert.deepEqual(
    setupScript.match(
      /https:\/\/storage\.googleapis\.com\/flutter_infra_release\/releases\/stable\/linux\/\S+\.tar\.xz/g,
    ),
    [flutterUrl],
  );
  assert.equal(setupScript.split(flutterSha256).length - 1, 1);
  assert.match(setupScript, /^set -euo pipefail$/m);
  assert.match(setupScript, /test "\$RUNNER_OS" = Linux/);
  assert.match(setupScript, /test "\$RUNNER_ARCH" = X64/);
  assert.match(
    setupScript,
    /mktemp -d "\$\{RUNNER_TEMP\}\/doompeller-flutter\.XXXXXX"/,
  );
  assert.match(setupScript, /sha256sum --check --strict/);
  assert.match(setupScript, /tar --extract --xz --no-same-owner/);

  const download = setupScript.indexOf('curl --fail');
  const checksum = setupScript.indexOf('sha256sum --check --strict');
  const extraction = setupScript.indexOf('tar --extract');
  const pathExport = setupScript.indexOf('>> "$GITHUB_PATH"');
  const rootExport = setupScript.indexOf('>> "$GITHUB_ENV"');
  assert.ok(download >= 0);
  assert.ok(checksum > download);
  assert.ok(extraction > checksum);
  assert.ok(pathExport > extraction);
  assert.ok(rootExport > extraction);
  assert.doesNotMatch(setupScript, /^\s*(?:flutter|dart)\s/m);
});

test('build remains credential-free and every action stays pinned by full SHA', () => {
  const buildStart = workflow.indexOf('\n  build:');
  const deployStart = workflow.indexOf('\n  deploy:');
  assert.ok(buildStart >= 0 && deployStart > buildStart);
  const build = workflow.slice(buildStart, deployStart);
  assert.doesNotMatch(build, /^\s*environment:/m);
  assert.doesNotMatch(build, /secrets\.|CLOUDFLARE_API_TOKEN|CLOUDFLARE_ACCOUNT_ID/);

  const uses = [...workflow.matchAll(/^\s*uses:\s*(\S+)/gm)].map(
    (match) => match[1],
  );
  assert.ok(uses.length >= 6);
  for (const action of uses) {
    assert.match(action, /^[^@\s]+@[0-9a-f]{40}$/, action);
  }
});

function writeExecutable(directory, name, contents) {
  const target = path.join(directory, name);
  fs.writeFileSync(target, `#!/bin/sh\nset -eu\n${contents}`);
  fs.chmodSync(target, 0o755);
}

function runMockedSetup({curlFails = false, checksumFails = false} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'doompeller-flutter-ci-'));
  const bin = path.join(root, 'bin');
  const runnerTemp = path.join(root, 'runner');
  const log = path.join(root, 'commands.log');
  const githubPath = path.join(root, 'github-path');
  const githubEnv = path.join(root, 'github-env');
  fs.mkdirSync(bin);
  fs.mkdirSync(runnerTemp);
  writeExecutable(bin, 'curl', `
printf '%s\n' curl >> "$MOCK_LOG"
if [ "$MOCK_CURL_FAILS" = 1 ]; then exit 22; fi
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
test -n "$output"
printf '%s' downloaded-archive > "$output"
`);
  writeExecutable(bin, 'sha256sum', `
printf '%s\n' sha256sum >> "$MOCK_LOG"
while IFS= read -r ignored; do :; done
if [ "$MOCK_CHECKSUM_FAILS" = 1 ]; then exit 1; fi
`);
  writeExecutable(bin, 'tar', `
printf '%s\n' tar >> "$MOCK_LOG"
`);
  writeExecutable(bin, 'git', `
printf '%s\n' git >> "$MOCK_LOG"
printf '%s\n' ad70ec4617166f1c38e5d2bfd388af71fda14f06
`);
  const result = spawnSync('bash', ['-c', setupScript], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      RUNNER_OS: 'Linux',
      RUNNER_ARCH: 'X64',
      RUNNER_TEMP: runnerTemp,
      GITHUB_PATH: githubPath,
      GITHUB_ENV: githubEnv,
      MOCK_LOG: log,
      MOCK_CURL_FAILS: curlFails ? '1' : '0',
      MOCK_CHECKSUM_FAILS: checksumFails ? '1' : '0',
    },
  });
  const commands = fs.existsSync(log)
    ? fs.readFileSync(log, 'utf8').trim().split('\n')
    : [];
  return {
    result,
    commands,
    githubPathExists: fs.existsSync(githubPath),
    githubEnvExists: fs.existsSync(githubEnv),
  };
}

test('download and checksum failures stop before extraction or PATH export', () => {
  const failedDownload = runMockedSetup({curlFails: true});
  assert.notEqual(failedDownload.result.status, 0);
  assert.deepEqual(failedDownload.commands, ['curl']);
  assert.equal(failedDownload.githubPathExists, false);
  assert.equal(failedDownload.githubEnvExists, false);

  const failedChecksum = runMockedSetup({checksumFails: true});
  assert.notEqual(failedChecksum.result.status, 0);
  assert.deepEqual(failedChecksum.commands, ['curl', 'sha256sum']);
  assert.equal(failedChecksum.githubPathExists, false);
  assert.equal(failedChecksum.githubEnvExists, false);

  const valid = runMockedSetup();
  assert.equal(valid.result.status, 0, valid.result.stderr);
  assert.deepEqual(valid.commands, ['curl', 'sha256sum', 'tar', 'git']);
  assert.equal(valid.githubPathExists, true);
  assert.equal(valid.githubEnvExists, true);
});
