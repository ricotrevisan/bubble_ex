const path = require('node:path');
const {createRequire} = require('node:module');
// Invoked through DevTools after script execution and CSS playback have stopped.
function prepare() {
  const roots = [document], shadowStyles = [], findings = [];
  let scroll = false;
  // MHTML hoists inline sheets ahead of linked sheets. Record the actual cascade.
  const stylesheets = [...document.styleSheets, ...document.adoptedStyleSheets].map(sheet => {
    const state = {href:sheet.href,base:document.baseURI,media:sheet.disabled ? 'not all' : sheet.media.mediaText};
    if (!sheet.href) {
      try { state.css = [...sheet.cssRules].map(rule => rule.cssText).join('\n'); }
      catch { findings.push({code:'unreadable_stylesheet'}); state.css = ''; }
    }
    return state;
  });
  for (let i = 0; i < roots.length; i++) {
    for (const element of roots[i].querySelectorAll('*')) {
      if (element instanceof HTMLAnchorElement || element instanceof HTMLAreaElement) {
        const href = element.getAttribute('href');
        let valid = href === null;
        try {
          const url = new URL(href,document.baseURI);
          valid ||= ['http:','https:','mailto:','tel:'].includes(url.protocol) && !url.username && !url.password;
        } catch {}
        // MHTML can turn malformed href="//" into a valid-looking homepage URL.
        if (!valid) element.setAttribute('data-bubbleex-invalid-href',href);
        else element.removeAttribute('data-bubbleex-invalid-href');
      }
      if (element.scrollLeft || element.scrollTop) {
        element.setAttribute('data-bubbleex-scroll',`${element.scrollLeft},${element.scrollTop}`);
        scroll = true;
      } else element.removeAttribute('data-bubbleex-scroll');
      if (element.shadowRoot) {
        const root = element.shadowRoot;
        roots.push(root);
        element.setAttribute('data-bubbleex-shadow', String(shadowStyles.length));
        shadowStyles.push([...root.styleSheets, ...root.adoptedStyleSheets].map(sheet => {
          try { return [...sheet.cssRules].map(rule => rule.cssText).join('\n'); }
          catch { findings.push({code:'unreadable_shadow_styles'}); return ''; }
        }).join('\n'));
      }
      if (element instanceof HTMLInputElement) {
        if (element.type === 'password') element.value = '';
        element.setAttribute('value', element.value);
        if (element.checked) element.setAttribute('checked',''); else element.removeAttribute('checked');
      }
      if (element instanceof HTMLTextAreaElement) element.textContent = element.value;
      if (element instanceof HTMLOptionElement) {
        if (element.selected) element.setAttribute('selected',''); else element.removeAttribute('selected');
      }
      if (element instanceof HTMLImageElement && element.currentSrc) {
        if (element.src !== element.currentSrc) element.src = element.currentSrc;
        element.removeAttribute('srcset'); element.removeAttribute('sizes');
        element.loading = 'eager';
      }
      if (element instanceof HTMLCanvasElement) {
        try {
          const image = document.createElement('img');
          for (const attribute of element.attributes) image.setAttribute(attribute.name, attribute.value);
          image.src = element.toDataURL('image/png');
          image.width = element.width; image.height = element.height;
          element.replaceWith(image);
        } catch { findings.push({code:'unreadable_canvas'}); }
      }
    }
  }
  // Freeze animated properties, rather than restarting animations in the export.
  const changes = [];
  for (const root of roots) for (const animation of root.getAnimations?.() || []) {
    const effect = animation.effect, target = effect?.target;
    if (!target || effect.pseudoElement) { findings.push({code:'unsupported_animation'}); continue; }
    const computed = getComputedStyle(target);
    const keys = new Set(effect.getKeyframes().flatMap(frame => Object.keys(frame)).filter(key => !['offset','computedOffset','easing','composite'].includes(key)));
    changes.push({animation,target,values:[...keys].map(key => [key.replace(/[A-Z]/g, c => '-' + c.toLowerCase()), computed[key]])});
  }
  for (const {animation,target,values} of changes) {
    for (const [key,value] of values) target.style.setProperty(key,value,'important');
    target.style.setProperty('animation','none','important');
    target.style.setProperty('transition','none','important');
    animation.cancel();
  }
  // Match the existing grading correlation, without changing presentation.
  for (const element of document.querySelectorAll('.bubble-element')) {
    const classes = [...element.classList], encoded = classes[classes.indexOf('bubble-element') + 2];
    if (encoded && /^[A-Za-z][A-Za-z0-9]*$/.test(encoded)) element.setAttribute('data-bubble-id',encoded.replace(/a([A-Z])/g,'$1'));
  }
  return {stylesheets,shadowStyles,scroll,findings};
}
async function capture(url, options, modules, audit) {
  const req = createRequire(path.join(path.resolve(modules),'package.json'));
  const {chromium} = req('playwright');
  const browser = await chromium.launch({headless:true});
  if (browser.version() !== '140.0.7339.186') { await browser.close(); throw new Error('browser_version_mismatch'); }
  const deadline = setTimeout(() => browser.close(), options.timeout || 90000);
  try {
    const context = await browser.newContext({viewport:{width:options.width || 1440,height:options.height || 900},locale:options.locale || 'en-US',deviceScaleFactor:1,reducedMotion:'reduce',serviceWorkers:'block',acceptDownloads:false});
    const page = await context.newPage(), resources = [], pending = [], errors = [];
    let resourceBytes = 0;
    page.on('pageerror', () => errors.push('source_page_error'));
    page.on('response', response => {
      if (['font','image'].includes(response.request().resourceType())) pending.push((async () => {
        const body = await response.body(); resourceBytes += body.length;
        if (resourceBytes > 100 * 1024 * 1024) throw new Error('resource_limit');
        resources.push({url:response.url(),mime:response.headers()['content-type'] || 'font/woff2',body:body.toString('base64')});
      })().catch(() => errors.push('resource_capture_failed')));
    });
    // Only the requested document may be navigated; its normal subresources load.
    await context.route('**/*', route => {
      const request = route.request();
      if (request.isNavigationRequest() && request.frame() === page.mainFrame() && request.url() !== url && !request.redirectedFrom()) return route.abort();
      if (!['http:','https:','data:','blob:','about:'].includes(new URL(request.url()).protocol)) return route.abort();
      return route.continue();
    });
    const response = await page.goto(url,{waitUntil:'domcontentloaded',timeout:45000});
    if (!response?.ok()) throw new Error('page_http_error');
    await page.waitForSelector('.bubble-element.Page',{timeout:20000});
    await page.waitForLoadState('networkidle',{timeout:10000}).catch(() => {});
    await page.evaluate(() => Promise.race([document.fonts.ready,new Promise(resolve => setTimeout(resolve,10000))]));
    await page.evaluate(() => Promise.race([Promise.all([...document.images].map(image => { image.loading = 'eager'; return image.decode().catch(() => {}); })),new Promise(resolve => setTimeout(resolve,10000))]));
    const cdp = await context.newCDPSession(page);
    await cdp.send('Animation.enable');
    await cdp.send('Animation.setPlaybackRate',{playbackRate:0});
    // The live page has scripting enabled. Keep its inactive fallbacks inert when
    // DevTools disables execution; Chromium can otherwise paint their raw text.
    await page.evaluate(() => { for (const node of document.querySelectorAll('noscript')) node.style.setProperty('display','none','important'); });
    await cdp.send('Emulation.setScriptExecutionDisabled',{value:true});
    const state = await page.evaluate(prepare), frames = [];
    // Out-of-process embeds have independent script/animation state. Their CSS
    // cascade and plugin state need the same preparation as the main document.
    for (const frame of page.frames().filter(frame => frame !== page.mainFrame())) {
      try {
        const element = await frame.frameElement(), index = frames.length;
        await element.evaluate((node,index) => node.setAttribute('data-bubbleex-frame',String(index)),index);
        await element.dispose();
        await frame.evaluate(() => { for (const node of document.querySelectorAll('noscript')) node.style.setProperty('display','none','important'); });
        const session = await context.newCDPSession(frame).catch(error => {
          if (error.message.includes('part of the parent frame')) return null;
          throw error;
        });
        if (session) {
          await session.send('Animation.enable');
          await session.send('Animation.setPlaybackRate',{playbackRate:0});
          await session.send('Emulation.setScriptExecutionDisabled',{value:true});
        }
        frames.push(await frame.evaluate(prepare));
      } catch { frames.push(null); errors.push('frame_capture_failed'); }
    }
    await Promise.all(pending);
    const archive = (await cdp.send('Page.captureSnapshot',{format:'mhtml'})).data;
    if (Buffer.byteLength(archive) > 100 * 1024 * 1024) throw new Error('archive_too_large');
    const result = {schema:1,url:page.url(),viewport:options,browser:browser.version(),platform:process.platform,arch:process.arch,capturedAt:new Date().toISOString(),archive,resources,frames,stylesheets:state.stylesheets,shadowStyles:state.shadowStyles,scroll:state.scroll,findings:[...state.findings,...frames.flatMap(frame => frame?.findings || []),...errors.map(code => ({code}))]};
    if (audit) {
      result.audit = await page.evaluate(audit);
      const clip = {x:0,y:0,width:result.audit.scrollWidth,height:result.audit.scrollHeight,scale:1};
      result.reference = (await cdp.send('Page.captureScreenshot',{format:'png',clip,captureBeyondViewport:true})).data;
      result.repeatReference = (await cdp.send('Page.captureScreenshot',{format:'png',clip,captureBeyondViewport:true})).data;
    }
    return result;
  } finally { clearTimeout(deadline); await browser.close(); }
}
module.exports = {capture,prepare};
