interface StateAdapter {
  exists(path:string):Promise<boolean>;
  read(path:string):Promise<string>;
  write(path:string,content:string):Promise<void>;
}
interface Checkpoint { generation:number; payload:string; checksum:string; }
async function checksum(payload:string):Promise<string> {
  const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(payload));
  return Array.from(new Uint8Array(bytes),b=>b.toString(16).padStart(2,'0')).join('');
}

// Never overwrite the last verified checkpoint. A failed or interrupted write
// leaves the other slot, including immutable request UUIDs, available for replay.
export class DurableState<T> {
  private checkpoints=new Map<string,Checkpoint>();
  private adapter:StateAdapter;
  private empty:()=>T;
  private valid:(value:unknown)=>boolean;
  constructor(adapter:StateAdapter,empty:()=>T,valid:(value:unknown)=>boolean) {
    this.adapter=adapter;this.empty=empty;this.valid=valid;
  }
  private async decode(raw:string):Promise<Checkpoint> {
    const checkpoint=JSON.parse(raw) as Checkpoint;
    if(!Number.isSafeInteger(checkpoint.generation)||checkpoint.generation<1||typeof checkpoint.payload!=='string'||
       checkpoint.checksum!==await checksum(checkpoint.payload)||!this.valid(JSON.parse(checkpoint.payload))) {
      throw new Error('Invalid PepeHub state checkpoint');
    }
    return checkpoint;
  }
  async read(path:string):Promise<T> {
    const checkpoints:Checkpoint[]=[];
    let present=false;
    for(const suffix of ['.0','.1']) {
      if(!await this.adapter.exists(path+suffix))continue;
      present=true;
      try {checkpoints.push(await this.decode(await this.adapter.read(path+suffix)));} catch { /* Try the other verified copy. */ }
    }
    if(checkpoints.length) {
      const latest=checkpoints.sort((a,b)=>b.generation-a.generation)[0]!;
      this.checkpoints.set(path,latest);
      return JSON.parse(latest.payload) as T;
    }
    // An old legacy file may predate accepted requests; never use it after both
    // checkpoints have been damaged, and never silently reset an existing queue.
    if(present)throw new Error('PepeHub: обе копии состояния повреждены; файлы сохранены.');
    const payload=await this.adapter.exists(path)?await this.adapter.read(path):JSON.stringify(this.empty());
    const state=JSON.parse(payload) as T;
    if(!this.valid(state))throw new Error('Invalid PepeHub state; existing file was preserved.');
    this.checkpoints.set(path,{generation:0,payload,checksum:''});
    return state;
  }
  async save(path:string,state:T):Promise<void> {
    if(!this.checkpoints.has(path))await this.read(path);
    const prior=this.checkpoints.get(path)!;
    const payload=JSON.stringify(state);
    if(prior.generation>0&&payload===prior.payload)return;
    const generation=prior.generation+1;
    if(!Number.isSafeInteger(generation))throw new Error('PepeHub state generation overflow');
    const next={generation,payload,checksum:await checksum(payload)};
    const target=`${path}.${generation%2}`;
    await this.adapter.write(target,JSON.stringify(next));
    const verified=await this.decode(await this.adapter.read(target));
    if(verified.generation!==generation||verified.payload!==payload)throw new Error('PepeHub state write was not persisted');
    this.checkpoints.set(path,next);
  }
}
