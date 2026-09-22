// Isolated test-only server: known fixture credentials, memory database, loopback only.
import {createServer} from 'node:http';
import {SqliteDatabase} from './sqlite-adapter.ts';
import worker,{hashToken} from '../services/sync-worker/src/index.ts';
const db=new SqliteDatabase();
for(const [id,token] of [['11111111-1111-4111-8111-111111111111','a'],['22222222-2222-4222-8222-222222222222','b']]) {
  await db.prepare('INSERT INTO devices(id,owner_id,token_hash) VALUES(?,?,?)').bind(id,'e2e-owner',await hashToken(token.repeat(64))).run();
}
const server=createServer(async(req,res)=>{
  const chunks:Buffer[]=[];for await(const chunk of req)chunks.push(Buffer.from(chunk));
  const response=await worker.fetch(new Request('http://localhost'+req.url,{method:req.method,headers:req.headers as Record<string,string>,...(chunks.length?{body:Buffer.concat(chunks)}:{})}),{DB:db});
  res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
});
server.listen(0,'127.0.0.1',()=>{const address=server.address();if(address && typeof address!=='string')console.log(`READY:${address.port}`);});
