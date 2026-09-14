# Emblem public website

Public informational site at https://emblem.protoyard.com/.
The independent `emblem-site` Cloudflare Worker serves nine bounded static
resources. It has no storage bindings, credentials, forms, mailbox backend, client
JavaScript or external subresource requests. Worker request logging is deliberately
disabled for this informational site; Cloudflare platform security processing is
disclosed in the privacy policy. The former MailPortrait hostname redirects each
path and query to the matching Emblem URL.

## Build and test

```sh
node build.mjs
node test.mjs
python3 -m unittest test_rollback.py -v
```

`build.mjs` is the content source. `worker.mjs` is the deployed module, and `dist/`
contains the same static files. It copies the application's existing MIT license.
Native Cloudflare Web APIs are used; Node dependencies are not needed at runtime.

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
