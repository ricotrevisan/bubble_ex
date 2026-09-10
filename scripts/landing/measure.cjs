const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require('../../test/support/fidelity/node_modules/playwright');
const root = path.resolve(process.argv[2]);
(async()=>{
 const browser=await chromium.launch({headless:true});
 const report={browser:browser.version(),platform:process.platform,arch:process.arch,results:[]};
 try {
  for(const [site,url] of [['mochary','https://beta.mocharymethod.com/'],['bubble','https://bubble.io/']]) {
   for(const mode of ['redacted-export']) {
    const html=path.join(root,site+'-redacted','pages/index/index.html');
    if(mode==='export'&&!fs.existsSync(html)){report.results.push({site,mode,error:'export_not_created'});continue;}
    for(const width of [390,768,1440]){
     const context=await browser.newContext({viewport:{width,height:900},locale:'en-US',deviceScaleFactor:1,reducedMotion:'reduce'});
     const page=await context.newPage();
     const errors=[];
     page.on('pageerror',e=>errors.push(e.message.slice(0,250)));
     const dest=mode==='source'?url:pathToFileURL(html).href;
     const entry={site,mode,width,url:dest};
     try{
      const response=await page.goto(dest,{waitUntil:'domcontentloaded',timeout:60000});
      entry.status=response?.status();
      if(mode==='source')await page.waitForSelector('.bubble-element.Page',{timeout:30000});
      await page.waitForLoadState('networkidle',{timeout:10000}).catch(()=>{});
      await page.evaluate(()=>Promise.race([document.fonts.ready,new Promise(r=>setTimeout(r,10000))]));
      entry.url=page.url();
      entry.audit=await page.evaluate(()=>{
       const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
       return {title:document.title,clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight,
        text:document.body.innerText.slice(0,20000),
        headings:[...document.querySelectorAll('h1,h2,h3')].filter(visible).map(e=>({tag:e.tagName,text:e.innerText})),
        images:[...document.images].filter(visible).map(e=>({src:e.getAttribute('src'),loaded:e.complete&&e.naturalWidth>0,alt:e.alt})),
        links:[...document.querySelectorAll('a')].filter(visible).map(e=>({text:e.innerText.slice(0,120),href:e.getAttribute('href')})),
        nodes:[...document.querySelectorAll('.bubble-element,[data-bubble-id]')].map(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return{classes:e.className,id:e.getAttribute('data-bubble-id'),exporterId:e.getAttribute('data-exporter-id'),visible:visible(e),tag:e.tagName,text:e.children.length?null:e.textContent.slice(0,150),box:{x:r.x,y:r.y,width:r.width,height:r.height},style:{display:s.display,position:s.position,fontFamily:s.fontFamily,fontSize:s.fontSize,lineHeight:s.lineHeight,background:s.backgroundColor}}})};
      });
      const dir=path.join(root,'comparison',site);fs.mkdirSync(dir,{recursive:true});
      entry.screenshot=path.join(dir,`${mode}-${width}.png`);
      await page.screenshot({path:entry.screenshot,fullPage:true,animations:'disabled',timeout:60000});
     }catch(e){entry.error=e.message.slice(0,400);}
     entry.errors=errors;report.results.push(entry);
     fs.writeFileSync(path.join(root,'comparison.json'),JSON.stringify(report,null,2));
     console.log(JSON.stringify({site,mode,width,status:entry.status,error:entry.error,height:entry.audit?.scrollHeight,nodes:entry.audit?.nodes.length}));
     await context.close();
    }
   }
  }
 }finally{await browser.close();}
})();
