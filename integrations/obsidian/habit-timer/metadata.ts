import {validCoverAsset, type CoverAsset} from './covers.ts';
/** Metadata contract for the real Habit Timer library. No media bytes or assets. */
export type JsonValue = null | string | number | boolean | JsonValue[] | { [key: string]: JsonValue };
export interface MetadataField { key: string; field: string; kind: 'text' | 'number' | 'list' | 'json'; }
export interface MetadataItem {
  id: string;
  path: string;
  collectionId: string;
  mediaType: 'book' | 'audiobook';
  modifiedAt: number;
  coverAsset?: CoverAsset | null;
  values: Record<string, JsonValue>;
  fields: MetadataField[];
}
export interface MetadataSnapshot {
  version: 1;
  ready: boolean;
  items: MetadataItem[];
  fields: MetadataField[];
  collections: Array<{ id: string; mediaType: 'book' | 'audiobook'; title: string }>;
}
export interface MetadataOperation {
  operationId: string;
  itemId: string;
  action: 'create' | 'update';
  collectionId: string;
  mediaType: 'book' | 'audiobook';
  base: Record<string, JsonValue>;
  values: Record<string, JsonValue>;
}
export interface MetadataReceipt {
  operationId: string;
  status: 'applied' | 'conflict' | 'error';
  message?: string;
}
export const ID_PROPERTY = 'pepehub_id';
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const validId = (value: unknown): value is string => typeof value === 'string' && uuidPattern.test(value);
const boundedText=(value:unknown,maximum:number):value is string=>typeof value==='string'&&value.length>0&&value.length<=maximum;
export function validMetadataFields(value:unknown):value is MetadataField[] {
  return Array.isArray(value)&&value.every(f=>f&&boundedText(f.key,200)&&boundedText(f.field,100)&&['text','number','list','json'].includes(f.kind));
}
export function validMetadataCollections(value:unknown):value is MetadataSnapshot['collections'] {
  return Array.isArray(value)&&value.every(c=>c&&boundedText(c.id,100)&&boundedText(c.title,1000)&&['book','audiobook'].includes(c.mediaType));
}
export function validMetadataItem(value:unknown):value is MetadataItem {
  if(!value||typeof value!=='object')return false;
  const item=value as MetadataItem;
  return validId(item.id)&&boundedText(item.path,4096)&&boundedText(item.collectionId,100)&&Number.isFinite(item.modifiedAt)&&item.modifiedAt>=0
    &&safeValues(item.values)&&validMetadataFields(item.fields)&&['book','audiobook'].includes(item.mediaType)&&(item.coverAsset==null||validCoverAsset(item.coverAsset));
}
export function validMetadataReceipt(value:unknown):value is MetadataReceipt {
  if(!value||typeof value!=='object')return false;
  const receipt=value as MetadataReceipt;
  return validId(receipt.operationId)&&['applied','conflict','error'].includes(receipt.status)&&(receipt.message===undefined||typeof receipt.message==='string'&&receipt.message.length<=4000);
}
export function equalValue(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a == null || b == null) return a == null && b == null;
  if (Array.isArray(a) || Array.isArray(b)) return Array.isArray(a) && Array.isArray(b)
    && a.length === b.length && a.every((v, i) => equalValue(v, b[i]));
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  const left = a as Record<string, unknown>, right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every(key => Object.prototype.hasOwnProperty.call(right, key) && equalValue(left[key], right[key]));
}
export function safeValues(value: unknown): value is Record<string, JsonValue> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const safe = (v: unknown, depth: number): boolean => {
    if (depth > 12) return false;
    if (v === null || typeof v === 'string' || typeof v === 'boolean') return true;
    if (typeof v === 'number') return Number.isFinite(v);
    if (Array.isArray(v)) return v.every(entry => safe(entry, depth + 1));
    return !!v && typeof v === 'object' && Object.entries(v).every(([key, entry]) =>
      !['__proto__', 'prototype', 'constructor', ID_PROPERTY].includes(key)
      && key.length > 0 && key.length <= 200 && safe(entry, depth + 1));
  };
  return safe(value, 0);
}
export function validOperation(value: unknown): value is MetadataOperation {
  if (!value || typeof value !== 'object') return false;
  const op = value as MetadataOperation;
  return validId(op.operationId) && validId(op.itemId) && ['create', 'update'].includes(op.action)
    && typeof op.collectionId === 'string' && op.collectionId.length > 0 && op.collectionId.length <= 100
    && ['book', 'audiobook'].includes(op.mediaType) && safeValues(op.base) && safeValues(op.values);
}
/** Compare only edited properties; a concurrent change of another field is preserved. */
export function conflictingKeys(current: Record<string, unknown>, op: MetadataOperation): string[] {
  return Object.keys(op.values).filter(key => !equalValue(current[key], op.base[key]) && !equalValue(current[key], op.values[key]));
}
