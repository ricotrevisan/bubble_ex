const fs = require('node:fs');
module.exports = file => {
  const sites = file ? JSON.parse(fs.readFileSync(file,'utf8')) : [
    ['mochary','https://beta.mocharymethod.com/'], ['bubble','https://bubble.io/']
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
