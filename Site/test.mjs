import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import worker from './worker.mjs';
const origin='https://emblem.protoyard.com';
const homeHtml=await (await worker.fetch(new Request(origin+'/'))).text();
const scriptPath=homeHtml.match(/<script type="module" src="(\/assets\/home\.[0-9a-f]{10}\.js)"><\/script>/)?.[1];
const stylePath=homeHtml.match(/<link rel="stylesheet" href="(\/assets\/home\.[0-9a-f]{10}\.css)">/)?.[1];
assert.ok(scriptPath&&stylePath,'hashed homepage assets');
for(const path of ['/','/privacy/','/terms/','/style.css','/icon.svg','/license.txt','/licenses.txt','/robots.txt','/sitemap.xml','/appcast.xml',scriptPath,stylePath]) {
  const response=await worker.fetch(new Request(origin+path));
  assert.equal(response.status,200);
  assert.equal(response.headers.get('set-cookie'),null);
  const csp=response.headers.get('content-security-policy');
  assert.ok(csp.includes("default-src 'none'")&&csp.includes("script-src 'self'"));
  assert.doesNotMatch(csp,/unsafe|https?:|data:|blob:|\*/);
  const body=await response.text();assert.ok(body.length>10);
  if(response.headers.get('content-type').includes('text/html')) {
    assert.match(body,/<html lang="en">/);assert.match(body,/href="\/privacy\/"/);assert.match(body,/href="\/terms\/"/);
    assert.doesNotMatch(body,/GOCSPX-|apps\.googleusercontent\.com|cni586@|example\.com|\son[a-z]+=/i);
    // Only the homepage runs a script: one hashed, self-hosted module, never inline.
    const scripts=body.match(/<script\b[^>]*>/g)||[];
    if(path==='/') {assert.equal(scripts.length,1);assert.equal(scripts[0],`<script type="module" src="${scriptPath}">`);assert.match(body,/<script type="module" src="[^"]+"><\/script>/);}
    else assert.equal(scripts.length,0,path);
    for(const [,link] of body.matchAll(/href="(\/[^"#]*)"/g)) assert.equal((await worker.fetch(new Request(origin+link))).status,200,link);
  }
  if(path.startsWith('/assets/')) assert.equal(response.headers.get('cache-control'),'public, max-age=31536000, immutable');
  else assert.equal(response.headers.get('cache-control'),'public, max-age=300');
  const head=await worker.fetch(new Request(origin+path,{method:'HEAD'}));assert.equal(head.status,200);assert.equal(await head.text(),'');
  console.log(`PASS GET/HEAD ${path}`);
}
assert.equal((await worker.fetch(new Request(origin+'/privacy'))).status,308);
assert.equal((await worker.fetch(new Request(origin+'/missing'))).status,404);
assert.equal((await worker.fetch(new Request(origin+'/__proto__'))).status,404);
const unknownAsset=await worker.fetch(new Request(origin+'/assets/home.0000000000.js'));assert.equal(unknownAsset.status,404);assert.equal(unknownAsset.headers.get('cache-control'),'public, max-age=300');
assert.equal((await worker.fetch(new Request(origin+'/',{method:'POST',body:'ignored'}))).status,405);
const legacy=await worker.fetch(new Request('https://mailportrait.protoyard.com/privacy/?from=old'));
assert.equal(legacy.status,308);
assert.equal(legacy.headers.get('location'),'https://emblem.protoyard.com/privacy/?from=old');
const privacy=await (await worker.fetch(new Request(origin+'/privacy/'))).text();
for(const phrase of ['gmail.metadata','Limited Use','Keychain','not anonymous','Gravatar','Libravatar','Disconnecting does not remove','Cloudflare']) assert.ok(privacy.includes(phrase),phrase);
console.log('PASS links, privacy disclosures, redirects, 404, method boundary and no embedded credentials');

const feed=await (await worker.fetch(new Request(origin+'/appcast.xml'))).text();assert.match(feed,/sparkle-signatures:/);assert.match(feed,/<channel>/);
const siteIcon=await (await worker.fetch(new Request(origin+'/icon.svg'))).text();
for(const asset of ['Head.svg','Body.svg']) {
  const glyph=await readFile(new URL('../Resources/AppIcon.icon/Assets/'+asset,import.meta.url),'utf8');
  assert.ok(siteIcon.includes(glyph.match(/ d="([^"]+)"/)[1]));
}
assert.equal((siteIcon.match(/<path /g)||[]).length,2);
assert.match(siteIcon,/fill="#8C9370"/);
assert.match(siteIcon,/mix-blend-mode:multiply/);
assert.doesNotMatch(siteIcon,/#2b70f4|Emblem.svg/);
const home=homeHtml;
assert.match(home,/0.20.0 RC5 preview/);
assert.match(home,/releases\/tag\/v0.20.0-rc.5/);
assert.match(home,/releases\/download\/v0.19.0/);
console.log('PASS approved four-vector branding, RC5 preview label and unchanged stable download');

// The scene is decoration: it may not reach the network, storage or cookies,
// and every public statement stays readable HTML.
const source=await readFile(new URL('./src/home.js',import.meta.url),'utf8');
assert.doesNotMatch(source,/\bfetch\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|localStorage|sessionStorage|indexedDB|document\.cookie|https?:\/\//);
const bundle=await (await worker.fetch(new Request(origin+scriptPath))).text();
assert.doesNotMatch(bundle,/sendBeacon|document\.cookie|localStorage|sessionStorage|indexedDB/);
assert.match(bundle,/three\.js authors|Three\.js Authors/i);
assert.ok(bundle.length<900_000,`homepage module ${bundle.length} bytes`);
assert.ok((await readFile(new URL('./worker.mjs',import.meta.url))).length<2_500_000,'worker size');
for(const phrase of ['Emblem finds sender photos and brand icons','Gmail metadata only','Your sender library stays on your Mac','href="/privacy/"','Not affiliated with Apple or Google']) assert.ok(home.includes(phrase),phrase);
const licenses=await (await worker.fetch(new Request(origin+'/licenses.txt'))).text();
assert.match(licenses,/three\.js 0\.186\.1/);assert.match(licenses,/MIT License/);
console.log('PASS one self-hosted network-free homepage module, script-free legal pages, immutable hashed assets and third-party license');
