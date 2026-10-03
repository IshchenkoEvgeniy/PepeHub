import { validId, equalValue } from './metadata.ts';

/** One timed segment/day. Positions remain in their original units. */
export interface ActivityEntry {
  id: string;
  itemId: string;
  mediaType: 'book' | 'audiobook';
  day: string;
  durationMs: number;
  progress: number;
  unit: 'characters' | 'pages' | 'minutes' | 'unknown';
  mediaMs: number;
  startedAt: string | null;
  endedAt: string | null;
  offsetMinutes: number | null;
  note: string;
  origin: 'app-reader' | 'app-audio' | 'app-manual' | 'obsidian';
  deleted: boolean;
}
export interface ActivityRecord { entry: ActivityEntry; revision: number; sequence: number; }
export interface ActivityOperation { operationId: string; baseRevision: number; entry: ActivityEntry; }
export const sameActivity = equalValue;
const integer = (v: unknown, min: number, max: number) => typeof v === 'number' && Number.isSafeInteger(v) && v >= min && v <= max;
export function validActivity(value: unknown): value is ActivityEntry {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const e = value as ActivityEntry;
  const keys = ['id','itemId','mediaType','day','durationMs','progress','unit','mediaMs','startedAt','endedAt','offsetMinutes','note','origin','deleted'];
  if (Object.keys(e).length !== keys.length || Object.keys(e).some(k => !keys.includes(k))) return false;
  const instant = (v: unknown) => v === null || (typeof v === 'string' && /^\d{4}-\d\d-\d\dT.*Z$/.test(v) && Number.isFinite(Date.parse(v)));
  const date = typeof e.day === 'string' ? new Date(`${e.day}T00:00:00Z`) : new Date(NaN);
  return validId(e.id) && validId(e.itemId) && ['book','audiobook'].includes(e.mediaType)
    && typeof e.day === 'string' && /^\d{4}-\d\d-\d\d$/.test(e.day) && Number.isFinite(date.getTime()) && date.toISOString().slice(0,10) === e.day
    && integer(e.durationMs,0,86400000) && typeof e.progress === 'number' && Number.isFinite(e.progress) && e.progress >= 0 && e.progress <= 1e9
    && ['characters','pages','minutes','unknown'].includes(e.unit) && integer(e.mediaMs,0,864000000)
    && instant(e.startedAt) && instant(e.endedAt) && (e.startedAt === null || e.endedAt === null || Date.parse(e.endedAt) >= Date.parse(e.startedAt))
    && (e.offsetMinutes === null || integer(e.offsetMinutes,-840,840))
    && typeof e.note === 'string' && e.note.length <= 10000 && typeof e.deleted === 'boolean'
    && ['app-reader','app-audio','app-manual','obsidian'].includes(e.origin);
}
export function validActivityOperation(v: unknown): v is ActivityOperation {
  const op = v as ActivityOperation;
  return !!op && validId(op.operationId) && integer(op.baseRevision,0,Number.MAX_SAFE_INTEGER-1) && validActivity(op.entry);
}
