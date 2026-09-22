import {test} from 'node:test';
import assert from 'node:assert/strict';
import {updateBookBlock} from '../integrations/obsidian/markdown.ts';
import type {Entity} from '../contracts/protocol.ts';
const book:Entity={entityType:'book',entityId:'book-test',revision:1,deleted:false,payload:{title:'Книга | <script>',authors:['Автор'],format:'epub',status:'active'}};
test('export is replay-safe, escapes content and preserves frontmatter and user sections byte for byte',()=>{
  const prefix='---\r\ncustom: true\r\n---\r\n\r\nМоя заметка.\r\n\r\n';
  const first=updateBookBlock(prefix,book,[]);
  assert.ok(first.startsWith(prefix));assert.ok(first.includes('&#124; &lt;script&gt;'));
  const withSuffix=first+'\r\n## Мой итог\r\nТекст.';
  assert.equal(updateBookBlock(withSuffix,book,[]),withSuffix);
});
test('damaged or duplicated markers fail closed',()=>{
  assert.throws(()=>updateBookBlock('<!-- pepehub:book-test:start -->',book,[]));
  const block=updateBookBlock('',book,[]);
  assert.throws(()=>updateBookBlock(block+block,book,[]));
});
