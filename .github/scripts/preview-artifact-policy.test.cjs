'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const zlib = require('node:zlib');

const {
  APPROVED_IWAD_BYTES,
  APPROVED_IWAD_PATH,
  APPROVED_IWAD_SHA256,
  EXPECTED_HEADERS,
  sanitizeArtifactArchive,
  validateCurrentPullRequest,
  validatePreviewSource,
  validatePreviewUrls,
} = require('./preview-artifact-policy.cjs');

const repository = {id: 1359861719, default_branch: 'main'};
const expectedWorkflow = {
  id: 341756850,
  name: 'Verify and deploy Doompeller web',
  path: '.github/workflows/deploy-web.yml',
};
const headSha = '48a6cc71fdb804d2b23f89eb05f7e7644265db64';
const buildSha = '2dc348080b0a99ec9d1472cf61606f11a923372b';

function validFixture() {
  const run = {
    id: 34037938388,
    workflow_id: expectedWorkflow.id,
    name: 'Verify and deploy Doompeller web',
    path: expectedWorkflow.path,
    event: 'pull_request',
    status: 'completed',
    conclusion: 'success',
    head_sha: headSha,
    repository: {id: repository.id},
    head_repository: {id: repository.id},
    pull_requests: [{number: 5}],
  };
  const pullRequest = {
    number: 5,
    state: 'open',
    head: {sha: headSha, repo: {id: repository.id}},
    base: {ref: 'main', repo: {id: repository.id}},
  };
  const artifacts = [{
    id: 9990834806,
    name: `doompeller-web-${buildSha}`,
    expired: false,
    digest: `sha256:${'1'.repeat(64)}`,
    workflow_run: {
      id: run.id,
      repository_id: repository.id,
      head_repository_id: repository.id,
      head_sha: headSha,
    },
  }];
  return {repository, expectedWorkflow, run, pullRequest, artifacts};
}

test('accepts the current PR head and its distinct tested merge artifact SHA', () => {
  assert.deepEqual(validatePreviewSource(validFixture()), {
    runId: 34037938388,
    prNumber: 5,
    headSha,
    buildSha,
    artifactId: 9990834806,
  });
});

test('accepts a same-repository stacked base branch', () => {
  const fixture = validFixture();
  fixture.pullRequest.base.ref = 'codex/runtime-ownership-refactor';
  assert.doesNotThrow(() => validatePreviewSource(fixture));
});

test('rejects untrusted, failed, stale, closed, fork, and ambiguous sources', () => {
  const mutations = [
    (fixture) => (fixture.run.workflow_id = 1),
    (fixture) => (fixture.run.path = '.github/workflows/other.yml'),
    (fixture) => (fixture.run.name = 'An attacker-controlled workflow'),
    (fixture) => (fixture.run.event = 'push'),
    (fixture) => (fixture.run.status = 'in_progress'),
    (fixture) => (fixture.run.conclusion = 'failure'),
    (fixture) => (fixture.run.repository.id = 1),
    (fixture) => (fixture.run.head_repository.id = 1),
    (fixture) => (fixture.run.pull_requests = [{number: 5}, {number: 6}]),
    (fixture) => (fixture.pullRequest.state = 'closed'),
    (fixture) => (fixture.pullRequest.head.repo.id = 1),
    (fixture) => (fixture.pullRequest.base.repo.id = 1),
    (fixture) => (fixture.pullRequest.head.sha = 'a'.repeat(40)),
    (fixture) => (fixture.artifacts[0].expired = true),
    (fixture) => (fixture.artifacts[0].digest = 'sha256:example'),
    (fixture) =>
      fixture.artifacts.push({
        ...fixture.artifacts[0],
        id: 2,
        name: `doompeller-web-${'b'.repeat(40)}`,
      }),
    (fixture) => (fixture.artifacts[0].workflow_run.id = 1),
    (fixture) => (fixture.artifacts[0].workflow_run.repository_id = 1),
    (fixture) => (fixture.artifacts[0].workflow_run.head_repository_id = 1),
    (fixture) => (fixture.artifacts[0].workflow_run.head_sha = 'c'.repeat(40)),
  ];
  for (const mutate of mutations) {
    const fixture = validFixture();
    mutate(fixture);
    assert.throws(() => validatePreviewSource(fixture));
  }
});

test('freshness validation fails after the PR head or state changes', () => {
  const fixture = validFixture();
  assert.doesNotThrow(() => validateCurrentPullRequest({
    repository,
    pullRequest: fixture.pullRequest,
    prNumber: 5,
    headSha,
  }));
  fixture.pullRequest.head.sha = 'a'.repeat(40);
  assert.throws(() => validateCurrentPullRequest({
    repository,
    pullRequest: fixture.pullRequest,
    prNumber: 5,
    headSha,
  }));
});

test('accepts only an immutable URL and the exact HTTPS PR-number alias', () => {
  assert.deepEqual(validatePreviewUrls({
    deploymentUrl: 'https://002794db.castletaste-doompeller.pages.dev/',
    aliasUrl: 'https://pr-5.castletaste-doompeller.pages.dev/',
    prNumber: 5,
  }), {
    deploymentUrl: 'https://002794db.castletaste-doompeller.pages.dev',
    aliasUrl: 'https://pr-5.castletaste-doompeller.pages.dev',
  });
  const invalid = [
    ['https://pr-5.castletaste-doompeller.pages.dev',
      'https://pr-5.castletaste-doompeller.pages.dev'],
    ['http://002794db.castletaste-doompeller.pages.dev',
      'https://pr-5.castletaste-doompeller.pages.dev'],
    ['https://002794db.evil.pages.dev',
      'https://pr-5.castletaste-doompeller.pages.dev'],
    ['https://002794db.castletaste-doompeller.pages.dev',
      'https://pr-6.castletaste-doompeller.pages.dev'],
    ['https://002794db.castletaste-doompeller.pages.dev/path',
      'https://pr-5.castletaste-doompeller.pages.dev'],
  ];
  for (const [deploymentUrl, aliasUrl] of invalid) {
    assert.throws(() => validatePreviewUrls({deploymentUrl, aliasUrl, prNumber: 5}));
  }
});

function writeString(header, offset, length, value) {
  const bytes = Buffer.from(value, 'ascii');
  assert.ok(bytes.length <= length);
  bytes.copy(header, offset);
}

function writeOctal(header, offset, length, value) {
  const encoded = value.toString(8).padStart(length - 1, '0');
  assert.equal(encoded.length, length - 1);
  writeString(header, offset, length, `${encoded}\0`);
}

function tarBuffer(entries) {
  const chunks = [];
  for (const entry of entries) {
    const contents = Buffer.isBuffer(entry.contents)
      ? entry.contents
      : Buffer.from(entry.contents ?? '');
    const header = Buffer.alloc(512);
    writeString(header, 0, 100, entry.name);
    writeOctal(header, 100, 8, entry.mode ?? 0o644);
    writeOctal(header, 108, 8, 0);
    writeOctal(header, 116, 8, 0);
    writeOctal(header, 124, 12, contents.length);
    writeOctal(header, 136, 12, 0);
    header.fill(0x20, 148, 156);
    header[156] = (entry.type ?? '0').charCodeAt(0);
    writeString(header, 257, 6, 'ustar\0');
    writeString(header, 263, 2, '00');
    let checksum = 0;
    for (const value of header) checksum += value;
    const checksumField = `${checksum.toString(8).padStart(6, '0')}\0 `;
    writeString(header, 148, 8, checksumField);
    chunks.push(header, contents);
    const padding = (512 - (contents.length % 512)) % 512;
    if (padding !== 0) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  return Buffer.concat(chunks);
}

const testWad = Buffer.from('approved-test-wad');
const testWadSha256 = crypto.createHash('sha256').update(testWad).digest('hex');

function validEntries() {
  return [
    {name: '_headers', contents: EXPECTED_HEADERS},
    {
      name: 'flutter_bootstrap.js',
      contents: '{"compileTarget":"dart2wasm","renderer":"skwasm","useLocalCanvasKit":true}',
    },
    {name: 'index.html', contents: '<!doctype html>'},
    {name: 'main.dart.mjs', contents: 'export const app = true;'},
    {name: 'main.dart.wasm', contents: 'wasm'},
    {name: 'doom_music_worker.wasm', contents: 'music wasm'},
    {name: 'doom_music_worker.mjs', contents: 'export const worker = true;'},
    {name: 'doom_music_worker_loader.mjs', contents: 'export const loader = true;'},
    {name: 'doom_music_worklet.js', contents: 'registerProcessor("doom-music", class {});'},
    {name: 'assets/assets/shaders/doom_palette.wgslbundle', contents: 'shader'},
    {name: APPROVED_IWAD_PATH, contents: testWad},
  ];
}

function withArtifact(entries, run, {rawTar} = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'doompeller-preview-test-'));
  const source = path.join(root, 'source');
  const destination = path.join(root, 'sanitized');
  fs.mkdirSync(source);
  const archivePath = path.join(source, `doompeller-web-${buildSha}.tar.gz`);
  const tar = rawTar ?? tarBuffer(entries);
  fs.writeFileSync(archivePath, zlib.gzipSync(tar));
  try {
    run({root, source, destination, archivePath});
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
}

function sanitize(source, destination, options = {}) {
  return sanitizeArtifactArchive(source, destination, buildSha, {
    expectedIwadBytes: testWad.length,
    expectedIwadSha256: testWadSha256,
    ...options,
  });
}

test('pins the exact approved public shareware IWAD identity', () => {
  assert.equal(APPROVED_IWAD_BYTES, 4196020);
  assert.equal(
    APPROVED_IWAD_SHA256,
    '1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771',
  );
});

test('trusted header constant stays byte-identical to the production source', () => {
  assert.equal(
    EXPECTED_HEADERS,
    fs.readFileSync(path.join(__dirname, '../../web/_headers'), 'utf8'),
  );
});

test('sanitizes an archive while preserving the one approved hidden WAD', () => {
  withArtifact(validEntries(), ({source, destination}) => {
    const result = sanitize(source, destination);
    assert.equal(result.fileCount, 11);
    assert.equal(result.iwadBytes, testWad.length);
    assert.equal(result.iwadSha256, testWadSha256);
    assert.deepEqual(
      fs.readFileSync(path.join(destination, APPROVED_IWAD_PATH)),
      testWad,
    );
  });
});

test('rejects a missing, modified, renamed, or additional WAD', () => {
  const cases = [
    validEntries().filter((entry) => entry.name !== APPROVED_IWAD_PATH),
    validEntries().map((entry) =>
      entry.name === APPROVED_IWAD_PATH ? {...entry, contents: 'modified'} : entry),
    validEntries().map((entry) =>
      entry.name === APPROVED_IWAD_PATH ? {...entry, name: 'assets/DOOM1.WAD'} : entry),
    [...validEntries(), {name: 'assets/extra.wad', contents: 'no'}],
  ];
  for (const entries of cases) {
    withArtifact(entries, ({source, destination}) => {
      assert.throws(() => sanitize(source, destination));
    });
  }
});

test('rejects server code, package execution metadata, unexpected roots, and links', () => {
  const unsafePaths = [
    '_worker.js',
    'functions/handler.js',
    'wrangler.toml',
    'package.json',
    'unexpected.txt',
    'assets/wrangler.jsonc',
    'assets/.secrets/token',
  ];
  for (const unsafePath of unsafePaths) {
    withArtifact([...validEntries(), {name: unsafePath, contents: 'unsafe'}],
      ({source, destination}) => {
        assert.throws(() => sanitize(source, destination));
      });
  }
  withArtifact([...validEntries(), {
    name: 'assets/link',
    contents: 'index.html',
    type: '2',
  }], ({source, destination}) => {
    assert.throws(() => sanitize(source, destination), /link, extension, or special/);
  });
});

test('rejects traversal, duplicate paths, malformed checksums, and extra outer files', () => {
  withArtifact([...validEntries(), {name: '../escape', contents: 'bad'}],
    ({source, destination}) => {
      assert.throws(() => sanitize(source, destination), /unsafe archive path/);
    });
  withArtifact([...validEntries(), {name: 'index.html', contents: 'duplicate'}],
    ({source, destination}) => {
      assert.throws(() => sanitize(source, destination), /duplicate archive path/);
    });
  const corrupt = tarBuffer(validEntries());
  corrupt[0] ^= 1;
  withArtifact([], ({source, destination}) => {
    assert.throws(() => sanitize(source, destination), /checksum/);
  }, {rawTar: corrupt});
  withArtifact(validEntries(), ({source, destination}) => {
    fs.writeFileSync(path.join(source, 'extra'), 'bad');
    assert.throws(() => sanitize(source, destination), /must contain only/);
  });
});

test('enforces required files, Wasm-only bootstrap, and bounded sizes', () => {
  for (const name of [
    'main.dart.wasm',
    'doom_music_worker.wasm',
    'doom_music_worker.mjs',
    'doom_music_worker_loader.mjs',
    'doom_music_worklet.js',
  ]) {
    const missing = validEntries().filter((entry) => entry.name !== name);
    withArtifact(missing, ({source, destination}) => {
      assert.throws(() => sanitize(source, destination), /missing required/, name);
    });
  }
  const fallback = validEntries().map((entry) => entry.name === 'flutter_bootstrap.js'
    ? {...entry, contents: '{"compileTarget":"dart2js","renderer":"skwasm","useLocalCanvasKit":true}'}
    : entry);
  withArtifact(fallback, ({source, destination}) => {
    assert.throws(() => sanitize(source, destination), /dart2wasm/);
  });
  withArtifact(validEntries(), ({source, destination}) => {
    assert.throws(() => sanitize(source, destination, {maxFileBytes: 4}));
  });
  withArtifact(validEntries(), ({source, destination}) => {
    assert.throws(() => sanitize(source, destination, {maxFiles: 1}));
  });
  withArtifact(validEntries(), ({source, destination}) => {
    assert.throws(() => sanitize(source, destination, {maxTotalBytes: 1}));
  });
});

test('rejects every missing, weakened, duplicated, or reordered header contract', () => {
  const mutations = [
    EXPECTED_HEADERS.replace(
      '  Cross-Origin-Embedder-Policy: credentialless\n',
      '',
    ),
    EXPECTED_HEADERS.replace(
      '  Cross-Origin-Opener-Policy: same-origin',
      '  Cross-Origin-Opener-Policy: unsafe-none',
    ),
    EXPECTED_HEADERS.replace(
      "  Content-Security-Policy: frame-ancestors 'none'",
      "  Content-Security-Policy: frame-ancestors *",
    ),
    `${EXPECTED_HEADERS}  X-Content-Type-Options: off\n`,
    EXPECTED_HEADERS.replace(
      '/assets/.local/doom/DOOM1.WAD\n  Cache-Control: public, max-age=31536000, immutable',
      '/assets/.local/doom/DOOM1.WAD\n  Cache-Control: public, max-age=0',
    ),
    EXPECTED_HEADERS.replace(
      '/main.dart.wasm\n  Cache-Control: public, max-age=0, must-revalidate\n\n' +
        '/main.dart.mjs\n  Cache-Control: public, max-age=0, must-revalidate',
      '/main.dart.mjs\n  Cache-Control: public, max-age=0, must-revalidate\n\n' +
        '/main.dart.wasm\n  Cache-Control: public, max-age=0, must-revalidate',
    ),
  ];
  for (const headers of mutations) {
    const entries = validEntries().map((entry) =>
      entry.name === '_headers' ? {...entry, contents: headers} : entry);
    withArtifact(entries, ({source, destination}) => {
      assert.throws(
        () => sanitize(source, destination),
        /trusted deployment contract/,
      );
    });
  }
});
