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
   for(const mode of ['snapshot']) {


    for(const width of [390,768,1440]){
     const html=path.join(root,`${site}-${width}`,'index.html');
     const context=await browser.newContext({viewport:{width,height:900},locale:'en-US',deviceScaleFactor:1,reducedMotion:'reduce'});
     const page=await context.newPage();
     const errors=[], requests=[];
     await page.route(/^https?:/,route=>{requests.push(new URL(route.request().url()).hostname);return route.abort();});
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
      entry.audit=await page.evaluate(require('./audit.cjs'));
      const dir=path.join(root,'comparison',site);fs.mkdirSync(dir,{recursive:true});
      entry.screenshot=path.join(dir,`${mode}-${width}.png`);
      await page.screenshot({path:entry.screenshot,fullPage:true,animations:'disabled',timeout:60000});
     }catch(e){entry.error=e.message.slice(0,400);}
     entry.errors=errors;entry.externalRequests=requests;report.results.push(entry);
     fs.writeFileSync(path.join(root,'comparison.json'),JSON.stringify(report,null,2));
     console.log(JSON.stringify({site,mode,width,status:entry.status,error:entry.error,height:entry.audit?.scrollHeight,nodes:entry.audit?.nodes.length}));
     await context.close();
    }
   }
  }
 }finally{await browser.close();}
})();
