export type EntityType = 'book' | 'session';
export const bookFormats = ['epub', 'fb2', 'txt', 'md', 'html', 'docx', 'rtf', 'pdf', 'audio'] as const;
export interface Book {
  title: string;
  authors: string[];
  format: typeof bookFormats[number];
  status: 'planned' | 'active' | 'finished';
}
export interface Session {
  bookId: string;
  kind: 'reading' | 'listening';
  startedAt: string;
  endedAt: string;
  activeSeconds: number;
  timezone: string;
  offsetMinutes?: number;
  source: 'manual' | 'timer' | 'player';
}
export interface Operation {
  schemaVersion: 1;
  operationId: string;
  deviceId: string;
  entityType: EntityType;
  entityId: string;
  baseRevision: number;
  action: 'put' | 'delete';
  payload: Book | Session | null;
}
export interface Entity {
  entityType: EntityType;
  entityId: string;
  revision: number;
  deleted: boolean;
  payload: Book | Session | null;
}
export interface Receipt {
  operationId: string;
  status: 'accepted' | 'conflict';
  current: Entity | null;
}
export interface Change extends Entity { sequence: number; operationId: string }
export interface ChangePage { schemaVersion: 1; changes: Change[]; cursor: number; hasMore: boolean }

export class InputError extends Error {}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function isUuid(value: unknown): value is string { return typeof value === 'string' && uuid.test(value); }
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new InputError('Expected object');
  return value as Record<string, unknown>;
}
function exactKeys(value: Record<string, unknown>, keys: string[]): void {
  if (Object.keys(value).some(key => !keys.includes(key))) throw new InputError('Unknown field');
}
function text(value: unknown, max: number): string {
  if (typeof value !== 'string' || !value.trim() || value.length > max || /[\u0000-\u001f\u007f]/.test(value)) throw new InputError('Invalid text');
  return value.trim();
}
function choice<T extends string>(value: unknown, values: readonly T[]): T {
  if (!values.includes(value as T)) throw new InputError('Invalid option');
  return value as T;
}
export function parseOperation(input: unknown): Operation {
  const o = record(input);
  exactKeys(o, ['schemaVersion','operationId','deviceId','entityType','entityId','baseRevision','action','payload']);
  if (o.schemaVersion !== 1 || !isUuid(o.operationId) || !isUuid(o.deviceId) || !isUuid(o.entityId)) throw new InputError('Invalid protocol or identifier');
  if (!Number.isSafeInteger(o.baseRevision) || (o.baseRevision as number) < 0) throw new InputError('Invalid revision');
  const entityType = choice(o.entityType, ['book', 'session']);
  const action = choice(o.action, ['put', 'delete']);
  let payload: Book | Session | null = null;
  if (action === 'delete') {
    if (o.payload !== null || o.baseRevision === 0) throw new InputError('Delete requires a known revision and null payload');
  } else if (entityType === 'book') {
    const p = record(o.payload);
    exactKeys(p, ['title','authors','format','status']);
    if (!Array.isArray(p.authors) || p.authors.length > 30) throw new InputError('Invalid authors');
    payload = { title: text(p.title, 500), authors: p.authors.map(a => text(a, 200)), format: choice(p.format, bookFormats), status: choice(p.status, ['planned', 'active', 'finished']) };
  } else {
    const p = record(o.payload);
    exactKeys(p, ['bookId','kind','startedAt','endedAt','activeSeconds','timezone','source','offsetMinutes']);
    if (!isUuid(p.bookId)) throw new InputError('Invalid book ID');
    const startedAt = text(p.startedAt, 40), endedAt = text(p.endedAt, 40);
    const canonicalDate = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
    if (!canonicalDate.test(startedAt) || !canonicalDate.test(endedAt)) throw new InputError('UTC dates required');
    const start = Date.parse(startedAt), end = Date.parse(endedAt);
    const normalized = (value: string) => value.includes('.') ? value : value.replace(/Z$/, '.000Z');
    if (!Number.isFinite(start) || !Number.isFinite(end) || new Date(start).toISOString() !== normalized(startedAt) || new Date(end).toISOString() !== normalized(endedAt)) throw new InputError('Invalid calendar date');
    const seconds = p.activeSeconds;
    if (!Number.isFinite(start) || !Number.isFinite(end) || end < start || !Number.isSafeInteger(seconds) || (seconds as number) < 0 || (seconds as number) > Math.floor((end-start)/1000) || end-start > 7*86400000) throw new InputError('Invalid session duration');
    const timezone = text(p.timezone, 100);
    try { new Intl.DateTimeFormat('en', { timeZone: timezone }); } catch { throw new InputError('Invalid timezone'); }
    payload = { bookId: p.bookId, kind: choice(p.kind, ['reading', 'listening']), startedAt, endedAt, activeSeconds: seconds as number, timezone, source: choice(p.source, ['manual','timer','player']) };
    if(p.offsetMinutes!==undefined) {
      if(!Number.isSafeInteger(p.offsetMinutes)||(p.offsetMinutes as number)<-840||(p.offsetMinutes as number)>840)throw new InputError('Invalid timezone offset');
      payload.offsetMinutes=p.offsetMinutes as number;
    }
  }
  return { schemaVersion: 1, operationId: o.operationId, deviceId: o.deviceId, entityType, entityId: o.entityId, baseRevision: o.baseRevision as number, action, payload };
}
