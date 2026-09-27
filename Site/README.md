# Emblem public website

Public informational site at https://emblem.protoyard.com/.
The independent `emblem-site` Cloudflare Worker serves twelve bounded static
resources. It has no storage bindings, credentials, forms, mailbox backend, analytics
or external subresource requests. The homepage runs one self-hosted module that
paints a three.js WebGL scene behind ordinary HTML; the Content Security Policy
allows only same-origin scripts and no network connections, and the privacy and
terms pages carry no script at all. Worker request logging is deliberately
disabled for this informational site; Cloudflare platform security processing is
disclosed in the privacy policy. The former MailPortrait hostname redirects each
path and query to the matching Emblem URL.

## Build and test

```sh
npm ci
node build.mjs
node test.mjs
python3 -m unittest test_rollback.py -v
node serve.mjs   # http://localhost:8788/ through the generated Worker
```

`build.mjs` is the content source; `src/home.js` and `src/home.css` are the homepage
scene and styles, bundled with esbuild into content-hashed `/assets/` files that
are cached as immutable. `worker.mjs` is the deployed module, and `dist/` contains
the same static files. It copies the application's existing MIT license and serves
three.js's license at `/licenses.txt`. esbuild and three are locked build-time
dependencies; the Worker itself needs none at runtime.

On localhost only, `?act=3&t=7` shows one act with the scene fast-forwarded seven
seconds, which makes headless captures of every act reproducible. The scene fails
closed: without WebGL the page shows the static icon, and reduced motion replaces
the flights with cross-fades.

## Deployment

The production upload uses Wrangler and binds `emblem.protoyard.com` plus the
legacy redirect at `mailportrait.protoyard.com`. Cloudflare manages both DNS
entries and certificates. `workers.dev` and preview URLs are disabled.

Deploy the tested module with `../Push/node_modules/.bin/wrangler deploy` from this directory.

## Withdrawal

First keep the Google OAuth branding links valid, or return the OAuth project to
Testing. `python3 rollback.py` checks the exact website binding without changing
it. `python3 rollback.py --apply` withdraws only these two custom domains and Worker.
It uses the current Wrangler OAuth login, or a scoped `CLOUDFLARE_API_TOKEN` from
the environment. No credential is included here. The rollback was executed against isolated API state in unit tests;
the public website is intentionally left deployed. Neither mode disconnects Gmail
or edits the Emblem library, Contacts, apex domain, or other subdomains.
