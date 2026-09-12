// Fixed library code only: captured values stay in data attributes, never code.
// CSP permits this exact hash, without permitting source scripts or handlers.
function initializeScroll() {
  const restore = () => {
    const roots = [document];
    for (let i = 0; i < roots.length; i++) {
      for (const element of roots[i].querySelectorAll('*')) {
        if (element.shadowRoot) roots.push(element.shadowRoot);
        if (!element.hasAttribute('data-bubbleex-scroll')) continue;
        const values = element.getAttribute('data-bubbleex-scroll').split(',').map(Number);
        if (values.length === 2 && values.every(Number.isFinite)) {
          element.scrollTo({left:values[0],top:values[1],behavior:'instant'});
        }
      }
    }
  };
  restore();
  if (document.readyState !== 'complete') window.addEventListener('load',restore,{once:true});
}
module.exports = `(${initializeScroll.toString()})();`;
