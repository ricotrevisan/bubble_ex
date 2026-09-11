import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {chromium} from 'playwright';

const browser = await chromium.launch({headless: true});
try {
  const page = await browser.newPage({viewport: {width: 900, height: 900}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  for (const mode of ['relative', 'row', 'column', 'fixed']) {
    await page.goto(pathToFileURL(path.join(process.argv[2], mode, 'pages/index/index.html')).href);
    for (const width of [200, 600, 900]) {
      await page.setViewportSize({width, height: 900});
      const box = await page.locator('[data-bubble-id=shape]').boundingBox();
      assert(box && box.width > 0, mode);
      assert(Math.abs(box.height - box.width * 0.6) < 0.1, `${mode} at ${width}: ${JSON.stringify(box)}`);
    }
  }
  assert.deepEqual(errors, []);
  console.log('PASS aspect shapes: native containers and viewport sizes');
} finally {
  await browser.close();
}
