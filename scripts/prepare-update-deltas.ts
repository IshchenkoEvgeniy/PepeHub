import {createHash, createPublicKey, verify} from 'node:crypto';
import {existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync, createWriteStream} from 'node:fs';
import {pipeline} from 'node:stream/promises';
import {Readable, Transform} from 'node:stream';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createDeltaPackage} from './delta-package.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha = (file: string) => createHash('sha256').update(readFileSync(file)).digest('hex');
interface Artifact {file: string; sha256: string; bytes: number; versionCode: number; format: string; deltas?: unknown[]}
interface Catalog {version: string; build: number; artifacts: Record<string, Artifact>}
const platforms = ['windows-x64', 'android-arm64'];
const filename = (platform: string) => platform === 'windows-x64' ? 'PepeHub-windows-x64.zip' : 'PepeHub-android-arm64.apk';

async function obtainBase(current: Catalog): Promise<{directory: string; catalog: Catalog} | null> {
  try {
    const response = await fetch('https://github.com/IshchenkoEvgeniy/PepeHub-Releases/releases/latest/download/update.json', {signal: AbortSignal.timeout(30000)});
    if (!response.ok) return null;
    const envelope = await response.text();
    if (envelope.length > 65536) return null;
    const outer = JSON.parse(envelope), payload = Buffer.from(outer.payload, 'base64');
    const trust = readFileSync(path.join(root, 'apps/pepehub/lib/updates/update_trust.dart'), 'utf8');
    const raw = Buffer.from(trust.match(/const updatePublicKey\s*=\s*'([^']+)'/s)![1], 'base64');
    const key = createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]), format: 'der', type: 'spki'});
    if (!verify(null, payload, key, Buffer.from(outer.signature, 'base64'))) throw new Error('Base release signature mismatch');
    const signed = JSON.parse(payload.toString('utf8'));
    if (signed.schema !== 1 || signed.appId !== 'app.pepehub.pepehub' || signed.channel !== 'stable' || !Number.isInteger(signed.build) || signed.build < 1 || signed.build >= current.build) return null;
    const directory = path.join(root, 'dist', 'delta-bases', String(signed.build)); mkdirSync(directory, {recursive: true});
    const artifacts: Record<string, Artifact> = {};
    for (const platform of platforms) {
      const item = signed.artifacts[platform], name = filename(platform), file = path.join(directory, name);
      const url = new URL(item.url);
      if (url.protocol !== 'https:' || url.hostname !== 'github.com' || !url.pathname.startsWith('/IshchenkoEvgeniy/PepeHub-Releases/releases/download/') || !/^[a-f0-9]{64}$/.test(item.sha256) || !Number.isInteger(item.bytes) || item.bytes < 1 || item.bytes > 536870912) throw new Error('Invalid base package');
      if (!existsSync(file) || statSync(file).size !== item.bytes || sha(file) !== item.sha256) {
        const downloaded = await fetch(url, {signal: AbortSignal.timeout(180000)});
        if (!downloaded.ok || !downloaded.body) throw new Error('Cannot download delta base');
        let bytes = 0;
        const bounded = new Transform({transform(chunk: Buffer, _encoding, callback) { bytes += chunk.length; callback(bytes > item.bytes ? new Error('Oversized delta base') : null, chunk); }});
        const partial = `${file}.part`;
        await pipeline(Readable.fromWeb(downloaded.body as never), bounded, createWriteStream(partial));
        if (bytes !== item.bytes || sha(partial) !== item.sha256) throw new Error('Downloaded base hash mismatch');
        // Verified package bytes only; never replace a user's installation.
        writeFileSync(file, readFileSync(partial)); unlinkSync(partial);
      }
      artifacts[platform] = {file: name, sha256: item.sha256, bytes: item.bytes, versionCode: item.versionCode, format: item.format};
    }
    return {directory, catalog: {version: signed.version, build: signed.build, artifacts}};
  } catch (error) { console.log(`Delta base unavailable; full packages remain available (${error instanceof Error ? error.message : 'network error'}).`); return null; }
}

export async function prepareUpdateDeltas(directory: string) {
  const catalogPath = path.join(directory, 'artifacts.json'), current: Catalog = JSON.parse(readFileSync(catalogPath, 'utf8'));
  const online = path.dirname(directory);
  const bases: {directory: string; catalog: Catalog}[] = [];
  for (const entry of readdirSync(online, {withFileTypes: true})) {
    const metadata = path.join(online, entry.name, 'artifacts.json');
    if (!entry.isDirectory() || !existsSync(metadata)) continue;
    try { const catalog: Catalog = JSON.parse(readFileSync(metadata, 'utf8')); if (Number.isInteger(catalog.build) && catalog.build > 0 && catalog.build < current.build) bases.push({directory: path.dirname(metadata), catalog}); } catch { /* A partial build is not a delta base. */ }
  }
  bases.sort((a, b) => b.catalog.build - a.catalog.build);
  if (!bases.length) { const remote = await obtainBase(current); if (remote) bases.push(remote); }
  const dart = path.join(root, '.tools/flutter/bin/cache/dart-sdk/bin', process.platform === 'win32' ? 'dart.exe' : 'dart');
  const packages = path.join(root, 'apps/pepehub/.dart_tool/package_config.json');
  for (const platform of platforms) {
    const target = current.artifacts[platform], targetPath = path.join(directory, filename(platform));
    target.deltas = [];
    if (sha(targetPath) !== target.sha256) throw new Error('Target package changed before delta generation');
    const uniqueBases = bases.filter((base, index) => bases.findIndex(other => other.catalog.build === base.catalog.build) === index).slice(0, 2);
    for (const base of uniqueBases) {
      const old = base.catalog.artifacts[platform], oldPath = path.join(base.directory, filename(platform));
      if (!old || old.bytes > 536870912 || target.bytes > 536870912 || !existsSync(oldPath) || statSync(oldPath).size !== old.bytes || sha(oldPath) !== old.sha256) continue;
      const file = `PepeHub-${platform}-from-${base.catalog.build}.pdelta`, output = path.join(directory, file);
      const delta = createDeltaPackage(oldPath, targetPath, output);
      if (delta.bytes >= target.bytes * .9) { unlinkSync(output); continue; }
      const verified = execFileSync(dart, [`--packages=${packages}`, path.join(root, 'apps/pepehub/tool/verify_update_delta.dart'), oldPath, output, targetPath], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000});
      if (JSON.parse(verified.trim()).verified !== true) throw new Error('Delta reconstruction failed');
      target.deltas.push({...delta, file, fromBuild: base.catalog.build});
      console.log(`Verified ${platform} delta from ${base.catalog.build}: ${(delta.bytes / 1048576).toFixed(2)} MiB (${(delta.bytes * 100 / target.bytes).toFixed(1)}% of full package)`);
    }
  }
  writeFileSync(catalogPath, JSON.stringify(current, null, 2));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error('Pass the prepared release directory');
  await prepareUpdateDeltas(path.resolve(process.argv[2]));
}
