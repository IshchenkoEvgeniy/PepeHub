import { createPrivateKey, createPublicKey, generateKeyPairSync } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const projectRoot = fileURLToPath(new URL('../', import.meta.url));
export const signingKeyPath = path.join(projectRoot, '.local', 'update-signing', 'private.pem');
export const publicKeyPath = path.join(projectRoot, 'apps', 'pepehub', 'lib', 'updates', 'update_trust.dart');

export function initializeUpdateKey(): string {
  if (!existsSync(signingKeyPath)) {
    if (existsSync(publicKeyPath)) throw new Error('Restore the existing private update key; never silently replace the trusted release key.');
    mkdirSync(path.dirname(signingKeyPath), {recursive: true});
    const keys = generateKeyPairSync('ed25519');
    writeFileSync(signingKeyPath, keys.privateKey.export({type: 'pkcs8', format: 'pem'}), {flag: 'wx', mode: 0o600});
  }
  const key = createPrivateKey(readFileSync(signingKeyPath));
  if (key.asymmetricKeyType !== 'ed25519') throw new Error('Expected the original Ed25519 signing key');
  const raw = createPublicKey(key).export({type: 'spki', format: 'der'}).subarray(-32).toString('base64');
  const source = `// Public verification key only. Back up .local/update-signing/private.pem separately.\nconst updatePublicKey = '${raw}';\nconst defaultUpdateFeed = 'https://github.com/IshchenkoEvgeniy/PepeHub-Releases/releases/latest/download/update.json';\n`;
  if (existsSync(publicKeyPath) && readFileSync(publicKeyPath, 'utf8').match(/const updatePublicKey\s*=\s*'([^']+)'/s)?.[1] !== raw) throw new Error('Private key does not match the verification key already embedded in the app.');
  mkdirSync(path.dirname(publicKeyPath), {recursive: true});
  if (!existsSync(publicKeyPath)) writeFileSync(publicKeyPath, source);
  return raw;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  initializeUpdateKey();
  console.log('Update signing key initialized. Private key stays in ignored .local/update-signing; only the public key is embedded.');
}
