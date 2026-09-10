// Private captures are inputs, never checked into Git. See the fixed rubric.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { PNG } = require('../../test/support/fidelity/node_modules/pngjs');
const hash = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const [baselineArg, candidateArg, outputArg] = process.argv.slice(2);
if (!baselineArg || !candidateArg || !outputArg) throw Error('Usage: node scripts/landing/grade.cjs BASELINE_DIR CANDIDATE_JSON OUTPUT_JSON');
const baseline = path.resolve(baselineArg);
const original = JSON.parse(fs.readFileSync(path.join(baseline, 'comparison.json')));
const source = original.results.filter(r => r.mode === 'source');
const lockPath = path.join(baseline, 'grading-baseline-lock.json');
const files = ['comparison.json', ...['mochary', 'bubble'].map(s => `${s}-redacted-payload.json`),
  ...source.map(r => `comparison/${r.site}/source-${r.width}.png`)];
const revisionPath = path.join(baseline, 'benchmark-revision.json');
const benchmarkRevision = fs.existsSync(revisionPath) ? JSON.parse(fs.readFileSync(revisionPath)) : {revision: 1};
if (fs.existsSync(revisionPath)) files.push('benchmark-revision.json');
const hashes = Object.fromEntries(files.map(p => [p, hash(path.join(baseline, p))]));
if (!fs.existsSync(lockPath)) fs.writeFileSync(lockPath, JSON.stringify({rubric: 1, hashes}, null, 2));
const lock = JSON.parse(fs.readFileSync(lockPath));
if (lock.rubric !== 1 || JSON.stringify(lock.hashes) !== JSON.stringify(hashes)) throw Error('Baseline changed; refusing to grade');
const candidate = JSON.parse(fs.readFileSync(candidateArg));
const normalizeText = t => (t || '').replace(/\s+/g, ' ').trim();
const encodedId = id => id.replace(/[A-Z]/g, c => `a${c}`);
const sourceId = n => {
  const classes = String(n.classes).split(/\s+/);
  const i = classes.indexOf('bubble-element');
  const id = classes[i + 2];
  return i >= 0 && id && /^[A-Za-z][A-Za-z0-9]*$/.test(id) ? id : null;
};
const grouped = (nodes, key) => {
  const groups = new Map();
  for (const n of nodes) { const k = key(n); if(k) groups.set(k, [...(groups.get(k) || []), n]); }
  return groups;
};
const close = (a, b, tolerance) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a-b) <= tolerance;
const numericCssEqual = (a,b) => a === b || (/^[\d.]+px$/.test(a) && /^[\d.]+px$/.test(b) && close(parseFloat(a),parseFloat(b),0.5));
const canonical = (href, url, siteUrl) => {
  if (href === null || href === undefined) return 'NO_DESTINATION';
  try {
    const dest = new URL(href, url);
    if (dest.protocol === 'file:') {
      if (!fs.existsSync(decodeURIComponent(dest.pathname))) return `MISSING:${dest.pathname}`;
      const match = dest.pathname.match(/\/pages\/([^/]+)\/index.html$/);
      if (!match) return `UNMAPPED:${dest.pathname}`;
      return new URL((match[1] === 'index' ? '/' : `/${match[1]}`) + dest.search + dest.hash, siteUrl).href;
    }
    return dest.href;
  } catch { return `INVALID:${href}`; }
};
const categories = ['visual', 'layout', 'content', 'typography', 'assets', 'navigation'];
(async () => {
  const {default: pixelmatch} = await import('../../test/support/fidelity/node_modules/pixelmatch/index.js');
  const report = {rubric: 1, implementationRevision: 2, benchmarkRevision, baselineHashes: hashes, results: [], normalExportGate: 'blocked_on_both_unmodified_sources'};
  for (const s of source) {
    const c = candidate.results.find(r => r.site === s.site && r.width === s.width && r.mode !== 'source' && r.audit);
    const checks = Object.fromEntries(categories.map(k => [k, []]));
    const add = (category, name, pass, detail) => checks[category].push({name, pass: !!pass, ...(pass ? {} : {detail})});
    if (!c) { for(const k of categories) add(k,'capture exists',false,'missing candidate capture'); }
    else {
      const a = s.audit, b = c.audit;
      const imageA = PNG.sync.read(fs.readFileSync(path.join(baseline, `comparison/${s.site}/source-${s.width}.png`)));
      const imageB = PNG.sync.read(fs.readFileSync(c.screenshot));
      const width = Math.max(imageA.width,imageB.width), height = Math.max(imageA.height,imageB.height);
      const padded = img => {const p = new PNG({width,height}); p.data.fill(255); PNG.bitblt(img,p,0,0,img.width,img.height,0,0);return p;};
      const p = padded(imageA), q = padded(imageB);
      const difference = pixelmatch(p.data,q.data,null,width,height,{threshold:0.1,includeAA:false})/(width*height);
      add('visual','full-page pixel difference <= 1%',difference <= 0.01,{difference});
      for (const key of ['clientWidth','scrollWidth','scrollHeight']) add('layout',key,close(a[key],b[key],2),{source:a[key],candidate:b[key]});
      const sg = grouped(a.nodes,sourceId), cg = grouped(b.nodes,n => n.id && encodedId(n.id));
      for (const [id, originals] of sg) {
        const copies = cg.get(id) || [];
        add('layout',`${id}: occurrence count`,originals.length === copies.length,{source:originals.length,candidate:copies.length});
        originals.forEach((node, i) => {
          const copy = copies[i];
          add('layout',`${id}[${i}]: visibility`,copy && node.visible === copy.visible,{source:node.visible,candidate:copy?.visible});
          if (node.visible) {
            add('layout',`${id}[${i}]: box`,copy && ['x','y','width','height'].every(k => close(node.box[k],copy.box[k],2)),{source:node.box,candidate:copy?.box});
            if (/\b(Text|Button|Link)\b/.test(node.classes)) {
              for(const k of ['fontFamily','fontSize','lineHeight']) add('typography',`${id}[${i}]: ${k}`,copy && (k === 'fontFamily' ? node.style[k] === copy.style[k] : numericCssEqual(node.style[k],copy.style[k])),{source:node.style[k],candidate:copy?.style[k]});
            }
          }
        });
      }
      add('content','visible text sequence',normalizeText(a.text) === normalizeText(b.text),'normalized text differs');
      add('assets','all visible images loaded',b.images.every(i => i.loaded),{unloaded:b.images.filter(i => !i.loaded).length});
      add('assets','visible image count',a.images.length === b.images.length,{source:a.images.length,candidate:b.images.length});
      add('assets','no new page errors',c.errors.every(e => s.errors.includes(e)),{source:s.errors.length,candidate:c.errors.length});
      const links = (r, base) => r.audit.links.map(l => `${normalizeText(l.text)}\n${canonical(l.href,r.url,base)}`).sort();
      const al = links(s,s.url), bl = links(c,s.url);
      add('navigation','visible anchors and destinations',JSON.stringify(al) === JSON.stringify(bl),{source:al,candidate:bl});
      add('navigation','no dangling local anchors',!bl.some(x => /\n(MISSING|INVALID|UNMAPPED):/.test(x)),'dangling or unmappable anchor');
    }
    const scores = Object.fromEntries(categories.map(k => [k,checks[k].length ? checks[k].filter(c => c.pass).length/checks[k].length : 1]));
    const score = Object.values(scores).reduce((a,b) => a+b,0)/categories.length;
    report.results.push({site:s.site,width:s.width,score:Math.floor(score*10000)/100,accepted:Object.values(checks).flat().every(c=>c.pass),scores,checks});
  }
  report.score = Math.floor(report.results.reduce((a,b)=>a+b.score,0)/report.results.length*100)/100;
  report.pageTestsAccepted = report.results.length === 6 && report.results.every(r=>r.accepted);
  fs.writeFileSync(outputArg,JSON.stringify(report,null,2));
  console.log(JSON.stringify({score:report.score,accepted:report.pageTestsAccepted,results:report.results.map(({checks,...r})=>r)},null,2));
})();
