'use strict';

const {
  validateCurrentPullRequest,
  validatePreviewUrls,
} = require('./preview-artifact-policy.cjs');

const COMMENT_MARKER = '<!-- doompeller-pr-preview -->';

function previewCommentBody({preview, headSha, buildSha, sourceRunId, owner, repo}) {
  for (const sha of [headSha, buildSha]) {
    if (typeof sha !== 'string' || !/^[0-9a-f]{40}$/.test(sha)) {
      throw new Error('preview comment requires full lowercase commit SHAs');
    }
  }
  if (!Number.isSafeInteger(sourceRunId) || sourceRunId <= 0) {
    throw new Error('preview comment requires a positive source run ID');
  }
  return [
    COMMENT_MARKER,
    '### Web preview is ready',
    '',
    `[Open this build](${preview.deploymentUrl}) · [Latest PR preview](${preview.aliasUrl})`,
    '',
    `PR head: \`${headSha}\``,
    `Tested build: \`${buildSha}\``,
    '',
    `[Build checks](https://github.com/${owner}/${repo}/actions/runs/${sourceRunId})`,
    '',
    'This comment updates after each successful preview deployment. The latest-PR link follows subsequent deployments; the build link above is immutable.',
  ].join('\n');
}

/** Called only by the trusted notification job, serialized per pull request. */
async function publishPreviewComment({
  github,
  context,
  prNumber,
  headSha,
  buildSha,
  sourceRunId,
  deploymentUrl,
  aliasUrl,
}) {
  const repository = context.payload.repository;
  if (context.ref !== `refs/heads/${repository.default_branch}`) {
    throw new Error('preview comments must run from the default branch');
  }
  const preview = validatePreviewUrls({deploymentUrl, aliasUrl, prNumber});
  const {owner, repo} = context.repo;
  const body = previewCommentBody({
    preview, headSha, buildSha, sourceRunId, owner, repo,
  });
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner, repo, issue_number: prNumber, per_page: 100,
  });
  const existing = comments.find((comment) =>
    comment.user?.login === 'github-actions[bot]' &&
    comment.user?.type === 'Bot' &&
    comment.body?.startsWith(`${COMMENT_MARKER}\n`),
  );

  // An older publisher must not replace the newest preview, including when two
  // builds of the same PR head finish out of order.
  const {data: status} = await github.rest.repos.getCombinedStatusForRef({
    owner, repo, ref: headSha,
  });
  const latest = status.statuses.find((entry) =>
    entry.context === 'Cloudflare Pages preview',
  );
  if (latest?.state !== 'success' || latest.target_url !== preview.deploymentUrl) {
    return {
      action: 'skipped',
      reason: 'Deployment is no longer the latest successful preview',
    };
  }
  const {data: pullRequest} = await github.rest.pulls.get({
    owner, repo, pull_number: prNumber,
  });
  if (pullRequest.state !== 'open' || pullRequest.head.sha !== headSha) {
    return {action: 'skipped', reason: 'Pull request closed or head changed'};
  }
  validateCurrentPullRequest({repository, pullRequest, prNumber, headSha});

  if (existing?.body === body) {
    return {action: 'unchanged', commentUrl: existing.html_url};
  }
  const {data: comment} = existing
    ? await github.rest.issues.updateComment({
        owner, repo, comment_id: existing.id, body,
      })
    : await github.rest.issues.createComment({
        owner, repo, issue_number: prNumber, body,
      });
  return {
    action: existing ? 'updated' : 'created',
    commentUrl: comment.html_url,
  };
}

module.exports = {COMMENT_MARKER, publishPreviewComment};
