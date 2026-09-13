# Release checklist

## Source and privacy

- [ ] `git diff --check` passes.
- [ ] `swift test` passes with no unexpected skip or network dependency.
- [ ] Source/archive scan finds no OAuth JSON, secrets, tokens, real MailPortrait library, personal diagnostics, contact images, or signing material.
- [ ] Dependency licenses and privacy descriptions are present.

## Isolated behavior

- [ ] Packaged `--self-test` passes and prints zero real Contacts/Mail operations.
- [ ] `Scripts/rollback.sh` passes against the exact printed fixture.
- [ ] Empty Gmail history advances its cursor without replacing the sender library.
- [ ] 1,800-row native table creates only visible cells; selection does not reload all rows.
- [ ] Toolbar/search object identity is stable across sender selection.
- [ ] Denied/revoked permissions, duplicate Contacts, malformed provider data, low-resolution images, timeout, cancellation, restart, and prepared-journal recovery are covered.

## Live macOS boundary

- [ ] Full current `.app` path is used so duplicate bundle identifiers do not confuse LaunchServices or TCC.
- [ ] Gmail bootstrap and history cursor are complete; Gmail-primary and Mail-fallback routing are observed.
- [ ] Command-Q exits the foreground process; a later login-item run completes with Gmail primary and exit status 0.
- [ ] A no-change background pass skips the linked-card full read and large sender-library rewrite.
- [ ] Disposable Contacts: create/update, read-back in Contacts, Mail appearance, restart, external edit, ignore, and undo/delete protection are observed separately.
- [ ] Minimum supported macOS and each shipped architecture are tested.

## Distribution

- [ ] Developer ID signature verifies with `codesign --verify --deep --strict`.
- [ ] Release archive is notarized and stapled before publishing a downloadable binary.
- [ ] Tag, source archive, release notes, website links, and rollback artifact refer to the same version and hashes.

Unchecked items are boundaries, not implicit claims. Source publication and binary distribution are separate gates.
