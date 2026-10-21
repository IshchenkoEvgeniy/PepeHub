import {test} from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {WebSocket} from 'ws';
import {createRelay} from '../services/relay/server.ts';
import {connect} from 'node:net';

test('failed authenticated upgrade releases its per-address connection slot',async()=>{
  const token='s'.repeat(32),relay=createRelay({token,maxPerAddress:1});
  relay.server.listen(0,'127.0.0.1');await once(relay.server,'listening');
  const address=relay.server.address();assert.ok(address&&typeof address!=='string');
  let client:WebSocket|undefined;
  try {
    const raw=connect(address.port,'127.0.0.1');await once(raw,'connect');raw.resume();
    const closed=once(raw,'close');
    raw.end(`GET /v1/relay HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nAuthorization: Bearer ${token}\r\nSec-WebSocket-Key: invalid\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    await closed;
    client=new WebSocket(`ws://127.0.0.1:${address.port}/v1/relay`,{headers:{Authorization:`Bearer ${token}`}});
    await once(client,'open');
  }finally{client?.terminate();await relay.close();}
});

test('relay authenticates, isolates opaque rooms and discards sessions on disconnect',async()=>{
  const token='a'.repeat(32),relay=createRelay({token});
  relay.server.listen(0,'127.0.0.1');await once(relay.server,'listening');
  const address=relay.server.address();assert.ok(address&&typeof address!=='string');
  const url=`ws://127.0.0.1:${address.port}/v1/relay`,all:WebSocket[]=[];
  const open=async(room:string,side:string)=>{
    const socket=new WebSocket(url,{headers:{Authorization:`Bearer ${token}`}});all.push(socket);await once(socket,'open');
    const state=once(socket,'message');socket.send(JSON.stringify({room,side}));await state;return socket;
  };
  try {
    const denied=new WebSocket(url,{headers:{Authorization:'Bearer wrong'}});denied.on('error',()=>{});all.push(denied);
    await assert.rejects(once(denied,'open'));
    const room='x'.repeat(43)+'=',other='y'.repeat(43)+'=';
    const a=await open(room,'a');const ready=once(a,'message');const b=await open(room,'b');assert.equal(JSON.parse((await ready)[0].toString()).ready,true);
    const c=await open(other,'a');let cross=0;c.on('message',()=>cross++);
    const opaque=Buffer.from([0,255,13,10,91,22]);const delivered=once(b,'message');a.send(opaque);assert.deepEqual(Buffer.from((await delivered)[0]),opaque);assert.equal(cross,0);
    const offline=once(a,'message');b.close();assert.equal(JSON.parse((await offline)[0].toString()).ready,false);
    a.send('not buffered');const restored=once(a,'message');const next=await open(room,'b');await restored;
    const request=once(next,'message');a.send('new opaque request');assert.equal((await request)[0].toString(),'new opaque request');
  }finally{for(const socket of all)socket.terminate();await relay.close();}
  assert.equal(relay.rooms(),0);
});
