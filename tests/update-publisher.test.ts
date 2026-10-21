import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash, generateKeyPairSync, verify} from 'node:crypto';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {createUpdateManifest} from '../scripts/publish-update.ts';
import {projectRoot} from '../scripts/update-key.ts';

test('publisher signs exact payload, pins immutable artifact URLs and refuses changed packages', async()=>{
  const parent=path.join(projectRoot,'.local'); mkdirSync(parent,{recursive:true});
  const root=mkdtempSync(path.join(parent,'update-publisher-test-'));
  try {
    const keys=generateKeyPairSync('ed25519'), artifacts:Record<string,unknown>={};
    for(const platform of ['windows-x64','android-arm64']) {
      const file=platform==='windows-x64'?'PepeHub-windows-x64.zip':'PepeHub-android-arm64.apk';
      const content=Buffer.from(platform);writeFileSync(path.join(root,file),content);
      artifacts[platform]={file,sha256:createHash('sha256').update(content).digest('hex'),bytes:content.length,
        versionCode:platform==='windows-x64'?52:2052,format:platform==='windows-x64'?'zip':'apk'};
    }
    writeFileSync(path.join(root,'artifacts.json'),JSON.stringify({version:'0.21.0',build:52,artifacts}));
    const result=await createUpdateManifest(root,'Изменения',new Date('2026-10-17T00:00:00Z'),keys.privateKey);
    assert.equal(result.tag,'v0.21.0-52');
    const signed=JSON.parse(readFileSync(path.join(root,'update.json'),'utf8'));
    const payload=Buffer.from(signed.payload,'base64'),signature=Buffer.from(signed.signature,'base64');
    assert.equal(verify(null,payload,keys.publicKey,signature),true);
    const manifest=JSON.parse(payload.toString('utf8'));
    assert.equal(manifest.artifacts['android-arm64'].versionCode,2052);
    assert.ok(manifest.artifacts['windows-x64'].url.includes('/releases/download/v0.21.0-52/'));
    assert.ok(!JSON.stringify(signed).includes('PRIVATE KEY'));
    payload[10]^=1;assert.equal(verify(null,payload,keys.publicKey,signature),false);
    writeFileSync(path.join(root,'PepeHub-android-arm64.apk'),'Changed package');
    await assert.rejects(()=>createUpdateManifest(root,'Changes',new Date(),keys.privateKey),/changed/);
  } finally { assert.ok(root.startsWith(parent+path.sep));rmSync(root,{recursive:true,force:true}); }
});
