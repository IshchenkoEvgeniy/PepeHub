import { createServer } from 'node:http';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import worker, {hashToken} from '../services/sync-worker/src/index.ts';
import { SqliteDatabase } from './sqlite-adapter.ts';
mkdirSync('.local',{recursive:true});
const db=new SqliteDatabase('.local/dev.sqlite');
const settingsPath='.local/devices.json';
const settings=existsSync(settingsPath) ? JSON.parse(readFileSync(settingsPath,'utf8')) as {ownerId:string;devices:{id:string;name:string;token:string}[]} : {
  ownerId:randomUUID(),devices:['Windows','Android emulator'].map(name=>({id:randomUUID(),name,token:randomBytes(32).toString('base64url')}))
};
if(!existsSync(settingsPath)) writeFileSync(settingsPath,JSON.stringify(settings,null,2));
for(const d of settings.devices) await db.prepare('INSERT INTO devices(id,owner_id,token_hash) VALUES(?,?,?) ON CONFLICT(id) DO NOTHING').bind(d.id,settings.ownerId,await hashToken(d.token)).run();
const server=createServer(async(req,res)=>{
  try {
    let size=0; const chunks:Buffer[]=[];
    for await(const chunk of req) {
      size+=chunk.length;
      if(size>32768) {res.writeHead(413);res.end();return;}
      chunks.push(Buffer.from(chunk));
    }
    const request=new Request(`http://127.0.0.1:8787${req.url}`,{method:req.method,headers:req.headers as Record<string,string>,...(chunks.length?{body:Buffer.concat(chunks)}:{})});
    const response=await worker.fetch(request,{DB:db});
    res.writeHead(response.status,Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  } catch {res.writeHead(500);res.end('Local server error');}
});
server.listen(8787,'127.0.0.1',()=>console.log('PepeHub API: http://127.0.0.1:8787\nLocal device credentials: .local/devices.json (do not commit).'));
process.on('SIGINT',()=>server.close(()=>{db.close();process.exit(0);}));
