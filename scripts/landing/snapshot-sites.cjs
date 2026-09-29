const fs = require('node:fs');
module.exports = file => {
  // Without a file, the customer site comes from LANDING_CUSTOMER_URL (no default).
  if (!file && !process.env.LANDING_CUSTOMER_URL) throw Error('Pass a sites file or set LANDING_CUSTOMER_URL');
  const sites = file ? JSON.parse(fs.readFileSync(file,'utf8')) : [
    ['customer', process.env.LANDING_CUSTOMER_URL], ['bubble','https://bubble.io/']
  ];
  if (!Array.isArray(sites) || sites.length === 0) throw Error('Expected a nonempty list of [site, URL] pairs');
  const names = new Set();
  for (const pair of sites) {
    if (!Array.isArray(pair) || pair.length !== 2 || !/^[a-z][a-z0-9-]*$/.test(pair[0]) || names.has(pair[0])) throw Error('Site names must be unique safe slugs');
    const url = new URL(pair[1]);
    if (!['https:','http:'].includes(url.protocol) || url.username || url.password) throw Error('Expected an anonymous HTTP(S) URL');
    names.add(pair[0]);
  }
  return sites;
};
