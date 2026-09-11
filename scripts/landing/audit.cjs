module.exports = ()=>{
       const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden';};
       return {title:document.title,clientWidth:document.documentElement.clientWidth,scrollWidth:document.documentElement.scrollWidth,scrollHeight:document.documentElement.scrollHeight,
        text:document.body.innerText.slice(0,20000),
        headings:[...document.querySelectorAll('h1,h2,h3')].filter(visible).map(e=>({tag:e.tagName,text:e.innerText})),
        images:[...document.images].filter(visible).map(e=>({src:e.getAttribute('src'),loaded:e.complete&&e.naturalWidth>0,alt:e.alt})),
        links:[...document.querySelectorAll('a')].filter(visible).map(e=>({text:e.innerText.slice(0,120),href:e.getAttribute('href')})),
        nodes:[...document.querySelectorAll('.bubble-element,[data-bubble-id]')].map(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return{classes:e.className,id:e.getAttribute('data-bubble-id'),exporterId:e.getAttribute('data-exporter-id'),visible:visible(e),tag:e.tagName,text:e.children.length?null:e.textContent.slice(0,150),box:{x:r.x,y:r.y,width:r.width,height:r.height},style:{display:s.display,position:s.position,fontFamily:s.fontFamily,fontSize:s.fontSize,lineHeight:s.lineHeight,background:s.backgroundColor}}})};
      };
