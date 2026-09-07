'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const SOURCE_WORKFLOW_PATH = '.github/workflows/deploy-web.yml';
const SOURCE_WORKFLOW_NAMES = new Set([
  'Verify and deploy Doompeller web',
]);
const SOURCE_ARTIFACT_PATTERN = /^doompeller-web-([0-9a-f]{40})$/;
const PREVIEW_PROJECT_HOST = 'castletaste-doompeller.pages.dev';
const APPROVED_IWAD_PATH = 'assets/.local/doom/DOOM1.WAD';
const APPROVED_IWAD_BYTES = 4196020;
const APPROVED_IWAD_SHA256 =
  '1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771';
const EXPECTED_HEADERS = [
  '/*',
  '  Cross-Origin-Embedder-Policy: credentialless',
  '  Cross-Origin-Opener-Policy: same-origin',
  "  Content-Security-Policy: frame-ancestors 'none'",
  '  Permissions-Policy: camera=(), geolocation=(), microphone=(), payment=(), usb=()',
  '  Strict-Transport-Security: max-age=31536000',
  '  X-Frame-Options: DENY',
  '  X-Content-Type-Options: nosniff',
  '  Referrer-Policy: strict-origin-when-cross-origin',
  '',
  '/index.html',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/flutter_bootstrap.js',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/flutter_service_worker.js',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/version.json',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/main.dart.wasm',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/main.dart.mjs',
  '  Cache-Control: public, max-age=0, must-revalidate',
  '',
  '/assets/.local/doom/DOOM1.WAD',
  '  Cache-Control: public, max-age=31536000, immutable',
  '',
].join('\n');

const ALLOWED_ROOT_FILES = new Set([
  '_headers',
  'favicon.png',
  'flutter.js',
  'flutter_bootstrap.js',
  'flutter_service_worker.js',
  'index.html',
  'main.dart.mjs',
  'main.dart.wasm',
  'manifest.json',
  'version.json',
]);
const ALLOWED_ROOT_DIRECTORIES = new Set(['assets', 'canvaskit', 'icons']);
const REQUIRED_ROOT_FILES = new Set([
  '_headers',
  'flutter_bootstrap.js',
  'index.html',
  'main.dart.mjs',
  'main.dart.wasm',
]);
const REQUIRED_FILES = new Set([
  ...REQUIRED_ROOT_FILES,
  'assets/assets/shaders/doom_palette.wgslbundle',
  APPROVED_IWAD_PATH,
]);
const FORBIDDEN_NAMES = new Set([
  '_routes.json',
  '_worker.js',
  '_worker.js.map',
  'bun.lock',
  'bun.lockb',
  'functions',
  'package-lock.json',
  'package.json',
  'pnpm-lock.yaml',
  'wrangler.json',
  'wrangler.jsonc',
  'wrangler.toml',
  'yarn.lock',
]);

function fail(message) {
  throw new Error(message);
}

function requirePositiveSafeInteger(value, label) {
  const parsed = typeof value === 'number' ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    fail(`${label} must be a positive safe integer`);
  }
  return parsed;
}

function requireSha(value, label) {
  if (typeof value !== 'string' || !/^[0-9a-f]{40}$/.test(value)) {
    fail(`${label} must be a lowercase 40-character SHA`);
  }
  return value;
}

function requireSinglePullRequestNumber(run) {
  if (!Array.isArray(run?.pull_requests) || run.pull_requests.length !== 1) {
    fail('source run must belong to exactly one pull request');
  }
  return requirePositiveSafeInteger(
    run.pull_requests[0]?.number,
    'pull request number',
  );
}

function validatePreviewSource({
  repository,
  expectedWorkflow,
  run,
  pullRequest,
  artifacts,
}) {
  const repositoryId = requirePositiveSafeInteger(
    repository?.id,
    'repository id',
  );
  const workflowId = requirePositiveSafeInteger(
    expectedWorkflow?.id,
    'workflow id',
  );
  const runId = requirePositiveSafeInteger(run?.id, 'source run id');
  const prNumber = requireSinglePullRequestNumber(run);

  if (expectedWorkflow?.path !== SOURCE_WORKFLOW_PATH) {
    fail('trusted source workflow path is unexpected');
  }
  if (
    run?.workflow_id !== workflowId ||
    run?.path !== SOURCE_WORKFLOW_PATH ||
    !SOURCE_WORKFLOW_NAMES.has(run?.name)
  ) {
    fail('source run did not execute the trusted web build workflow');
  }
  if (run?.event !== 'pull_request' || run?.status !== 'completed') {
    fail('source run must be a completed pull_request run');
  }
  if (run?.conclusion !== 'success') {
    fail('source run must have succeeded');
  }
  if (
    run?.repository?.id !== repositoryId ||
    run?.head_repository?.id !== repositoryId
  ) {
    fail('source run must build a branch from this repository');
  }

  if (pullRequest?.number !== prNumber || pullRequest?.state !== 'open') {
    fail('source pull request must still be open');
  }
  if (
    pullRequest?.base?.repo?.id !== repositoryId ||
    pullRequest?.head?.repo?.id !== repositoryId
  ) {
    fail('fork pull requests cannot publish previews');
  }
  const headSha = requireSha(run?.head_sha, 'source head SHA');
  if (pullRequest?.head?.sha !== headSha) {
    fail('source run is stale for the current pull request head');
  }

  if (!Array.isArray(artifacts)) fail('artifact response must be an array');
  const candidates = artifacts.filter((artifact) =>
    artifact?.name?.startsWith('doompeller-web-'),
  );
  if (candidates.length !== 1) {
    fail('source run must contain exactly one Doompeller web artifact');
  }
  const artifact = candidates[0];
  const nameMatch = SOURCE_ARTIFACT_PATTERN.exec(artifact.name);
  if (nameMatch === null) fail('source artifact name has an invalid build SHA');
  if (artifact.expired === true) fail('source artifact has expired');
  if (typeof artifact.digest !== 'string' ||
      !/^sha256:[0-9a-f]{64}$/.test(artifact.digest)) {
    fail('source artifact must have a SHA-256 digest');
  }
  if (
    artifact?.workflow_run?.id !== runId ||
    artifact?.workflow_run?.repository_id !== repositoryId ||
    artifact?.workflow_run?.head_repository_id !== repositoryId ||
    artifact?.workflow_run?.head_sha !== headSha
  ) {
    fail('source artifact provenance does not match the source run');
  }

  return Object.freeze({
    runId,
    prNumber,
    headSha,
    buildSha: nameMatch[1],
    artifactId: requirePositiveSafeInteger(artifact.id, 'artifact id'),
  });
}

function validateCurrentPullRequest({repository, pullRequest, prNumber, headSha}) {
  const repositoryId = requirePositiveSafeInteger(
    repository?.id,
    'repository id',
  );
  if (
    pullRequest?.number !== requirePositiveSafeInteger(prNumber, 'PR number') ||
    pullRequest?.state !== 'open' ||
    pullRequest?.head?.repo?.id !== repositoryId ||
    pullRequest?.base?.repo?.id !== repositoryId ||
    pullRequest?.head?.sha !== requireSha(headSha, 'expected head SHA')
  ) {
    fail('pull request changed after preview validation');
  }
}

function parseStaticPagesUrl(value, label) {
  if (typeof value !== 'string') fail('preview URL must be a string');
  let url;
  try {
    url = new URL(value.trim());
  } catch (_) {
    fail(`${label} is invalid`);
  }
  if (
    url.protocol !== 'https:' ||
    url.port !== '' ||
    url.username !== '' ||
    url.password !== '' ||
    (url.pathname !== '' && url.pathname !== '/') ||
    url.search !== '' ||
    url.hash !== ''
  ) {
    fail(`${label} must be a bare HTTPS origin`);
  }
  return url;
}

function validatePreviewUrls({deploymentUrl, aliasUrl, prNumber}) {
  const immutable = parseStaticPagesUrl(
    deploymentUrl,
    'immutable deployment URL',
  );
  const alias = parseStaticPagesUrl(aliasUrl, 'preview alias URL');
  const expectedAliasHost = `pr-${requirePositiveSafeInteger(
    prNumber,
    'PR number',
  )}.${PREVIEW_PROJECT_HOST}`;
  if (alias.hostname !== expectedAliasHost) {
    fail('preview URL does not match the expected Cloudflare branch alias');
  }
  const deploymentSuffix = `.${PREVIEW_PROJECT_HOST}`;
  if (!immutable.hostname.endsWith(deploymentSuffix)) {
    fail('deployment URL is not hosted by the configured Pages project');
  }
  const deploymentLabel = immutable.hostname.slice(0, -deploymentSuffix.length);
  if (
    !/^[a-z0-9](?:[a-z0-9-]{6,62}[a-z0-9])$/.test(deploymentLabel) ||
    deploymentLabel === `pr-${prNumber}`
  ) {
    fail('deployment URL is not an immutable Cloudflare Pages URL');
  }
  return Object.freeze({
    deploymentUrl: `https://${immutable.hostname}`,
    aliasUrl: `https://${expectedAliasHost}`,
  });
}

function decodeTarString(buffer, start, length, label) {
  const field = buffer.subarray(start, start + length);
  const nul = field.indexOf(0);
  const bytes = nul === -1 ? field : field.subarray(0, nul);
  if (bytes.some((value) => value > 0x7f)) fail(`${label} must be ASCII`);
  return bytes.toString('ascii');
}

function parseTarOctal(buffer, start, length, label) {
  const value = decodeTarString(buffer, start, length, label).trim();
  if (!/^[0-7]+$/.test(value)) fail(`${label} is not canonical octal`);
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) fail(`${label} is invalid`);
  return parsed;
}

function normalizeArchivePath(rawPath, isDirectory) {
  let value = rawPath;
  while (value.startsWith('./')) value = value.slice(2);
  if (isDirectory) value = value.replace(/\/+$/, '');
  if (value === '' && isDirectory) return '';
  if (
    value === '' ||
    value.startsWith('/') ||
    value.includes('\\') ||
    value.includes('//') ||
    value.length > 1024
  ) {
    fail(`unsafe archive path: ${JSON.stringify(rawPath)}`);
  }
  const segments = value.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) {
    fail(`unsafe archive path: ${JSON.stringify(rawPath)}`);
  }
  return value;
}

function validatePath(relativePath, isDirectory) {
  const segments = relativePath.split('/');
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    const lower = segment.toLowerCase();
    const isApprovedHiddenSegment =
      relativePath === APPROVED_IWAD_PATH && index === 1 && segment === '.local';
    if (
      segment.length === 0 ||
      segment.length > 255 ||
      (!isApprovedHiddenSegment && segment.startsWith('.')) ||
      !/^[A-Za-z0-9@+_,.=~()-]+$/.test(segment) ||
      FORBIDDEN_NAMES.has(lower) ||
      lower.startsWith('wrangler.')
    ) {
      fail(`unsafe artifact path segment: ${JSON.stringify(segment)}`);
    }
  }
  const root = segments[0];
  if (segments.length === 1) {
    if (isDirectory && !ALLOWED_ROOT_DIRECTORIES.has(root)) {
      fail(`unexpected artifact root directory: ${root}`);
    }
    if (!isDirectory && !ALLOWED_ROOT_FILES.has(root)) {
      fail(`unexpected artifact root file: ${root}`);
    }
  } else if (!ALLOWED_ROOT_DIRECTORIES.has(root)) {
    fail(`unexpected artifact root directory: ${root}`);
  }
  const lowerPath = relativePath.toLowerCase();
  if (
    !isDirectory &&
    /\.(?:wad|iwad|pwad)$/.test(lowerPath) &&
    relativePath !== APPROVED_IWAD_PATH
  ) {
    fail(`unexpected WAD in artifact: ${relativePath}`);
  }
}

function readTarEntries(archive, {maxFiles, maxFileBytes, maxTotalBytes}) {
  const entries = [];
  const seen = new Set();
  let offset = 0;
  let totalBytes = 0;
  let endBlocks = 0;

  while (offset + 512 <= archive.length) {
    const header = archive.subarray(offset, offset + 512);
    offset += 512;
    if (header.every((value) => value === 0)) {
      endBlocks += 1;
      if (endBlocks === 2) break;
      continue;
    }
    if (endBlocks !== 0) fail('tar has data after an end marker');

    const storedChecksum = parseTarOctal(header, 148, 8, 'tar checksum');
    let actualChecksum = 0;
    for (let index = 0; index < 512; index += 1) {
      actualChecksum += index >= 148 && index < 156 ? 0x20 : header[index];
    }
    if (storedChecksum !== actualChecksum) fail('tar header checksum mismatch');
    if (decodeTarString(header, 257, 6, 'tar magic') !== 'ustar') {
      fail('archive must use the ustar format');
    }

    const name = decodeTarString(header, 0, 100, 'tar path');
    const prefix = decodeTarString(header, 345, 155, 'tar prefix');
    const rawPath = prefix === '' ? name : `${prefix}/${name}`;
    const type = header[156];
    const isDirectory = type === 0x35;
    if (type !== 0 && type !== 0x30 && !isDirectory) {
      fail(`archive contains a link, extension, or special entry: ${rawPath}`);
    }
    const relativePath = normalizeArchivePath(rawPath, isDirectory);
    const size = parseTarOctal(header, 124, 12, 'tar entry size');
    if (isDirectory && size !== 0) fail('tar directory entry must be empty');
    if (!isDirectory && size > maxFileBytes) {
      fail(`artifact file exceeds the size limit: ${relativePath}`);
    }
    const paddedSize = Math.ceil(size / 512) * 512;
    if (offset + paddedSize > archive.length) fail('tar entry is truncated');
    if (relativePath !== '') {
      validatePath(relativePath, isDirectory);
      if (seen.has(relativePath)) fail(`duplicate archive path: ${relativePath}`);
      seen.add(relativePath);
      if (!isDirectory) {
        if (size === 0) fail(`artifact contains an empty file: ${relativePath}`);
        totalBytes += size;
        if (totalBytes > maxTotalBytes) fail('artifact exceeds the total size limit');
        entries.push({
          relativePath,
          contents: archive.subarray(offset, offset + size),
        });
        if (entries.length > maxFiles) fail('artifact exceeds the file count limit');
      }
    }
    offset += paddedSize;
  }

  if (endBlocks !== 2) fail('tar is missing its two-block end marker');
  if (archive.subarray(offset).some((value) => value !== 0)) {
    fail('tar contains nonzero trailing data');
  }
  return {entries, totalBytes};
}

function sanitizeArtifactArchive(
  sourceDirectory,
  destinationDirectory,
  buildSha,
  {
    maxArchiveBytes = 128 * 1024 * 1024,
    maxFiles = 20000,
    maxFileBytes = 25 * 1024 * 1024,
    maxTotalBytes = 256 * 1024 * 1024,
    expectedIwadBytes = APPROVED_IWAD_BYTES,
    expectedIwadSha256 = APPROVED_IWAD_SHA256,
  } = {},
) {
  const source = path.resolve(sourceDirectory);
  const destination = path.resolve(destinationDirectory);
  if (source === destination || destination.startsWith(`${source}${path.sep}`)) {
    fail('sanitized destination must be outside the source artifact');
  }
  const sourceStat = fs.lstatSync(source);
  if (!sourceStat.isDirectory() || sourceStat.isSymbolicLink()) {
    fail('source artifact must be a real directory');
  }
  if (fs.existsSync(destination)) fail('sanitized destination already exists');
  const checkedBuildSha = requireSha(buildSha, 'build SHA');
  const expectedArchiveName = `doompeller-web-${checkedBuildSha}.tar.gz`;
  const sourceNames = fs.readdirSync(source).sort();
  if (sourceNames.length !== 1 || sourceNames[0] !== expectedArchiveName) {
    fail(`source artifact must contain only ${expectedArchiveName}`);
  }
  const archivePath = path.join(source, expectedArchiveName);
  const archiveStat = fs.lstatSync(archivePath);
  if (!archiveStat.isFile() || archiveStat.isSymbolicLink()) {
    fail('source archive must be a regular file');
  }
  if (archiveStat.size === 0 || archiveStat.size > maxArchiveBytes) {
    fail('source archive has an invalid compressed size');
  }

  let archive;
  try {
    archive = zlib.gunzipSync(fs.readFileSync(archivePath), {
      maxOutputLength: maxTotalBytes + maxFiles * 512 + 1024,
    });
  } catch (error) {
    fail(`source archive is not a bounded gzip stream: ${error.message}`);
  }
  const {entries, totalBytes} = readTarEntries(archive, {
    maxFiles,
    maxFileBytes,
    maxTotalBytes,
  });
  const byPath = new Map(entries.map((entry) => [entry.relativePath, entry]));
  for (const required of REQUIRED_FILES) {
    const entry = byPath.get(required);
    if (entry === undefined) fail(`artifact is missing required file: ${required}`);
  }
  const iwad = byPath.get(APPROVED_IWAD_PATH);
  if (iwad === undefined) fail(`artifact is missing approved IWAD: ${APPROVED_IWAD_PATH}`);
  const iwadSha256 = crypto.createHash('sha256').update(iwad.contents).digest('hex');
  if (iwad.contents.length !== expectedIwadBytes || iwadSha256 !== expectedIwadSha256) {
    fail('bundled DOOM1.WAD does not match the approved shareware IWAD');
  }
  const bootstrap = byPath.get('flutter_bootstrap.js').contents.toString('utf8');
  if (!bootstrap.includes('"compileTarget":"dart2wasm"')) {
    fail('Flutter bootstrap has no dart2wasm target');
  }
  if (!bootstrap.includes('"renderer":"skwasm"')) {
    fail('Flutter bootstrap does not select skwasm');
  }
  if (bootstrap.includes('"compileTarget":"dart2js"')) {
    fail('Flutter bootstrap still contains a dart2js target');
  }
  if (!bootstrap.includes('"useLocalCanvasKit":true')) {
    fail('Flutter bootstrap still uses an external renderer CDN');
  }
  if (!byPath.get('_headers').contents.equals(Buffer.from(EXPECTED_HEADERS))) {
    fail('artifact _headers does not match the trusted deployment contract');
  }

  fs.mkdirSync(destination);
  for (const entry of entries) {
    const target = path.join(destination, entry.relativePath);
    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, entry.contents, {flag: 'wx', mode: 0o644});
  }
  return Object.freeze({
    fileCount: entries.length,
    totalBytes,
    iwadBytes: iwad.contents.length,
    iwadSha256,
  });
}

if (require.main === module) {
  const [, , command, source, destination, buildSha] = process.argv;
  if (command !== 'sanitize-archive' || !source || !destination || !buildSha) {
    console.error(
      'Usage: node preview-artifact-policy.cjs sanitize-archive SOURCE DEST BUILD_SHA',
    );
    process.exitCode = 2;
  } else {
    const result = sanitizeArtifactArchive(source, destination, buildSha);
    console.log(
      `Sanitized ${result.fileCount} static files (${result.totalBytes} bytes); ` +
      `approved IWAD ${result.iwadSha256}.`,
    );
  }
}

module.exports = {
  APPROVED_IWAD_BYTES,
  APPROVED_IWAD_PATH,
  APPROVED_IWAD_SHA256,
  EXPECTED_HEADERS,
  SOURCE_WORKFLOW_PATH,
  requireSinglePullRequestNumber,
  sanitizeArtifactArchive,
  validateCurrentPullRequest,
  validatePreviewSource,
  validatePreviewUrls,
};
