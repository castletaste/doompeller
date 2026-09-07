'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {COMMENT_MARKER, publishPreviewComment} = require('./preview-comment.cjs');

const headSha = 'a'.repeat(40);
const buildSha = 'b'.repeat(40);
const deploymentUrl = 'https://1234abcd.castletaste-doompeller.pages.dev';
const aliasUrl = 'https://pr-10.castletaste-doompeller.pages.dev';

function fixture() {
  const calls = [];
  const state = {
    comments: [],
    statuses: [{
      context: 'Cloudflare Pages preview',
      state: 'success',
      target_url: deploymentUrl,
    }],
    pullRequest: {
      number: 10,
      state: 'open',
      head: {sha: headSha, repo: {id: 1359861719}},
      base: {ref: 'main', repo: {id: 1359861719}},
    },
  };
  const listComments = () => assert.fail('Comments must be paginated');
  const github = {
    paginate: async (method, args) => {
      assert.equal(method, listComments);
      assert.deepEqual(args, {
        owner: 'castletaste', repo: 'doompeller', issue_number: 10, per_page: 100,
      });
      calls.push({method: 'list'});
      return state.comments;
    },
    rest: {
      issues: {
        listComments,
        createComment: async (args) => {
          calls.push({method: 'create', args});
          return {data: {html_url: 'https://github.com/castletaste/doompeller/pull/10#issuecomment-1'}};
        },
        updateComment: async (args) => {
          calls.push({method: 'update', args});
          return {data: {html_url: 'https://github.com/castletaste/doompeller/pull/10#issuecomment-1'}};
        },
      },
      repos: {
        getCombinedStatusForRef: async (args) => {
          assert.deepEqual(args, {
            owner: 'castletaste', repo: 'doompeller', ref: headSha,
          });
          calls.push({method: 'status'});
          return {data: {statuses: state.statuses}};
        },
      },
      pulls: {
        get: async (args) => {
          assert.deepEqual(args, {
            owner: 'castletaste', repo: 'doompeller', pull_number: 10,
          });
          calls.push({method: 'pull'});
          return {data: state.pullRequest};
        },
      },
    },
  };
  const input = {
    github,
    context: {
      ref: 'refs/heads/main',
      repo: {owner: 'castletaste', repo: 'doompeller'},
      payload: {repository: {id: 1359861719, default_branch: 'main'}},
    },
    prNumber: 10,
    headSha,
    buildSha,
    sourceRunId: 456,
    deploymentUrl,
    aliasUrl,
  };
  return {input, state, calls};
}

function botComment(body = `${COMMENT_MARKER}\nPrevious build`) {
  return {
    id: 789,
    user: {login: 'github-actions[bot]', type: 'Bot'},
    body,
    html_url: 'https://github.com/castletaste/doompeller/pull/10#issuecomment-789',
  };
}

test('creates a preview comment with immutable and alias URLs and provenance', async () => {
  const {input, calls} = fixture();
  const result = await publishPreviewComment(input);
  assert.equal(result.action, 'created');
  assert.deepEqual(calls.map((call) => call.method), ['list', 'status', 'pull', 'create']);
  const {args} = calls.at(-1);
  assert.ok(args.body.startsWith(`${COMMENT_MARKER}\n`));
  assert.ok(args.body.includes(`[Open this build](${deploymentUrl})`));
  assert.ok(args.body.includes(`[Latest PR preview](${aliasUrl})`));
  assert.ok(args.body.includes(`PR head: \`${headSha}\``));
  assert.ok(args.body.includes(`Tested build: \`${buildSha}\``));
  assert.ok(args.body.includes('https://github.com/castletaste/doompeller/actions/runs/456'));
});

test('updates only the existing marked github-actions bot comment', async () => {
  const {input, state, calls} = fixture();
  state.comments = [botComment()];
  assert.equal((await publishPreviewComment(input)).action, 'updated');
  assert.equal(calls.at(-1).method, 'update');
  assert.equal(calls.at(-1).args.comment_id, 789);

  const next = fixture();
  next.state.comments = [
    {...botComment(), user: {login: 'castletaste', type: 'User'}},
    {...botComment(), user: {login: 'other[bot]', type: 'Bot'}},
    botComment(`Quoted: ${COMMENT_MARKER}\nPrevious build`),
  ];
  assert.equal((await publishPreviewComment(next.input)).action, 'created');
});

test('an identical rerun does not rewrite the comment', async () => {
  const {input, state, calls} = fixture();
  await publishPreviewComment(input);
  const comment = botComment(calls.at(-1).args.body);
  state.comments = [comment];
  calls.length = 0;
  assert.deepEqual(await publishPreviewComment(input), {
    action: 'unchanged', commentUrl: comment.html_url,
  });
  assert.deepEqual(calls.map((call) => call.method), ['list', 'status', 'pull']);
});

test('closed, superseded, or stale-status publications never write a comment', async () => {
  for (const change of [
    ({state}) => { state.pullRequest.state = 'closed'; },
    ({state}) => { state.pullRequest.head.sha = 'c'.repeat(40); },
    ({state}) => { state.statuses = []; },
    ({state}) => { state.statuses[0].state = 'pending'; },
    ({state}) => { state.statuses[0].target_url = 'https://8765dcba.castletaste-doompeller.pages.dev'; },
  ]) {
    const current = fixture();
    current.state.comments = [botComment()];
    change(current);
    assert.equal((await publishPreviewComment(current.input)).action, 'skipped');
    assert.equal(current.calls.some((call) => ['create', 'update'].includes(call.method)), false);
  }
});

test('foreign repositories and mismatched PRs fail before any write', async () => {
  for (const change of [
    (pr) => { pr.head.repo.id = 999; },
    (pr) => { pr.base.repo.id = 999; },
    (pr) => { pr.number = 11; },
  ]) {
    const {input, state, calls} = fixture();
    change(state.pullRequest);
    await assert.rejects(publishPreviewComment(input), /pull request changed/);
    assert.equal(calls.some((call) => ['create', 'update'].includes(call.method)), false);
  }
});

test('invalid URLs, identifiers, and nondefault refs fail before GitHub access', async () => {
  for (const change of [
    (input) => { input.deploymentUrl = 'https://example.com'; },
    (input) => { input.aliasUrl = 'https://pr-11.castletaste-doompeller.pages.dev'; },
    (input) => { input.prNumber = -1; },
    (input) => { input.headSha = 'short'; },
    (input) => { input.buildSha = 'B'.repeat(40); },
    (input) => { input.sourceRunId = 0; },
    (input) => { input.context.ref = 'refs/heads/untrusted'; },
  ]) {
    const {input, calls} = fixture();
    change(input);
    await assert.rejects(publishPreviewComment(input));
    assert.deepEqual(calls, []);
  }
});

test('API write failures propagate without retrying', async () => {
  const {input, calls} = fixture();
  input.github.rest.issues.createComment = async () => {
    calls.push({method: 'create'});
    throw new Error('GitHub unavailable');
  };
  await assert.rejects(publishPreviewComment(input), /GitHub unavailable/);
  assert.equal(calls.filter((call) => call.method === 'create').length, 1);
});
