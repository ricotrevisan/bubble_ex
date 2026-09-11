// Chromium's bounded multipart/related archive format, not a general email parser.
const crypto = require('node:crypto');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function headers(text) {
  const result = {};
  for (const line of text.replace(/\r\n[\t ]+/g, ' ').split('\r\n')) {
    const colon = line.indexOf(':');
    if (colon > 0) result[line.slice(0, colon).toLowerCase()] = line.slice(colon + 1).trim();
  }
  return result;
}
function decodeArchive(raw, maxBytes = 100 * 1024 * 1024) {
  if (Buffer.byteLength(raw) > maxBytes) throw new Error('archive_too_large');
  const split = raw.indexOf('\r\n\r\n');
  const top = headers(raw.slice(0, split));
  const boundary = /boundary="([^"\r\n]{1,200})"/.exec(top['content-type'] || '')?.[1];
  if (split < 0 || !boundary || !top['content-type'].startsWith('multipart/related')) throw new Error('invalid_archive');
  const chunks = raw.slice(split + 4).split('--' + boundary);
  if (chunks.length > 5002 || !chunks.at(-1).startsWith('--')) throw new Error('invalid_archive');
  let total = 0;
  return chunks.slice(1, -1).map(chunk => {
    if (!chunk.startsWith('\r\n')) throw new Error('invalid_archive');
    chunk = chunk.slice(2);
    const offset = chunk.indexOf('\r\n\r\n');
    if (offset < 0) throw new Error('invalid_archive');
    const h = headers(chunk.slice(0, offset));
    const content = chunk.slice(offset + 4).replace(/\r\n$/, '');
    let body;
    switch (h['content-transfer-encoding']) {
      case 'base64': {
        const compact = content.replace(/\s/g, '');
        if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(compact)) throw new Error('invalid_archive');
        body = Buffer.from(compact, 'base64'); break;
      }
      case 'quoted-printable': {
        const flat = content.replace(/=\r\n/g, '');
        if (/=(?![0-9a-f]{2})/i.test(flat)) throw new Error('invalid_archive');
        body = Buffer.from(flat.replace(/=([0-9a-f]{2})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16))), 'latin1'); break;
      }
      case 'binary': case '8bit': case undefined: body = Buffer.from(content, 'utf8'); break;
      default: throw new Error('invalid_archive');
    }
    total += body.length;
    if (total > maxBytes) throw new Error('archive_too_large');
    return {body, mime: (h['content-type'] || '').split(';')[0].toLowerCase(), url: h['content-location'], cid: h['content-id']?.replace(/^<|>$/g, '')};
  });
}
module.exports = {decodeArchive, hash};
