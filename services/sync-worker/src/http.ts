import { InputError } from '../../../contracts/protocol.ts';

export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}
export function json(body: unknown, status = 200): Response {
  return Response.json(body, {status, headers: {
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
  }});
}
export async function body(request: Request): Promise<unknown> {
  const reader = request.body?.getReader();
  if (!reader) throw new InputError('Missing JSON body');
  let size = 0;
  const chunks: Uint8Array[] = [];
  while (true) {
    const next = await reader.read();
    if (next.done) break;
    size += next.value.length;
    if (size > 32768) { await reader.cancel(); throw new InputError('Body exceeds 32 KiB'); }
    chunks.push(next.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)); }
  catch { throw new InputError('Invalid JSON'); }
}
