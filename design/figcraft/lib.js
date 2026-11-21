// Small DSL that turns a layer tree into a FigCraft command script
// (`figcraft-cli run`). Screens describe the PepeHub windows; build.js joins
// them into one .figcraft file.
'use strict';
const icons = require('./icons.json');

// Tokens of the default "blue" palette (lib/ui/app_theme.dart, AppStyle.blue).
const C = {
  bg: '#121212',
  surface: '#1e1e1e',
  raised: '#2c2c2c',
  line: '#2c2c2c',
  strong: '#444444',
  accent: '#2f6fed',
  accentSoft: '#8fb2f7',
  onAccent: '#ffffff',
  text: '#ffffff',
  muted: '#a0a0a0',
  nav: '#0a0a0a',
  selected: '#1c2b4a',
  paper: '#fafafa',
  ink: '#2a2a2a',
};

const FONT = { body: 'Onest', display: 'Oswald', serif: 'Cormorant Garamond', reading: 'Lora' };

let counter = 0;
const id = () => `n${++counter}`;

/** Frame. `props` are node.set keys; children are other nodes. */
function F(name, props = {}, children = []) {
  const p = { ...props };
  if (p.fill == null && p.fills == null) p.fills = [];
  // One-sided strokes: the other sides must be zero explicitly.
  const sides = ['strokeTopWeight', 'strokeRightWeight', 'strokeBottomWeight', 'strokeLeftWeight'];
  if (sides.some((k) => p[k] != null)) for (const k of sides) if (p[k] == null) p[k] = 0;
  return { kind: 'frame', name, props: p, children: children.flat().filter(Boolean) };
}
/** Auto-layout shortcuts. */
const H = (name, props, children) => F(name, { layout: 'horizontal', sizingH: 'hug', sizingV: 'hug', ...props }, children);
const V = (name, props, children) => F(name, { layout: 'vertical', sizingH: 'hug', sizingV: 'hug', ...props }, children);
/** Flexible spacer for auto layout. */
const Spacer = (dir = 'h') => F('Spacer', dir === 'h' ? { width: 1, height: 1, sizingH: 'fill' } : { width: 1, height: 1, sizingV: 'fill' });

const weights = { 400: 'Regular', 500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold' };
/** Text. style: {size, w, color, font, ...node.set keys} */
function T(text, style = {}) {
  const { size = 14, w = 400, color = C.text, font = FONT.body, name, ...rest } = style;
  return {
    kind: 'text', name: name || text.slice(0, 32), text,
    props: { fontFamily: font, fontStyle: weights[w] || w, fontSize: size, fill: color, ...rest },
  };
}
const Display = (text, size = 36, color = C.text, extra = {}) =>
  T(text, { font: FONT.display, w: 700, size, color, lineHeight: '105%', letterSpacing: 0.3, ...extra });
const Book = (text, size = 18, color = C.text, extra = {}) =>
  T(text, { font: FONT.serif, w: 700, size: Math.round(size * 1.12), color, lineHeight: '112%', ...extra });

/** Material icon as an editable vector inside a square frame. */
function I(name, size = 24, color = C.text) {
  const d = icons[name];
  if (!d) throw new Error(`Unknown icon ${name}`);
  const s = size / 24;
  const path = s === 1 ? d : d.replace(/-?\d+(\.\d+)?/g, (n) => String(Math.round(parseFloat(n) * s * 100) / 100));
  return { kind: 'icon', name: `Icon/${name}`, size, path, color };
}
const R = (name, props) => ({ kind: 'rect', name, props });
const E = (name, props) => ({ kind: 'ellipse', name, props });

/** Compile a node tree into script steps under parent ref (or the page). */
function compile(node, parent, out, extra = {}) {
  const ref = id();
  const p = parent ? { parent: { $ref: parent } } : {};
  if (node.kind === 'frame') {
    const { width = 100, height = 100, x, y, ...props } = node.props;
    out.push({ command: 'node.create', as: ref, params: { type: 'frame', name: node.name, width, height, ...(x != null && { x }), ...(y != null && { y }), ...p, props: { ...props, ...extra }, select: false } });
    for (const child of node.children) compile(child, ref, out);
  } else if (node.kind === 'text') {
    const { x, y, ...props } = node.props;
    out.push({ command: 'node.create', as: ref, params: { type: 'text', name: node.name, text: node.text, ...(x != null && { x }), ...(y != null && { y }), ...p, props: { ...props, ...extra }, select: false } });
  } else if (node.kind === 'icon') {
    out.push({ command: 'node.create', as: ref, params: { type: 'frame', name: node.name, width: node.size, height: node.size, ...p, props: { fills: [], ...extra }, select: false } });
    out.push({ command: 'node.create', params: { type: 'vector', name: 'Glyph', path: node.path, x: 0, y: 0, parent: { $ref: ref }, props: { fill: node.color }, select: false } });
  } else if (node.kind === 'rect' || node.kind === 'ellipse') {
    const { width = 10, height = 10, x, y, ...props } = node.props;
    out.push({ command: 'node.create', as: ref, params: { type: node.kind === 'rect' ? 'rectangle' : 'ellipse', name: node.name, width, height, ...(x != null && { x }), ...(y != null && { y }), ...p, props: { ...props, ...extra }, select: false } });
  }
  return ref;
}

module.exports = { C, FONT, F, H, V, T, I, R, E, Display, Book, Spacer, compile };
