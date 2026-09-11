const http = require('node:http'), path = require('node:path'), assert = require('node:assert/strict');
const {capture} = require('../../../lib/bubble_ex/frontend/snapshot/runtime/capture.cjs');
const {PNG} = require('../fidelity/node_modules/pngjs');
const modules = path.resolve(process.env.BUBBLE_EX_SNAPSHOT_RUNTIME || '_build/snapshot-runtime');
const source = '<!doctype html><html><head><style>body{margin:0}</style></head><body><noscript><iframe src="/pixel" height="0" width="0" style="display:none"></iframe></noscript><main class="bubble-element Page test"><div id="marker" style="background:red;width:100px;height:100px"></div></main></body></html>';
(async () => {
  const server = http.createServer((_request,response) => {
    response.setHeader('Content-Type','text/html'); response.end(source);
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  try {
    const result = await capture(`http://127.0.0.1:${server.address().port}/`,{width:390,height:900},modules,() => ({
      scrollWidth:document.documentElement.scrollWidth, scrollHeight:document.documentElement.scrollHeight,
      y:document.querySelector('#marker').getBoundingClientRect().y
    }));
    const png = PNG.sync.read(Buffer.from(result.reference,'base64')), offset = (10 * png.width + 10) * 4;
    assert.equal(result.audit.y,0);
    assert.equal(result.reference,result.repeatReference);
    assert.deepEqual([...png.data.subarray(offset,offset + 3)],[255,0,0],
      'inactive noscript text must not paint over the marker after scripts stop');
    console.log('Noscript fallback stays inert; DOM geometry and frozen pixels agree');
  } finally { await new Promise(resolve => server.close(resolve)); }
})();
