import {createServer} from 'node:http';
import {timingSafeEqual} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {WebSocketServer,WebSocket} from 'ws';

/** Ephemeral bounded routing only. No database, file staging or payload logs. */
export function createRelay({token,maxClients=128,maxPerAddress=16}:{token:string;maxClients?:number;maxPerAddress?:number}) {
  if(token.length<24)throw new Error('RELAY_TOKEN must contain at least 24 characters');
  const server=createServer((request,response)=>{
    response.writeHead(request.url==='/health'?200:404,{'Content-Type':'text/plain','Cache-Control':'no-store'});response.end(request.url==='/health'?'ok':'not found');
  });
  const ws=new WebSocketServer({noServer:true,maxPayload:200000,perMessageDeflate:false});
  const rooms=new Map<string,Map<string,WebSocket>>(),addresses=new Map<string,number>();
  const rate=new Map<WebSocket,{time:number;bytes:number;messages:number;alive:boolean}>();
  server.on('upgrade',(request,socket,head)=>{
    const supplied=Buffer.from((request.headers.authorization??'').replace(/^Bearer /,'')),expected=Buffer.from(token);
    const address=request.socket.remoteAddress??'';
    if(request.url!=='/v1/relay'||request.headers.origin||supplied.length!==expected.length||!timingSafeEqual(supplied,expected)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');return;
    }
    if(ws.clients.size>=maxClients||(addresses.get(address)??0)>=maxPerAddress){socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');return;}
    addresses.set(address,(addresses.get(address)??0)+1);
    let released=false;
    const release=()=>{
      if(released)return;released=true;
      const remaining=(addresses.get(address)??1)-1;if(remaining)addresses.set(address,remaining);else addresses.delete(address);
    };
    socket.once('close',release);socket.on('error',()=>{});
    ws.handleUpgrade(request,socket,head,client=>{
      let roomKey='',side='';
      rate.set(client,{time:Date.now(),bytes:0,messages:0,alive:true});
      const hello=setTimeout(()=>client.close(1008),5000);hello.unref();
      client.on('error',()=>{});
      client.on('pong',()=>{const state=rate.get(client);if(state)state.alive=true;});
      client.on('message',(data,isBinary)=>{
        const state=rate.get(client)!;
        if(Date.now()-state.time>=1000){state.time=Date.now();state.bytes=0;state.messages=0;}
        const size=Array.isArray(data)?data.reduce((n,b)=>n+b.length,0):data instanceof ArrayBuffer?data.byteLength:data.length;
        state.bytes+=size;state.messages++;
        if(state.bytes>16*1024*1024||state.messages>2000){client.close(1008);return;}
        if(!roomKey) {
          try {
            const value=JSON.parse(data.toString()) as {room:unknown;side:unknown};
            if(typeof value.room!=='string'||! /^[\w-]{43}=$/.test(value.room)||!['a','b'].includes(String(value.side)))throw new Error();
            const room=rooms.get(value.room)??new Map<string,WebSocket>();
            side=String(value.side);if(room.has(side))throw new Error();
            roomKey=value.room;room.set(side,client);rooms.set(roomKey,room);clearTimeout(hello);
            for(const other of room.values())other.send(JSON.stringify({op:'state',ready:room.size===2}));
          }catch{client.close(1008);}
          return;
        }
        const target=rooms.get(roomKey)?.get(side==='a'?'b':'a');
        if(target?.readyState!==WebSocket.OPEN)return;
        if(target.bufferedAmount>1024*1024){client.close(1013);target.close(1013);return;}
        target.send(data,{binary:isBinary});
      });
      client.on('close',()=>{
        clearTimeout(hello);rate.delete(client);
        release();
        const room=rooms.get(roomKey);if(room?.get(side)!==client)return;
        room.delete(side);if(!room.size)rooms.delete(roomKey);
        else for(const other of room.values())if(other.readyState===WebSocket.OPEN)other.send(JSON.stringify({op:'state',ready:false}));
      });
    });
  });
  const heartbeat=setInterval(()=>{
    for(const [client,state] of rate){if(!state.alive)client.terminate();else{state.alive=false;client.ping();}}
  },30000);heartbeat.unref();
  return {server,clients:()=>ws.clients.size,rooms:()=>rooms.size,close:async()=>{
    clearInterval(heartbeat);for(const client of ws.clients)client.terminate();
    await new Promise<void>(resolve=>ws.close(()=>resolve()));
    await new Promise<void>(resolve=>server.close(()=>resolve()));
  }};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  const relay=createRelay({token:process.env.RELAY_TOKEN??''});
  const port=Number(process.env.PORT??42593),host=process.env.HOST??'127.0.0.1';
  relay.server.listen(port,host,()=>process.stdout.write(`PepeHub relay listening on ${host}:${port}\n`));
  for(const signal of ['SIGINT','SIGTERM'] as const)process.on(signal,()=>{void relay.close().then(()=>process.exit(0));});
}
