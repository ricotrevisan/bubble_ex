import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {chromium} from 'playwright';

const browser = await chromium.launch({headless: true});
try {
  const page = await browser.newPage({viewport: {width: 390, height: 900}});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(pathToFileURL(path.join(process.argv[2], 'pages/index/index.html')).href);
  const field = page.locator('textarea[data-bubble-id=field]');
  for (const [width, height] of [[390, 140], [768, 70], [1440, 70], [390, 140]]) {
    await page.setViewportSize({width, height: 900});
    assert.equal((await field.boundingBox()).height, height, `empty field at ${width}`);
  }
  await page.setViewportSize({width: 768, height: 900});
  await field.fill('Line\n'.repeat(50));
  assert.equal((await field.boundingBox()).height, 400, 'authored maximum');
  await field.fill('');
  assert.equal((await field.boundingBox()).height, 70, 'authored minimum after clearing');
  assert.deepEqual(errors, []);
  console.log('PASS fit-height textarea: minimum, breakpoint, maximum, and clearing');
} finally {
  await browser.close();
}
