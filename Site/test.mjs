import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from './worker.mjs';
const origin='https://emblem.protoyard.com';
for(const path of ['/','/privacy/','/terms/','/style.css','/icon.svg','/license.txt','/robots.txt','/sitemap.xml','/appcast.xml']) {
  const response=await worker.fetch(new Request(origin+path));
  assert.equal(response.status,200);
  assert.equal(response.headers.get('set-cookie'),null);
  assert.ok(response.headers.get('content-security-policy').includes("default-src 'none'"));
  const body=await response.text();assert.ok(body.length>10);
  if(response.headers.get('content-type').includes('text/html')) {
    assert.match(body,/<html lang="en">/);assert.match(body,/href="\/privacy\/"/);assert.match(body,/href="\/terms\/"/);
    assert.doesNotMatch(body,/<script|GOCSPX-|apps\.googleusercontent\.com|cni586@|example\.com/);
    for(const [,link] of body.matchAll(/href="(\/[^"#]*)"/g)) assert.equal((await worker.fetch(new Request(origin+link))).status,200,link);
  }
  const head=await worker.fetch(new Request(origin+path,{method:'HEAD'}));assert.equal(head.status,200);assert.equal(await head.text(),'');
  console.log(`PASS GET/HEAD ${path}`);
}
assert.equal((await worker.fetch(new Request(origin+'/privacy'))).status,308);
assert.equal((await worker.fetch(new Request(origin+'/missing'))).status,404);
assert.equal((await worker.fetch(new Request(origin+'/__proto__'))).status,404);
assert.equal((await worker.fetch(new Request(origin+'/',{method:'POST',body:'ignored'}))).status,405);
const legacy=await worker.fetch(new Request('https://mailportrait.protoyard.com/privacy/?from=old'));
assert.equal(legacy.status,308);
assert.equal(legacy.headers.get('location'),'https://emblem.protoyard.com/privacy/?from=old');
const privacy=await (await worker.fetch(new Request(origin+'/privacy/'))).text();
for(const phrase of ['gmail.metadata','Limited Use','Keychain','not anonymous','Gravatar','Libravatar','Disconnecting does not remove','Cloudflare']) assert.ok(privacy.includes(phrase),phrase);
console.log('PASS links, privacy disclosures, redirects, 404, method boundary and no embedded credentials');

const feed=await (await worker.fetch(new Request(origin+'/appcast.xml'))).text();assert.match(feed,/sparkle-signatures:/);assert.match(feed,/<channel>/);
const appGlyph=await readFile(new URL('../Resources/AppIcon.icon/Assets/Emblem.svg',import.meta.url),'utf8');
const siteIcon=await (await worker.fetch(new Request(origin+'/icon.svg'))).text();
assert.equal(siteIcon.match(/ d="([^"]+)"/)[1],appGlyph.match(/ d="([^"]+)"/)[1]);
assert.equal((siteIcon.match(/<path /g)||[]).length,1);
console.log('PASS website reuses the app portrait-and-ring compound glyph');
