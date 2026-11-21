// Extract Material Icons used by the app as 24x24 SVG path data.
const fs = require('fs'), path = require('path'), opentype = require('opentype.js');
// Needs opentype.js: npm i --no-save opentype.js@1.3.4
const root = path.resolve(__dirname, '../..');
const dart = fs.readFileSync(root + '/.tools/flutter/packages/flutter/lib/src/material/icons.dart', 'utf8');
const map = {};
for (const m of dart.matchAll(/static const IconData (\w+) = IconData\(\s*0x([0-9a-f]+)/g)) map[m[1]] = parseInt(m[2], 16);
const used = new Set();
(function walk(d) { for (const f of fs.readdirSync(d)) { const p = path.join(d, f);
  if (fs.statSync(p).isDirectory()) walk(p); else if (p.endsWith('.dart'))
    for (const m of fs.readFileSync(p, 'utf8').matchAll(/Icons\.([a-z_0-9]+)/g)) used.add(m[1]); } })(root + '/apps/pepehub/lib');
const font = opentype.loadSync(root + '/apps/pepehub/build/unit_test_assets/fonts/MaterialIcons-Regular.otf');
const out = {}; for (const x of ['arrow_back','chevron_left','chevron_right','arrow_drop_down','help_outline','cloud_upload_outlined','storage','dns','view_list','view_agenda','sort','pause','language','history_toggle_off','bookmark_border','edit_outlined','repeat','format_list_bulleted','article_outlined','list','filter_list','person_outline','auto_stories','queue_music','graphic_eq','timer','settings','subtitles_outlined','speed','folder','add_box_outlined','open_in_new','library_add_outlined','label_outline','event_note','trending_up','emoji_events_outlined','local_fire_department_outlined','access_time','music_note','video_library_outlined']) used.add(x);
const r = n => Math.round(n * 100) / 100;
for (const name of [...used].sort()) {
  const cp = map[name]; if (cp == null) continue;
  const g = font.charToGlyph(String.fromCodePoint(cp)); if (!g || !g.path) continue;
  // font units: em = unitsPerEm; icon box = 24 px. y flipped (ascender baseline).
  const p = g.getPath(0, 0, 24); // baseline at y=0, glyph above
  let d = '';
  const asc = 24 * font.ascender / font.unitsPerEm;
  for (const c of p.commands) {
    const pt = (x, y) => `${r(x)} ${r(y + asc)}`;
    if (c.type === 'M') d += `M${pt(c.x, c.y)}`; else if (c.type === 'L') d += `L${pt(c.x, c.y)}`;
    else if (c.type === 'Q') d += `Q${pt(c.x1, c.y1)} ${pt(c.x, c.y)}`;
    else if (c.type === 'C') d += `C${pt(c.x1, c.y1)} ${pt(c.x2, c.y2)} ${pt(c.x, c.y)}`;
    else if (c.type === 'Z') d += 'Z';
  }
  out[name] = d;
}
fs.writeFileSync(root + '/design/figcraft/icons.json', JSON.stringify(out, null, 0));
console.log(Object.keys(out).length, 'icons; asc', font.ascender, font.descender, font.unitsPerEm);
console.log(out.book);
