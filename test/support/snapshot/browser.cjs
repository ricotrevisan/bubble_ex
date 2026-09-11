const crypto=require('node:crypto');
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {pathToFileURL}=require('node:url'),{createRequire}=require('node:module');
const {capture}=require('../../../lib/bubble_ex/frontend/snapshot/runtime/capture.cjs');
const {build}=require('../../../lib/bubble_ex/frontend/snapshot/runtime/package.cjs');
const modules=path.resolve(process.env.BUBBLE_EX_SNAPSHOT_RUNTIME||'_build/snapshot-runtime');
const {chromium}=createRequire(path.join(modules,'package.json'))('playwright');
const out=path.resolve(process.argv[2]);
const audit=()=>({scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight,text:document.body.innerText,boxes:[...document.querySelectorAll('.bubble-element')].map(e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height];})});
const source=`<!doctype html><html><head><style>body{margin:0;font:16px Arial}.Page{width:390px}canvas{display:block}x-card{display:block} @keyframes move{to{transform:translateX(100px)}} .moving{animation:move 10s infinite linear;width:20px;height:20px;background:blue}</style><link rel="stylesheet" href="/reset.css"></head><body><style>body{padding-top:24px}</style><main class="bubble-element Page fixture"><h1 class="bubble-element Text title">Loading</h1><x-card></x-card><iframe title="Embedded preview" src="/frame" style="width:160px;height:90px;border:0"></iframe><div class="moving"></div><canvas width="40" height="30"></canvas><div class="bubble-element Group scrollbox" style="width:120px;height:30px;overflow:hidden"><div class="bubble-element Text scrolltext" style="width:240px;height:70px">Saved scroll position</div></div><button onclick="document.querySelector('h1').textContent='Workflow ran'">Action</button><a href="/other">Other</a><a id="invalid" href="//" style="color:inherit;text-decoration:none">Broken source link</a><textarea>Initial</textarea></main><script>
 customElements.define('x-card',class extends HTMLElement{constructor(){super();const root=this.attachShadow({mode:'open'});const sheet=new CSSStyleSheet();sheet.replaceSync(':host{display:block}div{display:flex;height:40px;color:rgb(10,20,30)}');root.adoptedStyleSheets=[sheet];root.innerHTML='<div>Rendered plugin</div>';}});
 const adopted=new CSSStyleSheet();adopted.replaceSync('.scrollbox{border:2px solid blue}');document.adoptedStyleSheets=[adopted];
 document.querySelector('.scrollbox').scrollTo(18,12);
 const canvas=document.querySelector('canvas');const ctx=canvas.getContext('2d');ctx.fillStyle='red';ctx.fillRect(0,0,40,30);
 fetch('/data').then(r=>r.json()).then(data=>document.querySelector('h1').textContent=data.title);
 </script></body></html>`;
(async()=>{
 const server=http.createServer((req,res)=>{if(req.url==='/frame'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><link rel=stylesheet href=/reset.css><style>body{margin:0;padding:0;background:rgb(30,150,50)}</style><div class=frame-paint></div><canvas width=160 height=90></canvas><script>const c=document.querySelector("canvas").getContext("2d");c.fillStyle="red";c.fillRect(0,0,80,90)</script>');}else if(req.url==='/reset.css'){res.setHeader('Content-Type','text/css');res.end('body{padding:0}.frame-paint{width:90px;height:20px;background:magenta}');}else if(req.url==='/data'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({title:'Database content'}));}else{res.setHeader('Content-Type','text/html');res.end(source);}});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 let browser;
 try{
  const url=`http://127.0.0.1:${server.address().port}/`;
  const input=await capture(url,{width:390,height:900,locale:'en-US'},modules,audit);
  assert.equal(hash(input.reference),hash(input.repeatReference),'source freeze must be stable');
  const result=build(input,modules);
  fs.mkdirSync(out,{recursive:true});
  for(const entry of result.entries){const file=path.join(out,entry.name);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,Buffer.from(entry.body,'base64'));}
  browser=await chromium.launch();const page=await browser.newPage({viewport:{width:390,height:900},locale:'en-US',deviceScaleFactor:1,reducedMotion:'reduce'});
  const requests=[],errors=[];await page.route(/^https?:/,route=>{requests.push(route.request().url());return route.abort();});page.on('pageerror',e=>errors.push(e.message));
  await page.goto(pathToFileURL(path.join(out,'index.html')).href);await page.evaluate(()=>document.fonts.ready);
  assert.equal(await page.locator("#invalid").getAttribute("href"),null);
  assert(result.findings.some(f=>f.code==="invalid_navigation"));
  assert.deepEqual(await page.evaluate(audit),input.audit);
  assert.equal(await page.locator('x-card div').innerText(),'Rendered plugin');
  await page.getByRole('button',{name:'Action'}).click();
  assert.equal(await page.locator('h1').innerText(),'Database content');
  assert.deepEqual(requests,[]);assert.deepEqual(errors,[]);
  assert.deepEqual(await page.locator('script').allTextContents(),[require('../../../lib/bubble_ex/frontend/snapshot/runtime/scroll.cjs')]);
  const cdp=await page.context().newCDPSession(page), clip={x:0,y:0,width:input.audit.scrollWidth,height:input.audit.scrollHeight,scale:1};
  // Clicking can add a focus ring: remove it before comparing the initial state.
  await page.evaluate(()=>document.activeElement.blur());
  await page.mouse.move(0,0);
  const initial=(await cdp.send('Page.captureScreenshot',{format:'png',clip,captureBeyondViewport:true})).data;
  assert.equal(hash(initial),hash(input.reference),'offline initial pixels must equal captured pixels');
  console.log('Snapshot capture, database content, shadow CSS, canvas, animation, inert controls and offline pixels passed');
 }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})();
