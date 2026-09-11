const {test} = require('node:test'), assert = require('node:assert/strict');
const path = require('node:path');
const {decodeArchive} = require('../../../lib/bubble_ex/frontend/snapshot/runtime/archive.cjs');
const {build} = require('../../../lib/bubble_ex/frontend/snapshot/runtime/package.cjs');
const modules = process.env.BUBBLE_EX_SNAPSHOT_RUNTIME || path.resolve('_build/snapshot-runtime');
const archive = parts => 'Content-Type: multipart/related; boundary="snapshot"\r\n\r\n' + parts.map(([mime,url,body]) => `--snapshot\r\nContent-Type: ${mime}\r\nContent-Location: ${url}\r\nContent-Transfer-Encoding: base64\r\n\r\n${Buffer.from(body).toString('base64')}\r\n`).join('') + '--snapshot--\r\n';
const capture = parts => ({archive:archive(parts),url:'https://example.test/',fonts:[],shadowStyles:[]});
const text = (result, name='index.html') => Buffer.from(result.entries.find(e=>e.name===name).body,'base64').toString();
test('archive decodes UTF-8, soft lines, and embedded equals without interpreting filenames', () => {
 const raw='Content-Type: multipart/related;\r\n boundary="snapshot"\r\n\r\n--snapshot\r\nContent-Type: text/html\r\nContent-Location: ../../outside\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<p>=C3=A9=3D=\r\nvalue</p>\r\n--snapshot--\r\n';
 assert.equal(decodeArchive(raw)[0].body.toString(),'<p>é=value</p>');
 assert.throws(()=>decodeArchive(raw,5),/too_large/);
 assert.throws(()=>decodeArchive(raw.replace('=C3','=ZZ')),/invalid_archive/);
 assert.throws(()=>decodeArchive(raw.replace('--snapshot--','--missing--')),/invalid_archive/);
});
test('HTML and shadow content cannot retain source execution or form submission', () => {
 const result=build(capture([['text/html','https://example.test/',`<script>alert(1)</script><meta http-equiv="refresh" content="0;url=https://bad.test"><base href="https://bad.test"><form action="https://bad.test"><input type=password value=secret><button formaction="https://bad.test">Go</button></form><a href="java&#x73;cript:alert(1)" onclick="alert(1)" ping="https://bad.test">link</a><div><template shadowmode="open"><script>alert(2)</script><img onerror="alert(3)" src="https://bad.test/x"></template></div>`]]),modules);
 const output=text(result);
 assert(!output.includes('<script')); assert(!output.includes('alert(')); assert(!output.includes('https://bad.test'));
 assert(output.includes('Content-Security-Policy')); assert(output.includes('form-action &#39;none&#39;') || output.includes("form-action 'none'"));
 assert(output.includes('shadowrootmode="open"')); assert(output.includes('value=""')); assert(output.includes('type="button"'));
});
test('CSS resources are parsed, localized, or removed, including escaped URLs and imports', () => {
 const result=build(capture([
  ['text/html','https://example.test/','<link rel="stylesheet" href="/main.css"><p style="background:url(https://bad.test/x)">Text</p>'],
  ['text/css','https://example.test/main.css','@import "https://bad.test/missing.css";.a{background:u\\72l("/img.png")} .b{background:image-set("https://bad.test/x" 1x)}'],
  ['image/png','https://example.test/img.png',Buffer.from([137,80,78,71])]
 ]),modules);
 const styles=result.entries.filter(e=>e.name.endsWith('.css')).map(e=>text(result,e.name)).join('');
 assert(!styles.includes('bad.test')); assert(!styles.includes('@import')); assert(styles.includes('.png')); assert(!text(result).includes('bad.test'));
});
test('navigation stays absolute and source credentials remain visible to the gate', () => {
 const token='xoxb-'+'123456789012-123456789012-abcdefghijklmnopqrstuvwx';
 const result=build(capture([['text/html','https://example.test/path','<a href="/docs">Docs</a><p>'+token+'</p>']]),modules);
 assert(text(result).includes('href="https://example.test/docs"'));
 assert(result.scan.some(s=>s.includes(token)));
});
test('shadow-root styles missing from MHTML are restored and sanitized', () => {
 const input=capture([['text/html','https://example.test/','<x-card data-bubbleex-shadow="0"><template shadowmode="open"><p>Hello</p></template></x-card>']]);
 input.shadowStyles=[':host{display:block}p{display:flex;background:url(https://bad.test/pixel)}'];
 const result=build(input,modules),output=text(result);
 assert(output.includes(':host{display:block}')); assert(output.includes('display:flex')); assert(!output.includes('bad.test'));
});
test('SVG scripts, event handlers, animation mutation, and foreignObject execution are removed', () => {
 const result=build(capture([
 ['text/html','https://example.test/','<img src="/image.svg">'],
 ['image/svg+xml','https://example.test/image.svg','<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><set attributeName="href" to="javascript:alert(2)"/><foreignObject><div xmlns="http://www.w3.org/1999/xhtml" onclick="alert(3)">Text</div></foreignObject><image href="https://bad.test/pixel"/></svg>']
 ]),modules);
 const svg=text(result,result.entries.find(e=>e.name.endsWith('.svg')).name);
 assert(!svg.includes('alert')); assert(!svg.includes('<set')); assert(!svg.includes('bad.test')); assert(svg.includes('Text'));
});
test('archive-expanded SVG references stay internal to their own document', () => {
 const result=build(capture([
 ['text/html','https://example.test/','<svg><defs><path id="arrow" d="M0 0L4 4"/></defs><use href="https://example.test/#arrow"/></svg><img src="/art.svg">'],
 ['image/svg+xml','https://example.test/art.svg','<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="paint"><stop stop-color="red"/></linearGradient></defs><rect width="40" height="40" fill="url(https://example.test/art.svg#paint)"/></svg>']
 ]),modules);
 assert(text(result).includes('href="#arrow"'));
 const svg=text(result,result.entries.find(e=>e.name.endsWith('.svg')).name);
 assert(svg.includes('fill="url(#paint)"'));
 assert(!svg.includes('.svg#paint'));
});
test('Lottie raster data with an omitted MIME type survives, while untyped HTML does not', () => {
 const webp=Buffer.concat([Buffer.from('RIFF'),Buffer.alloc(4),Buffer.from('WEBPVP8 '),Buffer.alloc(8)]).toString('base64');
 const active=Buffer.from('<script>alert(1)</script>').toString('base64');
 const result=build(capture([['text/html','https://example.test/',`<svg><image href="data:;base64,${webp}"/><image href="data:;base64,${active}"/></svg>`]]),modules);
 assert(text(result).includes(`data:image/webp;base64,${webp}`));
 assert(!text(result).includes(active));
});
test('text scan excludes recognized raster encodings, but includes SVG and decoded entities', () => {
 const token='AIza'+'a'.repeat(35);
 const png=Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),Buffer.from(token)]).toString('base64');
 const svg='<svg xmlns="http://www.w3.org/2000/svg"><text>'+token+'</text></svg>';
 const result=build(capture([['text/html','https://example.test/',`<img src="data:image/png;base64,${png}"><img src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}"><p>&#65;Iza${'b'.repeat(35)}</p>`]]),modules);
 assert(result.scan.some(s=>s.includes(token)));
 assert(result.scan.some(s=>s.includes('AIza'+'b'.repeat(35))));
 assert(!result.scan.some(s=>s.includes(png)));
});
