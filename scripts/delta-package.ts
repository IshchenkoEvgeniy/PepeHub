import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync, statSync} from 'node:fs';
import {gzipSync} from 'node:zlib';

export const deltaFormat = 'pepe-delta-v1';
const digest = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex');
const gear = new Uint32Array(256);
let seed = 0x9e3779b9;
for (let i = 0; i < gear.length; i++) { seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5; gear[i] = seed >>> 0; }

function* chunks(bytes: Buffer): Generator<{offset: number; length: number; hash: string}> {
  let start = 0, rolling = 0;
  for (let i = 0; i < bytes.length; i++) {
    rolling = ((rolling << 1) + gear[bytes[i]]) >>> 0;
    const length = i + 1 - start;
    if (length >= 4096 && ((rolling & 16383) === 0 || length >= 65536)) {
      yield {offset: start, length, hash: `${length}:${digest(bytes.subarray(start, i + 1))}`};
      start = i + 1; rolling = 0;
    }
  }
  if (start < bytes.length) yield {offset: start, length: bytes.length - start, hash: `${bytes.length - start}:${digest(bytes.subarray(start))}`};
}

/** Content-defined COPY/literal instructions over exact signed package bytes. */
export function createDeltaPackage(basePath: string, targetPath: string, output: string) {
  for (const file of [basePath, targetPath]) if (statSync(file).size < 1 || statSync(file).size > 536870912) throw new Error('Delta generation supports packages up to 512 MiB');
  const base = readFileSync(basePath), target = readFileSync(targetPath);
  const index = new Map<string, {offset: number; length: number}>();
  for (const chunk of chunks(base)) if (!index.has(chunk.hash)) index.set(chunk.hash, chunk);
  const operations: Buffer[] = [];
  let copyOffset = 0, copyLength = 0, literalStart = 0, literalLength = 0;
  const flushCopy = () => {
    if (!copyLength) return;
    const command = Buffer.alloc(13); command[0] = 0; command.writeBigUInt64LE(BigInt(copyOffset), 1); command.writeUInt32LE(copyLength, 9);
    operations.push(command); copyLength = 0;
  };
  const flushLiteral = () => {
    if (!literalLength) return;
    const command = Buffer.alloc(5); command[0] = 1; command.writeUInt32LE(literalLength, 1);
    operations.push(command, target.subarray(literalStart, literalStart + literalLength)); literalLength = 0;
  };
  for (const chunk of chunks(target)) {
    const found = index.get(chunk.hash);
    if (found) {
      flushLiteral();
      if (copyLength && copyOffset + copyLength !== found.offset) flushCopy();
      if (!copyLength) copyOffset = found.offset;
      copyLength += found.length;
    } else {
      flushCopy();
      if (literalLength + chunk.length > 1048576) flushLiteral();
      if (!literalLength) literalStart = chunk.offset;
      literalLength += chunk.length;
    }
  }
  flushCopy(); flushLiteral(); operations.push(Buffer.from([255]));
  const details = {version: 1, baseSha256: digest(base), baseBytes: base.length, targetSha256: digest(target), targetBytes: target.length};
  const header = Buffer.from(JSON.stringify(details));
  const prefix = Buffer.alloc(12); prefix.write('PEPEDLT1'); prefix.writeUInt32LE(header.length, 8);
  const patch = Buffer.concat([prefix, header, gzipSync(Buffer.concat(operations), {level: 9})]);
  writeFileSync(output, patch);
  return {format: deltaFormat, sha256: digest(patch), bytes: patch.length, baseSha256: details.baseSha256, baseBytes: details.baseBytes};
}
