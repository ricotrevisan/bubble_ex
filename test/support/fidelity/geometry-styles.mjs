import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {chromium} from 'playwright';

const root = process.argv[2];
const browser = await chromium.launch({headless: true});
const errors = [];
const entry = name => pathToFileURL(path.join(root, name, 'pages/index/index.html')).href;
try {
  const page = await browser.newPage({viewport: {width: 390, height: 900}});
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(entry('normal'), {waitUntil: 'networkidle'});
  for (const [width, height] of [[390, 80], [599, 80], [600, 96], [768, 96], [390, 80]]) {
    await page.setViewportSize({width, height: 900});
    await page.waitForFunction(expected =>
      document.querySelector('#spacer').getBoundingClientRect().height === expected,
    height, {timeout: 3000});
    assert.equal(await page.locator('[data-bubble-id=header]').evaluate(el => el.getBoundingClientRect().height), height);
  }
  const transformed = await page.addStyleTag({content: '[data-bubble-id=header] {transform: scale(2)}'});
  await page.setViewportSize({width: 391, height: 900});
  await page.waitForFunction(() => document.querySelector('#spacer').getBoundingClientRect().height === 96);
  await transformed.evaluate(el => el.remove());
  await page.setViewportSize({width: 390, height: 900});
  await page.waitForFunction(() => document.querySelector('#spacer').getBoundingClientRect().height === 80);

  const ancestor = await page.addStyleTag({content: 'main {transform: scale(2)}'});
  await page.setViewportSize({width: 391, height: 900});
  await page.waitForFunction(() => document.querySelector('#spacer').getBoundingClientRect().height === 192);
  await ancestor.evaluate(el => el.remove());
  await page.locator('[data-bubble-id=header]').evaluate(el => el.setAttribute('data-placeholder-kind', 'unsupported'));
  await page.setViewportSize({width: 390, height: 900});
  await page.waitForFunction(() => document.querySelector('#spacer').getBoundingClientRect().height === 96);
  await page.locator('[data-bubble-id=header]').evaluate(el => el.removeAttribute('data-placeholder-kind'));
  await page.setViewportSize({width: 391, height: 900});
  await page.waitForFunction(() => document.querySelector('#spacer').getBoundingClientRect().height === 80);

  for (const name of ['missing', 'duplicate', 'feedback']) {
    await page.goto(entry(name), {waitUntil: 'networkidle'});
    const values = await page.locator('style[data-bubbleex-geometry]').evaluateAll(styles =>
      styles.flatMap(style => JSON.parse(style.getAttribute('data-bubbleex-geometry')).map(ref =>
        document.documentElement.style.getPropertyValue(ref.variable))));
    assert(values.length > 0, name);
    assert(values.every(value => value === ''), name + ': unresolved measurement was applied');
    assert.equal(await page.locator('#spacer').evaluate(el => el.getBoundingClientRect().height), 96);
  }
  assert.deepEqual(errors, []);
  console.log('PASS geometry styles: load, resize, transformed target/ancestor, placeholder, missing, duplicate and feedback cases');
} finally {
  await browser.close();
}
