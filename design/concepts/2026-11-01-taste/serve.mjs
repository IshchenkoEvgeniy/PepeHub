import {createServer} from 'node:http';
import {createReadStream,statSync} from 'node:fs';
import {dirname,resolve,sep,extname} from 'node:path';
import {fileURLToPath} from 'node:url';
const dir=dirname(fileURLToPath(import.meta.url));
const root=resolve(dir,'../../..');
const prefix='/design/concepts/2026-11-01-taste/';
const mime={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.ttf':'font/ttf','.svg':'image/svg+xml','.png':'image/png'};
const server=createServer((req,res)=>{
  try{
    const pathname=decodeURIComponent(new URL(req.url,'http://localhost').pathname);
    if(pathname==='/'){res.writeHead(302,{location:prefix});res.end();return}
    // Serve only this concept and the two existing local fonts it uses.
    const font=/^\/apps\/pepehub\/assets\/fonts\/(Onest|CormorantGaramond)\.ttf$/.test(pathname);
    if(!pathname.startsWith(prefix)&&!font){res.writeHead(404);res.end();return}
    let file=resolve(root,'.'+pathname);
    if(!file.startsWith(root+sep)){res.writeHead(403);res.end();return}
    if(statSync(file).isDirectory())file=resolve(file,'index.html');
    res.writeHead(200,{'content-type':mime[extname(file)]||'application/octet-stream','cache-control':'no-store'});
    createReadStream(file).pipe(res);
  }catch{res.writeHead(404);res.end('Not found')}
});
server.listen(5179,'127.0.0.1',()=>console.log('PepeHub concept: http://127.0.0.1:5179'));
