(() => {
  const targets = new Map();
  for (const element of document.querySelectorAll('[data-bubble-id]')) {
    const key = element.getAttribute('data-bubble-id');
    const group = targets.get(key) || [];
    group.push(element);
    targets.set(key, group);
  }
  const references = new Map();
  const styles = [];
  for (const style of document.querySelectorAll('style[data-bubbleex-geometry]')) {
    try {
      const refs = JSON.parse(style.getAttribute('data-bubbleex-geometry')).map(ref => {
        const matches = targets.get(ref.element) || [];
        if (matches.length === 1 && ['width', 'height'].includes(ref.axis) &&
            /^--bubbleex-geometry-[0-9a-f]{64}$/.test(ref.variable)) {
          return {...ref, target: matches[0]};
        }
        return null;
      });
      if (refs.length && refs.every(Boolean)) {
        styles.push({style, refs});
        for (const ref of refs) references.set(ref.variable, ref);
      }
    } catch (_) { /* Leave malformed or unresolved bindings inactive. */ }
  }
  const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve));
  const measure = ref => {
    if (ref.target.closest('[data-placeholder-kind]') || !ref.target.getClientRects().length) return null;
    for (let element = ref.target; element; element = element.parentElement) {
      if (getComputedStyle(element).transform !== 'none') return null;
    }
    const size = ref.target.getBoundingClientRect()[ref.axis];
    return Number.isFinite(size) && size >= 0 ? size : null;
  };
  let generation = 0;
  async function update() {
    const current = ++generation;
    for (const {style} of styles) style.media = 'not all';
    for (const ref of references.values()) document.documentElement.style.removeProperty(ref.variable);
    await document.fonts.ready;
    await nextFrame();
    if (current !== generation) return;
    const measured = new Map();
    for (const ref of references.values()) {
      const size = measure(ref);
      if (size !== null) measured.set(ref.variable, size);
    }
    for (const [variable, size] of measured) {
      document.documentElement.style.setProperty(variable, `${size}px`);
    }
    for (const {style, refs} of styles) {
      if (refs.every(ref => measured.has(ref.variable))) style.media = 'all';
    }
    await nextFrame();
    if (current !== generation) return;
    // Reject feedback: an assigned dimension must not resize its own source.
    const feedback = [...references.values()].some(ref => {
      if (!measured.has(ref.variable)) return false;
      const after = measure(ref);
      return after === null || Math.abs(after - measured.get(ref.variable)) > 0.01;
    });
    if (feedback) {
      for (const {style} of styles) style.media = 'not all';
      for (const ref of references.values()) document.documentElement.style.removeProperty(ref.variable);
    }
  }
  window.addEventListener('resize', update);
  window.addEventListener('load', update, {once: true});
  update();
})();
