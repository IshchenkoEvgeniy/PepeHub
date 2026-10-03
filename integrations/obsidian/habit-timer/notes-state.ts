import { equalValue } from './metadata.ts';
import type { NoteEntry, NoteOperation, NoteRecord } from './notes.ts';

export interface NoteSlot {
  value: NoteEntry;
  synced: NoteEntry | null;
  revision: number;
  operation?: NoteOperation;
  conflict?: NoteRecord;
  needsWrite?: boolean;
  writeBase?: NoteEntry | null;
}
export interface NoteState { version: 1; cursor: number; slots: Record<string,NoteSlot>; }
export const emptyNoteState = (): NoteState => ({version:1,cursor:0,slots:{}});
export function captureNote(state: NoteState, entries: NoteEntry[], observedItems: Set<string>): void {
  const present = new Set(entries.map(e=>e.id));
  for (const entry of entries) {
    const slot=state.slots[entry.id];
    if (slot) slot.value=entry;
    else state.slots[entry.id]={value:entry,synced:null,revision:0};
  }
  for (const slot of Object.values(state.slots)) {
    if (!slot.needsWrite && observedItems.has(slot.value.itemId) && !present.has(slot.value.id) && !slot.value.deleted) slot.value={...slot.value,deleted:true};
  }
}
export function pendingNote(state: NoteState): NoteOperation[] {
  const operations: NoteOperation[]=[];
  for (const slot of Object.values(state.slots)) {
    if (slot.conflict) continue;
    if (!slot.operation && !equalValue(slot.value,slot.synced)) slot.operation={operationId:crypto.randomUUID(),baseRevision:slot.revision,entry:structuredClone(slot.value)};
    if (slot.operation) operations.push(slot.operation);
  }
  return operations;
}
export function receiptNote(state: NoteState, receipt:{operationId:string;status:string;record:NoteRecord}): void {
  const slot=Object.values(state.slots).find(s=>s.operation?.operationId===receipt.operationId);
  if (!slot) return;
  if (receipt.status==='conflict' && !equalValue(slot.value,receipt.record.entry)) slot.conflict=receipt.record;
  else if (receipt.status==='applied' || receipt.status==='conflict') {slot.revision=receipt.record.revision;slot.synced=receipt.record.entry;delete slot.operation;}
}
/** Returns false when a local edit must be reviewed, preserving both versions. */
export function receiveNote(state: NoteState, record: NoteRecord): boolean {
  const slot=state.slots[record.entry.id];
  if (slot && record.revision<=slot.revision) return false;
  if (slot && !equalValue(slot.value,slot.synced) && !equalValue(slot.value,record.entry)) {slot.conflict=record;return false;}
  state.slots[record.entry.id]={value:record.entry,synced:record.entry,revision:record.revision};
  return true;
}
