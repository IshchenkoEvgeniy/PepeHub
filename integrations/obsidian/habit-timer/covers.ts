export interface CoverAsset { hash:string; bytes:number; mime:'image/png'; }
export interface PrivateCoverBucket {
  head(key:string):Promise<unknown>;
  get(key:string):Promise<{body:ReadableStream;httpEtag:string}|null>;
  put(key:string,value:ArrayBuffer,options:{httpMetadata:{contentType:string}}):Promise<unknown>;
}
export const validCoverAsset=(v:unknown):v is CoverAsset=>{
  const a=v as CoverAsset;return !!a&&/^[a-f0-9]{64}$/.test(a.hash)&&a.mime==='image/png'&&Number.isInteger(a.bytes)&&a.bytes>=24&&a.bytes<=2097152;
};
export const coverReference=(hash:string)=>`pepehub-cover:${hash}`;
export const coverHash=(value:unknown):string|null=>typeof value==='string'&&/^pepehub-cover:[a-f0-9]{64}$/.test(value)?value.slice(14):null;
export async function digestCover(bytes:ArrayBuffer):Promise<string>{return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');}
export function validCoverPng(bytes:Uint8Array):boolean{
  if(bytes.length<57||bytes.length>2097152||[137,80,78,71,13,10,26,10].some((v,i)=>bytes[i]!==v)||new TextDecoder().decode(bytes.slice(12,16))!=='IHDR')return false;
  const view=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),w=view.getUint32(16),h=view.getUint32(20);
  if(!(w>0&&h>0&&w<=2048&&h<=2048&&w*h<=4194304)||view.getUint32(8)!==13)return false;
  let at=8,data=false;
  while(at+12<=bytes.length){const size=view.getUint32(at),type=new TextDecoder().decode(bytes.slice(at+4,at+8));if(size>bytes.length-at-12)return false;if(type==='IDAT')data=true;if(type==='IEND')return data&&size===0&&at+12===bytes.length;at+=size+12;}
  return false;
}
/** Authentication is performed by Companion. Objects are never served by public /covers URLs. */
export async function handlePrivateCover(request:Request,profile:string,bucket?:PrivateCoverBucket):Promise<Response>{
  if(!bucket)return Response.json({error:'covers_not_configured'},{status:503});
  const hash=new URL(request.url).pathname.split('/').at(-1) || '';
  if(!/^[a-f0-9]{64}$/.test(hash))return Response.json({error:'invalid_hash'},{status:400});
  const owner=await digestCover(new TextEncoder().encode(profile).buffer),key=`pepehub-covers/${owner}/${hash}.png`;
  if(request.method==='HEAD')return new Response(null,{status:await bucket.head(key)?200:404,headers:{'Cache-Control':'no-store'}});
  if(request.method==='GET'){
    const object=await bucket.get(key);if(!object)return new Response(null,{status:404});
    return new Response(object.body,{headers:{'Content-Type':'image/png','Cache-Control':'private, max-age=86400','ETag':object.httpEtag,'X-Content-Type-Options':'nosniff'}});
  }
  if(request.method!=='POST')return new Response(null,{status:405});
  const reader=request.body?.getReader();if(!reader)return new Response(null,{status:400});
  const chunks:Uint8Array[]=[];let count=0;
  while(true){const part=await reader.read();if(part.done)break;count+=part.value.length;if(count>2097152){await reader.cancel();return new Response(null,{status:413});}chunks.push(part.value);}
  const bytes=new Uint8Array(count);let at=0;for(const chunk of chunks){bytes.set(chunk,at);at+=chunk.length;}
  if(!validCoverPng(bytes)||request.headers.get('Content-Type')!=='image/png')return new Response(null,{status:415});
  if(await digestCover(bytes.buffer)!==hash)return new Response(null,{status:400});
  if(!await bucket.head(key))await bucket.put(key,bytes.buffer,{httpMetadata:{contentType:'image/png'}});
  return Response.json({hash,bytes:count,mime:'image/png'} satisfies CoverAsset);
}
