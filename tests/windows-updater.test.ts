import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync} from 'node:fs';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {projectRoot} from '../scripts/update-key.ts';

const ps=path.join(process.env.SystemRoot??'C:\\Windows','System32/WindowsPowerShell/v1.0/powershell.exe');
const helper=path.join(projectRoot,'apps/pepehub/assets/updater/install-windows.ps1');
const compiler=path.join(process.env.SystemRoot??'C:\\Windows','Microsoft.NET/Framework64/v4.0.30319/csc.exe');
const hash=(file:string)=>createHash('sha256').update(readFileSync(file)).digest('hex');

test('real Windows helper waits, updates only managed files, preserves library and can restore backup', {skip:process.platform!=='win32',timeout:120000}, async()=>{
  const parent=path.join(projectRoot,'.local');mkdirSync(parent,{recursive:true});
  const root=mkdtempSync(path.join(parent,"updater-test ' & "));
  const oldExe=path.join(root,'old.exe'),newExe=path.join(root,'new.exe');
  const compile=(target:string,build:number)=>{
    const source=target+'.cs';
    writeFileSync(source,`using System.Reflection;[assembly:AssemblyFileVersion("0.21.0.${build}")][assembly:AssemblyInformationalVersion("0.21.0+${build}")]class App{static void Main(){System.Threading.Thread.Sleep(30000);}}`);
    execFileSync(compiler,['/nologo','/target:winexe','/out:'+target,source],{windowsHide:true,stdio:'pipe'});
  };
  let application:ReturnType<typeof spawn>|undefined;
  let updater:ReturnType<typeof spawn>|undefined;
  try {
    compile(oldExe,51);compile(newExe,52);
    const fixture=(name:string,blocked=false)=>{
      const install=path.join(root,name,'install'),transaction=path.join(root,name,'transaction'),stage=path.join(transaction,'stage');
      mkdirSync(path.join(install,'data'),{recursive:true});mkdirSync(path.join(stage,'data'),{recursive:true});
      copyFileSync(oldExe,path.join(install,'pepehub.exe'));copyFileSync(newExe,path.join(stage,'pepehub.exe'));
      writeFileSync(path.join(install,'flutter_windows.dll'),'old decoder');writeFileSync(path.join(stage,'flutter_windows.dll'),'new decoder');
      writeFileSync(path.join(install,'data/a.txt'),'old asset');writeFileSync(path.join(stage,'data/a.txt'),'new asset');
      writeFileSync(path.join(install,'data/obsolete.txt'),'old managed asset');
      writeFileSync(path.join(install,'.pepehub-update-receipt.json'),JSON.stringify({version:'0.21.0+51',files:['pepehub.exe','flutter_windows.dll','data/a.txt','data/obsolete.txt']}));
      writeFileSync(path.join(install,'library.sqlite'),'USER DATABASE');writeFileSync(path.join(install,'book.epub'),'USER BOOK');
      const names=['data/a.txt','pepehub.exe','flutter_windows.dll'];
      if(blocked){writeFileSync(path.join(install,'data/block'),'user file blocks directory');mkdirSync(path.join(stage,'data/block'));writeFileSync(path.join(stage,'data/block/child.bin'),'new');names.splice(1,0,'data/block/child.bin');}
      const files=names.map(name=>({path:name,sha256:hash(path.join(stage,name)),bytes:readFileSync(path.join(stage,name)).length}));
      const config={installDir:install,stageDir:stage,transactionDir:transaction,parentPid:0,expectedVersion:'0.21.0+52',files};
      const configPath=path.join(transaction,'transaction.json');writeFileSync(configPath,JSON.stringify(config));
      return {install,transaction,stage,config,configPath};
    };
    const f=fixture('success');
    application=spawn(path.join(f.install,'pepehub.exe'),[],{windowsHide:true,stdio:'ignore'});
    f.config.parentPid=application.pid!;writeFileSync(f.configPath,JSON.stringify(f.config));
    updater=spawn(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helper,'-ConfigPath',f.configPath,'-NoLaunch'],{windowsHide:true,stdio:'ignore'});
    const done=new Promise<number|null>((resolve,reject)=>{updater!.on('exit',resolve);updater!.on('error',reject);});
    for(let i=0;i<100&&!existsSync(path.join(f.transaction,'ready'));i++){if(existsSync(path.join(f.transaction,'failure.txt')))throw new Error(readFileSync(path.join(f.transaction,'failure.txt'),'utf8'));await delay(50);}
    assert.ok(existsSync(path.join(f.transaction,'ready')));assert.equal(hash(path.join(f.install,'pepehub.exe')),hash(oldExe));
    application.kill();await new Promise<void>(resolve=>application!.once('exit',()=>resolve()));application=undefined;
    assert.equal(await done,0);assert.equal(hash(path.join(f.install,'pepehub.exe')),hash(newExe));
    assert.equal(readFileSync(path.join(f.install,'data/a.txt'),'utf8'),'new asset');
    assert.equal(existsSync(path.join(f.install,'data/obsolete.txt')),false);
    assert.equal(readFileSync(path.join(f.install,'library.sqlite'),'utf8'),'USER DATABASE');
    assert.equal(readFileSync(path.join(f.install,'book.epub'),'utf8'),'USER BOOK');
    execFileSync(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helper,'-ConfigPath',f.configPath,'-Rollback','-NoLaunch'],{windowsHide:true,stdio:'pipe'});
    assert.equal(hash(path.join(f.install,'pepehub.exe')),hash(oldExe));
    assert.equal(readFileSync(path.join(f.install,'data/obsolete.txt'),'utf8'),'old managed asset');
    const broken=fixture('rollback',true);
    assert.throws(()=>execFileSync(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helper,'-ConfigPath',broken.configPath,'-NoLaunch'],{windowsHide:true,stdio:'pipe'}));
    assert.equal(JSON.parse(readFileSync(path.join(broken.transaction,'status.json'),'utf8')).state,'rolledBack');
    assert.equal(readFileSync(path.join(broken.install,'data/a.txt'),'utf8'),'old asset');
    assert.equal(hash(path.join(broken.install,'pepehub.exe')),hash(oldExe));
    const unsafe=fixture('unsafe');unsafe.config.files.push({path:'../escape.dll',sha256:'a'.repeat(64),bytes:1});writeFileSync(unsafe.configPath,JSON.stringify(unsafe.config));
    assert.throws(()=>execFileSync(ps,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',helper,'-ConfigPath',unsafe.configPath,'-NoLaunch'],{windowsHide:true,stdio:'pipe'}));
    assert.equal(existsSync(path.join(root,'unsafe/escape.dll')),false);
    assert.equal(hash(path.join(unsafe.install,'pepehub.exe')),hash(oldExe));
  } finally {
    for(const child of [application,updater]) {
      if(child&&child.exitCode===null&&child.signalCode===null){const closed=new Promise(resolve=>child.once('exit',resolve));child.kill();await closed;}
    }
    assert.ok(root.startsWith(parent+path.sep));rmSync(root,{recursive:true,force:true,maxRetries:20,retryDelay:100});
  }
});
