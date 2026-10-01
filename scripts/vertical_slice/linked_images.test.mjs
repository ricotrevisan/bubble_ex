// node --test scripts/vertical_slice/linked_images.test.mjs
// (run by test/scripts/vertical_slice_linked_images_test.exs)
import { test } from "node:test";
import assert from "node:assert/strict";
import { bubbleStorage, expectedImage, linkedImageUrls, withoutFragment } from "./linked_images.mjs";

const manifest = {
  assets: [
    { kind: "image", status: "external", url: "https://cdn.example.com/a.png" },
    { kind: "image", status: "external", url: "https://cdn.example.com/q.png?w=200#top" },
    { kind: "image", status: "external", url: "https://s3.amazonaws.com/appforest_uf/f1/x.png" },
    { kind: "image", status: "external", url: "https://s3.amazonaws.com/other-bucket/b.png" },
    { kind: "image", status: "local", url: "https://x1.cdn.bubble.io/f1/c.png" },
    { kind: "icon", status: "external", url: "https://icons.example.com/i.svg" },
    { kind: "image", status: "external", url: "not a url" },
  ],
};
const linked = linkedImageUrls(manifest);

test("only external images are linked, never Bubble's storage", () => {
  assert.deepEqual([...linked].sort(), [
    "https://cdn.example.com/a.png",
    "https://cdn.example.com/q.png?w=200",
    "https://s3.amazonaws.com/other-bucket/b.png",
  ]);
  assert.deepEqual([...linkedImageUrls({})], []);
  assert.deepEqual([...linkedImageUrls(null)], []);
});

test("the exact URL is expected, its fragment aside", () => {
  assert.equal(expectedImage("https://cdn.example.com/a.png", "image", linked), true);
  assert.equal(expectedImage("https://cdn.example.com/a.png#x", "image", linked), true);
  assert.equal(expectedImage("https://cdn.example.com/q.png?w=200", "image", linked), true);
  assert.equal(expectedImage("https://s3.amazonaws.com/other-bucket/b.png", "image", linked), true);
});

test("anything else on the same host is not expected", () => {
  for (const href of [
    "https://cdn.example.com/b.png",
    "https://cdn.example.com/a.png?track=1",
    "https://cdn.example.com/q.png",
    "http://cdn.example.com/a.png",
    "https://cdn.example.com:8443/a.png",
    "https://s3.amazonaws.com/other-bucket/pixel.gif",
    "https://s3.amazonaws.com/appforest_uf/f1/x.png",
    "https://icons.example.com/i.svg",
    "not a url",
  ]) {
    assert.equal(expectedImage(href, "image", linked), false, href);
  }
});

test("only image requests are expected", () => {
  for (const type of ["script", "fetch", "xhr", "document", "stylesheet", "other"]) {
    assert.equal(expectedImage("https://cdn.example.com/a.png", type, linked), false, type);
  }
});

test("Bubble's storage is never expected, even when listed", () => {
  const listed = new Set([
    "https://s3.amazonaws.com/appforest_uf/f1/x.png",
    "https://appforest_uf.s3.amazonaws.com/f1/x.png",
    "https://dd7tel2830j4w.cloudfront.net/f1700000000000x1/a.png",
    "https://x1.cdn.bubble.io/f1/a.png",
    "https://app.bubbleapps.io/fileupload/f1/a.png",
  ]);
  for (const href of listed) {
    assert.equal(bubbleStorage(href), true, href);
    assert.equal(expectedImage(href, "image", listed), false, href);
  }
  for (const href of [
    "https://x1.cdn.bubble.io.evil.example/f1/a.png",
    "https://dd7tel2830j4w.cloudfront.net/not-a-file/a.png",
    "https://other.cloudfront.net/f1x1/a.png",
    "not a url",
  ]) {
    assert.equal(bubbleStorage(href), false, href);
  }
});

test("withoutFragment", () => {
  assert.equal(withoutFragment("https://cdn.example.com/a.png#x"), "https://cdn.example.com/a.png");
  assert.equal(withoutFragment("HTTPS://CDN.Example.com/a.png"), "https://cdn.example.com/a.png");
  assert.equal(withoutFragment("::"), null);
});
