// Builds design/figcraft PepeHub windows into a .figcraft file.
//   node design/figcraft/build.js [out.figcraft] [--only=name1,name2]
// Requires FigCraft (figcraft-cli). Fonts are loaded from the app assets.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os'), { execFileSync } = require('child_process');
const { compile } = require('./lib');

const root = path.resolve(__dirname, '../..');
const out = process.argv.find((a, i) => i > 1 && !a.startsWith('--')) || 'C:/Users/ghjcn/FigCraft/pepehub/PepeHub.figcraft';
const only = (process.argv.find((a) => a.startsWith('--only=')) || '').slice(7).split(',').filter(Boolean);
const cli = process.env.FIGCRAFT_CLI || 'C:/Program Files/ArtCraft/FigCraft/figcraft-cli.exe';

// [page name, module] — each module exports an array of screen trees.
const pages = [
  ['Книги', './screens/books'],
  ['Аудиокниги', './screens/audio'],
  ['Медиа', './screens/media'],
  ['Библиотека', './screens/library'],
  ['Рекомендации', './screens/recommendations'],
  ['Статистика', './screens/statistics'],
  ['Чтение', './screens/reader'],
  ['Настройки', './screens/settings'],
  ['Служебные окна', './screens/service'],
];

const steps = [];
for (const font of ['Onest', 'Oswald', 'CormorantGaramond', 'CormorantGaramond-Italic', 'Lora']) {
  steps.push({ command: 'text.loadFont', params: { path: path.join(root, 'apps/pepehub/assets/fonts', `${font}.ttf`).replace(/\\/g, '/') } });
}
steps.push({ command: 'file.rename', params: { name: 'PepeHub — окна приложения' } });

// Colour tokens: every AppStyle palette of lib/ui/app_theme.dart is a mode.
const theme = fs.readFileSync(path.join(root, 'apps/pepehub/lib/ui/app_theme.dart'), 'utf8');
const palettes = [...theme.matchAll(/^\s{2}(\w+)\(\s*'([^']+)',([\s\S]*?)\),\s*$/gm)]
  .map(([, , label, body]) => [label, Object.fromEntries([...body.matchAll(/(\w+): 0xff([0-9a-f]{6})/g)].map(([, k, v]) => [k, `#${v}`]))])
  .filter(([, tokens]) => tokens.background);
if (palettes.length) {
  steps.push({ command: 'variable.createCollection', params: { name: 'Палитра', modes: palettes.map(([label]) => label) } });
  for (const key of Object.keys(palettes[0][1])) {
    steps.push({ command: 'variable.create', params: { collection: 'Палитра', name: `Color/${key}`, type: 'color', values: Object.fromEntries(palettes.map(([label, t]) => [label, t[key]])) } });
  }
}

let first = true;
for (const [name, mod] of pages) {
  if (!fs.existsSync(path.join(__dirname, mod + '.js'))) continue;
  const screens = require(mod).filter((s) => !only.length || only.includes(s.name));
  if (!screens.length) continue;
  if (first) steps.push({ command: 'page.rename', params: { name } });
  else steps.push({ command: 'page.add', params: { name } });
  first = false;
  let x = 0;
  for (const screen of screens) {
    const gap = 120;
    screen.props.x = x;
    screen.props.y = 0;
    compile(screen, null, steps);
    x += (screen.props.width || 1440) + gap;
  }
}

const script = path.join(os.tmpdir(), 'pepehub-figcraft-build.json');
fs.writeFileSync(script, JSON.stringify(steps));
fs.mkdirSync(path.dirname(out), { recursive: true });
console.log(`${steps.length} steps → ${out}`);
try {
  execFileSync(cli, ['run', script, '--out', out], { stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 1 << 28 });
} catch (e) {
  const lines = String(e.stdout || '').split('\n').filter((l) => l.includes('"ok":false'));
  console.error(lines.join('\n').slice(0, 2000) || String(e.stderr).slice(0, 2000));
  process.exit(1);
}
console.log('done');
