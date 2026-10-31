import { createHash, createPrivateKey, sign, type KeyObject } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream, existsSync, openAsBlob, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { initializeUpdateKey, projectRoot, signingKeyPath } from './update-key.ts';

const owner = 'IshchenkoEvgeniy', repo = 'PepeHub-Releases';
interface Delta {file: string; sha256: string; bytes: number; format: string; baseSha256: string; baseBytes: number; fromBuild: number}
interface Artifact {file: string; sha256: string; bytes: number; versionCode: number; format: string; deltas?: Delta[]}
type PublishedArtifact = Omit<Artifact, 'file' | 'deltas'> & {url: string; deltas?: Array<Omit<Delta, 'file'> & {url: string}>};
export async function createUpdateManifest(directory: string, notes: string, now = new Date(), signingKey?: KeyObject) {
  if (!signingKey) initializeUpdateKey();
  const input = JSON.parse(readFileSync(path.join(directory, 'artifacts.json'), 'utf8')) as {version: string; build: number; artifacts: Record<string, Artifact>};
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(input.version) || !Number.isInteger(input.build) || input.build < 1 || input.build > 999999 || notes.length > 8000) throw new Error('Invalid release version/notes');
  const tag = `v${input.version}-${input.build}`;
  const artifacts: Record<string, PublishedArtifact> = {};
  const patchFiles: string[] = [];
  if (Object.keys(input.artifacts).sort().join(',') !== 'android-arm64,windows-x64') throw new Error('Both verified platform packages are required');
  for (const [platform, item] of Object.entries(input.artifacts)) {
    const filename = platform === 'windows-x64' ? 'PepeHub-windows-x64.zip' : 'PepeHub-android-arm64.apk';
    if (item.file !== filename || item.format !== (platform === 'windows-x64' ? 'zip' : 'apk') ||
        item.versionCode !== input.build + (platform === 'android-arm64' ? 2000 : 0)) throw new Error('Unexpected package metadata');
    const file = path.join(directory, filename), hash = createHash('sha256');
    for await (const chunk of createReadStream(file)) hash.update(chunk);
    if (hash.digest('hex') !== item.sha256 || statSync(file).size !== item.bytes || item.bytes < 1 || item.bytes > 2147483648) throw new Error('Package changed after verification');
    artifacts[platform] = {url: `https://github.com/${owner}/${repo}/releases/download/${tag}/${filename}`,
      sha256: item.sha256, bytes: item.bytes, versionCode: item.versionCode, format: item.format};
    if (item.deltas?.length) {
      if (item.deltas.length > 3 || new Set(item.deltas.map(d => d.fromBuild)).size !== item.deltas.length) throw new Error('Too many or duplicate delta bases');
      artifacts[platform].deltas = [];
      for (const delta of item.deltas) {
        const name = `PepeHub-${platform}-from-${delta.fromBuild}.pdelta`;
        if (delta.file !== name || delta.format !== 'pepe-delta-v1' || !Number.isInteger(delta.fromBuild) || delta.fromBuild < 1 || delta.fromBuild >= input.build || !Number.isInteger(delta.bytes) || delta.bytes < 1 || delta.bytes >= item.bytes || !Number.isInteger(delta.baseBytes) || delta.baseBytes < 1 || delta.baseBytes > 2147483648 || !/^[a-f0-9]{64}$/.test(delta.baseSha256) || !/^[a-f0-9]{64}$/.test(delta.sha256)) throw new Error('Invalid delta package metadata');
        const patch = path.join(directory, name), checksum = createHash('sha256');
        for await (const chunk of createReadStream(patch)) checksum.update(chunk);
        if (checksum.digest('hex') !== delta.sha256 || statSync(patch).size !== delta.bytes) throw new Error('Delta changed after verification');
        const {file: _localFile, ...metadata} = delta;
        artifacts[platform].deltas!.push({...metadata, url: `https://github.com/${owner}/${repo}/releases/download/${tag}/${name}`});
        patchFiles.push(name);
      }
    }
  }
  const payload = Buffer.from(JSON.stringify({schema: 1, appId: 'app.pepehub.pepehub', channel: 'stable',
    version: input.version, build: input.build, publishedAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + 180 * 86400000).toISOString(), notes, artifacts}));
  const signature = sign(null, payload, signingKey ?? createPrivateKey(readFileSync(signingKeyPath)));
  const envelope = JSON.stringify({payload: payload.toString('base64'), signature: signature.toString('base64')});
  writeFileSync(path.join(directory, 'update.json'), envelope);
  return {tag, version: input.version, build: input.build, files: ['PepeHub-windows-x64.zip', 'PepeHub-android-arm64.apk', ...patchFiles, 'update.json']};
}
function githubCredential(): string {
  const output = execFileSync('git', ['credential', 'fill'], {input: 'protocol=https\nhost=github.com\n\n', encoding: 'utf8',
    env: {...process.env, GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never'}, stdio: ['pipe', 'pipe', 'pipe'], timeout: 15000});
  const token = output.split('\n').find(line => line.startsWith('password='))?.slice(9).trim();
  if (!token) throw new Error('GitHub credentials are unavailable. Sign in to Git Credential Manager.');
  return token;
}
async function publish(directory: string, release: Awaited<ReturnType<typeof createUpdateManifest>>, notes: string) {
  const token = githubCredential();
  const headers = {Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json',
    'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'PepeHub release publisher'};
  async function api(route: string, method = 'GET', body?: unknown, allow404 = false): Promise<any> {
    const response = await fetch(`https://api.github.com${route}`, {method, headers,
      ...(body === undefined ? {} : {body: JSON.stringify(body)}), signal: AbortSignal.timeout(30000)});
    if (allow404 && response.status === 404) return null;
    if (!response.ok) throw new Error(`GitHub ${method} ${route}: HTTP ${response.status}`);
    if (response.status === 204) return null;
    return response.json();
  }
  if ((await api('/user')).login.toLowerCase() !== owner.toLowerCase()) throw new Error('GitHub account does not match the release owner');
  let repository = await api(`/repos/${owner}/${repo}`, 'GET', undefined, true);
  if (!repository) repository = await api('/user/repos', 'POST', {name: repo, private: false,
    description: 'PepeHub for Windows and Android — compiled releases and signed update feed. Application source code is stored separately.',
    auto_init: true, has_issues: false, has_projects: false, has_wiki: false});
  if (repository.private || repository.owner.login.toLowerCase() !== owner.toLowerCase()) throw new Error('Expected the public binary release repository');
  const latest = await api(`/repos/${owner}/${repo}/releases/latest`, 'GET', undefined, true);
  const previous = latest?.tag_name?.match(/^v(\d+\.\d+\.\d+)-(\d+)$/);
  const previousBuild = previous?.[2];
  if (previousBuild && Number(previousBuild) >= release.build) throw new Error('Increase the pubspec build number before publishing another update');
  if (previous) {
    const older = previous[1].split('.').map(Number), newer = release.version.split('.').map(Number);
    const difference = newer.map((part, i) => part - older[i]).find(part => part !== 0) ?? 0;
    if (difference < 0) throw new Error('Refusing to publish a lower application version');
  }
  let draft = await api(`/repos/${owner}/${repo}/releases/tags/${release.tag}`, 'GET', undefined, true);
  if (draft && !draft.draft) throw new Error('Published versions are immutable; increase the build number');
  if (!draft) draft = await api(`/repos/${owner}/${repo}/releases`, 'POST', {tag_name: release.tag,
    name: `PepeHub ${release.version} (build ${release.build})`, body: notes, draft: true, prerelease: false});
  for (const name of release.files) {
    const existing = draft.assets.find((asset: {name: string}) => asset.name === name);
    if (existing) await api(`/repos/${owner}/${repo}/releases/assets/${existing.id}`, 'DELETE');
    console.log(`Uploading ${name} (${(statSync(path.join(directory, name)).size / 1048576).toFixed(1)} MiB)...`);
    const blob = await openAsBlob(path.join(directory, name));
    const response = await fetch(`https://uploads.github.com/repos/${owner}/${repo}/releases/${draft.id}/assets?name=${encodeURIComponent(name)}`,
      {method: 'POST', headers: {...headers, 'Content-Type': name.endsWith('.json') ? 'application/json' : 'application/octet-stream'},
        body: blob, signal: AbortSignal.timeout(600000)});
    if (!response.ok) throw new Error(`GitHub upload ${name}: HTTP ${response.status}. Draft retained for retry.`);
  }
  const published = await api(`/repos/${owner}/${repo}/releases/${draft.id}`, 'PATCH', {draft: false, make_latest: 'true'});
  console.log(`Published: ${published.html_url}`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const version = readFileSync(path.join(projectRoot, 'apps/pepehub/pubspec.yaml'), 'utf8').match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/m);
    if (!version) throw new Error('Invalid pubspec version');
    const directory = path.join(projectRoot, 'dist', 'online', `${version[1]}-${version[2]}`);
    const notes = existsSync(path.join(directory, 'notes.md')) ? readFileSync(path.join(directory, 'notes.md'), 'utf8') : `Обновление PepeHub ${version[1]}, сборка ${version[2]}.`;
    const release = await createUpdateManifest(directory, notes);
    console.log(`Signed update manifest ready: ${directory}`);
    if (process.argv.includes('--publish')) await publish(directory, release, notes);
    else console.log('Nothing uploaded. Use --publish after reviewing the packages and notes.');
  } catch (error) { console.error(error instanceof Error ? error.message : 'Release preparation failed'); process.exitCode = 1; }
}
