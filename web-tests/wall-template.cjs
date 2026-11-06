const fs = require('node:fs');
const path = require('node:path');

const templatePath = path.resolve(__dirname, '../Booth360/LANControl/WallPageTemplate.swift');

function decodeSwiftString(value) {
  const escapes = { '0': '\0', t: '\t', n: '\n', r: '\r', '"': '"', "'": "'", '\\': '\\' };
  return value.replace(/\\(u\{[0-9a-fA-F]+\}|\r?\n[ \t]*|[\s\S])/g, (match, escaped) => {
    if (Object.hasOwn(escapes, escaped)) return escapes[escaped];
    if (escaped.startsWith('u{')) return String.fromCodePoint(parseInt(escaped.slice(2, -1), 16));
    if (/^\r?\n/.test(escaped)) return '';
    throw new Error(`Unsupported Swift escape in wall template: ${JSON.stringify(match)}`);
  });
}

/** Extract the production Swift multiline literal, preserving its real HTML/JS. */
function renderWallHTML(variantJS) {
  if (typeof variantJS !== 'string') throw new TypeError('variantJS must be a string');
  const source = fs.readFileSync(templatePath, 'utf8');
  const literal = source.match(/return """\r?\n([\s\S]*?)\r?\n([ \t]*)"""/);
  if (!literal) throw new Error('Swift wall template multiline literal not found');
  const indent = literal[2];
  const body = literal[1].split(/\r?\n/).map(line => {
    if (!line.trim()) return '';
    if (!line.startsWith(indent)) throw new Error('Unexpected Swift multiline indentation');
    return line.slice(indent.length);
  }).join('\n');
  const pieces = body.split('\\(variantJS)');
  if (pieces.length !== 2) throw new Error('Expected exactly one Swift variantJS interpolation');
  return decodeSwiftString(pieces[0]) + variantJS + decodeSwiftString(pieces[1]);
}

module.exports = { renderWallHTML, templatePath };
