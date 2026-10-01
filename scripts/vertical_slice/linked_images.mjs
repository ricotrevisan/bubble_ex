// Which blocked requests of the vertical slice's drive are expected: the
// images the generated pages link from other hosts, as Bubble does
// (WTF-465), listed in the generated `.wtf/assets.json` as `external`.
// Pure functions, tested by linked_images.test.mjs (`node --test`).
//
// A request is expected only if it is an image request for exactly a
// listed URL (its fragment aside) and not on Bubble's storage: on a shared
// host (S3, CloudFront) another request is a leak or a tracker, and a page
// never links Bubble's storage, so such a request is always reported.

const BUBBLE_CLOUDFRONT = "dd7tel2830j4w.cloudfront.net";

// A URL without its fragment, as the browser writes it; null if invalid.
export const withoutFragment = (href) => {
  try {
    const url = new URL(href);
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
};

// Bubble's storage, as BubbleEx.Load.Files.bubble?/2 recognizes it (any
// scheme: an http:// request to it is no more expected), plus any other
// bubble.io or bubbleapps.io host.
export const bubbleStorage = (href) => {
  let url;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  const host = url.hostname.toLowerCase();
  const path = url.pathname;
  if (host === "s3.amazonaws.com") return path.startsWith("/appforest_uf/");
  if (host === "appforest_uf.s3.amazonaws.com") return true;
  if (host === BUBBLE_CLOUDFRONT) return /^\/f[0-9]+x[0-9]+\//.test(path);
  return /(^|\.)(bubble\.io|bubbleapps\.io)$/.test(host);
};

// The linked image URLs of a decoded `.wtf/assets.json`.
export const linkedImageUrls = (manifest) => {
  const urls = new Set();
  for (const asset of (manifest && manifest.assets) || []) {
    if (!asset || asset.kind !== "image" || asset.status !== "external") continue;
    const url = withoutFragment(asset.url);
    if (url && !bubbleStorage(url)) urls.add(url);
  }
  return urls;
};

// Whether a blocked request is an expected linked image.
export const expectedImage = (href, resourceType, linked) => {
  if (resourceType !== "image") return false;
  const url = withoutFragment(href);
  return url !== null && linked.has(url) && !bubbleStorage(url);
};
