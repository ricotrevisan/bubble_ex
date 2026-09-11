const {decodeArchive, hash} = require('./archive.cjs');
const {rasterData,scanText} = require('./data.cjs');
const path = require('node:path');
const {createRequire} = require('node:module');
const CSP = "default-src 'none'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; media-src 'self'; frame-src 'self'; connect-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'";
const extensions = {'text/html':'html','text/css':'css','image/svg+xml':'svg','image/png':'png','image/jpeg':'jpg','image/gif':'gif','image/webp':'webp','image/avif':'avif','image/x-icon':'ico','font/woff2':'woff2','font/woff':'woff','application/font-woff':'woff','font/ttf':'ttf','font/otf':'otf'};
function build(capture, modules) {
  const req = createRequire(path.join(path.resolve(modules), 'package.json'));
  const html = req('parse5'), css = req('css-tree');
  const parts = decodeArchive(capture.archive);
  if (parts[0]?.mime !== 'text/html') throw new Error('invalid_archive');
  for (const font of capture.resources || capture.fonts || []) {
    if (typeof font.url !== 'string' || typeof font.body !== 'string') throw new Error('invalid_font');
    if (parts.some(part => part.url === font.url)) continue;
    parts.push({url:font.url, mime:font.mime.split(';')[0], body:Buffer.from(font.body,'base64')});
  }
  const refs = new Map(), findings = new Map(), entries = [], scan = [];
  const warn = code => findings.set(code, (findings.get(code) || 0) + 1);
  parts.forEach((part, i) => {
    part.name = i === 0 ? 'index.html' : `assets/${hash(part.body)}.${extensions[part.mime] || 'bin'}`;
    if (i && extensions[part.mime]) {
      if (part.url) refs.set(part.url, part);
      if (part.cid) refs.set('cid:' + part.cid, part);
    }
    scan.push(part.body.toString(/^(text\/|image\/svg\+xml)/.test(part.mime) ? 'utf8' : 'latin1'));
  });
  let total = parts.reduce((sum, part) => sum + part.body.length, 0);
  if (total > 100 * 1024 * 1024) throw new Error('archive_too_large');
  const resource = (url, owner, allowed) => {
    if (!url) return null;
    if (url.startsWith('#')) return url;
    // Data SVG/HTML must be parsed and sanitized too; unknown data is omitted.
    const raster = rasterData(url);
    if (raster) return `data:${raster.mime};base64,${raster.body.toString('base64')}`;
    if (/^data:image\/svg\+xml(?:;charset=[^;,]+)?(?:;base64)?,/i.test(url) && !refs.has(url)) {
      const comma = url.indexOf(',');
      let body;
      try { body = /;base64$/i.test(url.slice(0,comma)) ? Buffer.from(url.slice(comma+1),'base64') : Buffer.from(decodeURIComponent(url.slice(comma+1))); }
      catch { warn('unresolved_resource'); return null; }
      total += body.length;
      if (total > 100 * 1024 * 1024) throw new Error('archive_too_large');
      const part = {url,mime:'image/svg+xml',body,name:`assets/${hash(body)}.svg`};
      parts.push(part); refs.set(url,part); scan.push(body.toString('utf8'));
    }
    let absolute;
    try { absolute = new URL(url, owner.url || capture.url).href; } catch { warn('unresolved_resource'); return null; }
    const base = absolute.split('#')[0], fragment = absolute.slice(base.length);
    if (fragment && base === (owner.url || capture.url).split('#')[0]) return fragment;
    const part = refs.get(absolute) || refs.get(base);
    if (!part || (allowed && !allowed(part.mime))) { warn('unresolved_resource'); return null; }
    return path.posix.relative(path.posix.dirname(owner.name), part.name) + fragment;
  };
  const rewriteCSS = (source, owner, context = 'stylesheet') => {
    let ast;
    try { ast = css.parse(source, {context, parseCustomProperty:true, onParseError:() => { throw new Error('invalid_css'); }}); }
    catch { warn('unparsed_css'); return ''; }
    css.walk(ast, {
      enter(node, item, list) {
        if (['String','Url'].includes(node.type)) scan.push(node.value);
        if (node.type === 'Atrule' && ['import','namespace','charset'].includes(node.name.toLowerCase())) {
          if (node.name.toLowerCase() === 'import') {
            let ref;
            css.walk(node.prelude, n => { if (!ref && ['String','Url'].includes(n.type)) ref = n; });
            const target = ref && resource(ref.value, owner, mime => mime === 'text/css');
            if (target) ref.value = target; else { if (list) list.remove(item); return this.skip; }
            return this.skip;
          }
          if (node.name.toLowerCase() === 'charset') { if (list) list.remove(item); return this.skip; }
        }
        if (node.type === 'Declaration' && /^(?:behavior|-moz-binding)$/i.test(node.property)) { list.remove(item); return this.skip; }
        if (node.type === 'Function' && node.name.toLowerCase() === 'expression') throw new Error('active_css');
        if (node.type === 'Url') node.value = resource(node.value, owner, mime => mime !== 'text/html') || 'data:,';
        // image-set string arguments are resource URLs, unlike ordinary CSS strings.
        if (node.type === 'Function' && /^(?:-webkit-)?image-set$/i.test(node.name)) {
          node.children.forEach(child => { if (child.type === 'String') child.value = resource(child.value, owner, mime => mime.startsWith('image/')) || 'data:,'; });
        }
      }
    });
    return css.generate(ast);
  };
  const attr = (node, name) => node.attrs?.find(a => a.name === name)?.value;
  const set = (node, name, value) => {
    node.attrs = (node.attrs || []).filter(a => a.name !== name);
    node.attrs.push({name, value});
  };
  const navigation = (url, owner) => {
    try { const u = new URL(url, owner.url || capture.url); return ['https:','http:','mailto:','tel:'].includes(u.protocol) && !u.username && !u.password ? u.href : null; }
    catch { return null; }
  };
  function sanitize(root, owner) {
    root.childNodes = (root.childNodes || []).filter(node => {
      if (node.nodeName === '#text') scan.push(node.value);
      for (const attribute of node.attrs || []) scan.push(attribute.value);
      if (node.nodeName === '#comment') return false;
      if (!node.tagName) return true;
      const tag = node.tagName.toLowerCase();
      if (['script','base','object','embed','applet','animate','animatetransform','animatemotion','set','discard'].includes(tag)) { warn('active_content_removed'); return false; }
      if (tag === 'meta' && attr(node,'http-equiv')) return false;
      if (tag === 'link' && !['stylesheet','icon'].includes(attr(node,'rel'))) return false;
      node.attrs = node.attrs.filter(a => !/^on/i.test(a.name) && !['nonce','integrity','crossorigin','ping','action','formaction','srcdoc','autoplay','manifest','is'].includes(a.name));
      if (tag === 'input' && attr(node,'type') === 'password') set(node,'value','');
      if (tag === 'button' || (tag === 'input' && ['submit','image'].includes(attr(node,'type')))) set(node,'type','button');
      if (tag === 'iframe') set(node,'sandbox','');
      if (tag === 'template' && attr(node,'shadowmode')) {
        const shadowIndex = attr(node.parentNode,'data-bubbleex-shadow');
        const shadowCSS = capture.shadowStyles?.[Number(shadowIndex)];
        if (shadowIndex !== undefined && typeof shadowCSS === 'string') {
          scan.push(shadowCSS);
          const style = {nodeName:'style',tagName:'style',namespaceURI:'http://www.w3.org/1999/xhtml',attrs:[],childNodes:[],parentNode:node.content};
          style.childNodes.push({nodeName:'#text',value:shadowCSS,parentNode:style});
          node.content.childNodes.push(style);
        }
        set(node,'shadowrootmode',attr(node,'shadowmode'));
        node.attrs = node.attrs.filter(a => a.name !== 'shadowmode');
      }
      node.attrs = node.attrs.filter(a => {
        const key = a.name.toLowerCase();
        if (key === 'style') { a.value = rewriteCSS(a.value,owner,'declarationList'); return true; }
        if (key === 'srcset' || key === 'imagesrcset') return false; // Capture fixes each image to currentSrc.
        if (key === 'href' && ['a','area'].includes(tag)) { const value = navigation(a.value,owner); if (value === null) return false; a.value = value; return true; }
        if (['src','href','poster','background'].includes(key)) {
          const value = resource(a.value,owner, mime => tag === 'iframe' ? mime === 'text/html' : tag === 'link' && attr(node,'rel') === 'stylesheet' ? mime === 'text/css' : mime !== 'text/html');
          if (value === null) return false; a.value = value; return true;
        }
        // SVG paint/filter attributes can load external resources.
        if (['fill','stroke','filter','clip-path','mask','cursor'].includes(key) && /url\s*\(/i.test(a.value)) {
          a.value = rewriteCSS(key + ':' + a.value,owner,'declarationList').replace(/^[^:]+:/,'');
        }
        return true;
      });
      if (tag === 'style') {
        const source = node.childNodes.map(n => n.value || '').join('');
        node.childNodes = [{nodeName:'#text',value:rewriteCSS(source,owner),parentNode:node}];
      } else sanitize(node,owner);
      if (node.content) sanitize(node.content,owner);
      return true;
    });
  }
  for (const part of parts) {
    if (!extensions[part.mime]) { warn('unsupported_resource'); continue; }
    let body = part.body;
    if (part.mime === 'text/css') body = Buffer.from(rewriteCSS(body.toString('utf8'),part));
    if (part.mime === 'text/html' || part.mime === 'image/svg+xml') {
      const source = body.toString('utf8');
      const doc = part.mime === 'text/html' ? html.parse(source) : html.parseFragment(source);
      sanitize(doc,part);
      if (part.mime === 'text/html') {
        const htmlNode = doc.childNodes.find(n => n.tagName === 'html');
        const head = htmlNode.childNodes.find(n => n.tagName === 'head');
        const policy = html.parseFragment(`<meta http-equiv="Content-Security-Policy" content="${CSP}">`).childNodes[0];
        head.childNodes.unshift(policy); policy.parentNode = head;
      }
      body = Buffer.from(html.serialize(doc));
    }
    entries.push({name:part.name,body:body.toString('base64')});
    if (/^(text\/|image\/svg\+xml)/.test(part.mime)) scan.push(body.toString('utf8'));
  }
  const decodedRasters = [], textScan = scan.map(text => scanText(text,decodedRasters));
  return {entries:[...new Map(entries.map(e => [e.name,e])).values()],scan:[...new Set([...textScan,...decodedRasters])],findings:[...findings].map(([code,count]) => ({code,count}))};
}
module.exports = {build};
