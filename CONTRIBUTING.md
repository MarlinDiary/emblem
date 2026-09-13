# Contributing to Emblem

Thank you for helping improve Emblem.

## Before opening a change

1. Search existing issues and keep each pull request focused.
2. Use synthetic sender addresses, fixture Contacts, and captured public test assets. Never commit a real Emblem library, mailbox diagnostics, OAuth JSON, token, contact photo, or signing credential.
3. For a bug fix, add a failing regression first, make the smallest implementation change, then run the same test and the complete suite.

## Local checks

```sh
swift test
bash Scripts/build-app.sh
build/Emblem.app/Contents/MacOS/Emblem --self-test --data-dir /tmp/emblem-self-test
```

Also run `git diff --check` and inspect every new network endpoint and user-facing string.

## Invariants

- Gmail remains metadata-only.
- Discovery and rendering never mutate Contacts.
- Contacts writes require the user's previously enabled sync scope or a deliberate photo choice.
- Existing personal photos and ambiguous contact matches are preserved.
- A durable intent precedes every Contacts write; a read-back follows it.
- Person, mailbox, and brand identities are not merged from a name alone.
- Network fetches remain public-HTTPS-only, bounded, cancellable, and provenance-preserving.
- Large-list changes must preserve virtualization and stable toolbar/search identity.

## Brand assets

Prefer first-party evidence and URLs rather than committing third-party brand images. A brand-source contribution should include the registrable domain, first-party evidence page, source image URL, artwork semantics, and a fixture proving its ranking and circular presentation.
