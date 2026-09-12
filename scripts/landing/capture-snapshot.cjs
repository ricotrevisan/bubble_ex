// Private paired inputs and references. Run before any snapshot export.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const {capture} = require('../../lib/bubble_ex/frontend/snapshot/runtime/capture.cjs');
const audit = require('./audit.cjs');
const root = path.resolve(process.argv[2]);
const modules = path.resolve(process.argv[3]);
const sites = require('./snapshot-sites.cjs')(process.argv[4]);
(async () => {
  if (fs.existsSync(root)) throw Error('Capture destination must be new');
  fs.mkdirSync(root,{recursive:true,mode:0o700});
  const report = {mode:'snapshot',results:[]}, files=[];
  for (const [site,url] of sites) for (const width of [390,768,1440]) {
    try {
    const result = await capture(url,{width,height:900,locale:'en-US'},modules,audit);
    if (result.reference !== result.repeatReference) {
      const failed = path.join(root,'failed',`${site}-${width}`);
      fs.mkdirSync(failed,{recursive:true,mode:0o700});
      fs.writeFileSync(path.join(failed,'capture.json'),JSON.stringify(result),{mode:0o600});
      fs.writeFileSync(path.join(failed,'first.png'),Buffer.from(result.reference,'base64'));
      fs.writeFileSync(path.join(failed,'repeat.png'),Buffer.from(result.repeatReference,'base64'));
      throw Error('Unstable source screenshot');
    }
    const image = `comparison/${site}/source-${width}.png`, input = `${site}-${width}-snapshot.json`;
    fs.mkdirSync(path.dirname(path.join(root,image)),{recursive:true});
    fs.writeFileSync(path.join(root,image),Buffer.from(result.reference,'base64'));
    report.results.push({site,url:result.url,mode:'source',width,audit:result.audit,errors:result.findings.filter(f=>f.code==='source_page_error').map(f=>f.code)});
    delete result.reference; delete result.repeatReference; delete result.audit;
    fs.writeFileSync(path.join(root,input),JSON.stringify(result),{mode:0o600});
    files.push(input,image);
    console.log(JSON.stringify({site,width,height:report.results.at(-1).audit.scrollHeight,findings:result.findings}));
    } catch (error) {
      const reason = error.message === 'Unstable source screenshot' ? 'unstable_source' : 'capture_failed';
      report.results.push({site,url,mode:'source',width,error:reason,errors:[]});
      console.log(JSON.stringify({site,width,error:reason}));
    }
    fs.writeFileSync(path.join(root,'comparison.json'),JSON.stringify(report,null,2));
  }
  fs.writeFileSync(path.join(root,'comparison.json'),JSON.stringify(report,null,2)); files.unshift('comparison.json');
  const hashes=Object.fromEntries(files.map(f=>[f,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,f))).digest('hex')]));
  fs.writeFileSync(path.join(root,'grading-baseline-lock.json'),JSON.stringify({rubric:1,mode:'snapshot',hashes},null,2));
})();
