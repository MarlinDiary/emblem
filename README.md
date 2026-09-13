# MailPortrait

MailPortrait is a local-first macOS companion for sender avatars in Apple Mail. It discovers people and brands from Gmail or Apple Mail, finds high-quality public artwork, and keeps the matching cards in Apple Contacts up to date.

- Native SwiftUI and AppKit interface with macOS materials and controls
- No Mail plug-in, browser extension, hosted account, analytics, or menu-bar item
- Open source under the MIT License
- Current version: **0.18.1**

Download: [MailPortrait 0.18.1 for macOS](https://github.com/MarlinDiary/mail-portrait/releases/download/v0.18.1/MailPortrait-0.18.1-macOS.zip) · Website: [mailportrait.protoyard.com](https://mailportrait.protoyard.com/) · Privacy: [mailportrait.protoyard.com/privacy](https://mailportrait.protoyard.com/privacy/)

## What it does

### Inbox discovery

- Gmail is the primary provider for every healthy, fully caught-up connected Gmail account.
- Gmail access is limited to `gmail.metadata`: message identifiers, `From` headers, labels, and received dates. MailPortrait does not request bodies, subjects, attachments, send, or modify access.
- Apple Mail covers non-Gmail accounts and automatically becomes the fallback when a Gmail account needs to retry.
- The list follows inbox recency. Rotating transactional aliases from the same proven brand can share one display group and one app-managed contact; academic, shared-provider, and distinct person identities stay separate.

### Avatar discovery

MailPortrait evaluates sources by identity evidence, clarity, and circular suitability instead of applying one universal crop:

1. unique exact-name public profile matches for supported organization directories
2. circle-suitable BIMI artwork
3. verified first-party brand assets
4. Apple Touch Icons, Web App Manifest icons, and structured website logos
5. website icons and a registrable-domain icon fallback
6. optional Libravatar and Gravatar lookups
7. a crisp, deterministic monogram generated on the Mac

Raster candidates below the quality threshold, blank/placeholder portraits, and badly blurred brand images are rejected. Person photos use a centered fill; ordinary logos retain a safe area; declared app-icon canvases and maskable artwork preserve their intended geometry.

### Contacts sync

Automatic Contacts sync is opt-in. Once enabled, new eligible senders and selected replacement photos are synchronized without per-item confirmation.

- Existing personal photos are preserved unless you deliberately choose another photo.
- Every mutation is preceded by a durable journal intent and followed by a read-back check.
- Ignore is a stop signal. It undoes MailPortrait-managed changes and removes only unchanged contacts created by MailPortrait; later user edits are preserved.
- External Contact edits and deletions are detected through Contacts change history. A no-change background pass skips the full linked-card read.

### Background operation

**Continue after quitting** registers a macOS-managed login item with `SMAppService`. The foreground process exits on Command-Q; a bounded headless job checks incremental Gmail history first and uses Apple Mail as needed. It runs approximately once a minute while the user is logged in and the Mac is awake. It is polling, not push.

The foreground app and background job share an exclusive library lease, so they do not write the local library or Contacts concurrently.

## Performance

Version 0.18 replaces the sender sidebar's per-row SwiftUI tree with a virtualized AppKit source-list table. Only visible cells and avatars are created. Selection does not reload the table, and every section/search preserves its own scroll position.

Background passes transform the decoded library before publishing it once, retain that loaded revision, persist receipt-only Gmail changes in a small overlay, and bound Contacts history IPC before conservatively falling back to a linked-card read. Legacy photo-fingerprint enrichment is versioned and runs once. New mail and idle shutdown therefore do not copy, rescan, or re-encode every cached image.

Regression coverage includes a 1,800-row native table, a 903-row selection benchmark, empty Gmail history pages that leave the large sender library untouched, and a Contacts change-history fast path.

## Requirements

- macOS 14 or later
- Xcode 26 or later to build
- Apple Silicon is the currently tested binary architecture
- Contacts permission for synchronization
- Apple Events permission only when the Apple Mail provider is enabled

Liquid Glass controls are used on macOS 26 or later; older supported systems receive standard native controls.

## Build

```sh
git clone https://github.com/MarlinDiary/mail-portrait.git
cd mail-portrait
swift test
bash Scripts/build-app.sh
open build/MailPortrait.app
```

`build-app.sh` never overwrites an existing output. It uses an unambiguous Developer ID Application identity when one is available and otherwise performs an ad-hoc local signature. The downloadable release is Developer ID signed, notarized by Apple, and has its notarization ticket stapled to the app bundle.

Dependencies are resolved by Swift Package Manager. AppAuth 3.0.0 is used for OAuth; third-party notices are included in the app bundle and repository.

## Gmail configuration

The repository contains no OAuth client secret, refresh token, mailbox data, or maintainer credentials.

For a source build:

1. Create an OAuth client of type **Desktop app** in a Google Cloud project with the Gmail API enabled.
2. Open MailPortrait → Settings → General → **Connect Gmail…**.
3. Choose the downloaded desktop client JSON once, then finish consent in the system browser.

The imported client configuration and account authorization are stored in the macOS Keychain, not the sender library. Maintainers can bundle a public client identifier at build time:

```sh
MAILPORTRAIT_GOOGLE_CLIENT_ID='YOUR_CLIENT_ID.apps.googleusercontent.com' \
  bash Scripts/build-app.sh
```

A broadly distributed OAuth client must satisfy Google's consent-screen and restricted-scope requirements. Testing-mode grants may have shorter lifetimes.

## Privacy and security

- Sender addresses, cached images, settings, and mutation journals stay under `~/Library/Application Support/MailPortrait/` with restricted permissions.
- Gmail credentials and imported OAuth client configuration stay in the login Keychain.
- Website discovery accepts only public HTTPS endpoints on port 443, rejects credential-bearing/private-network URLs, and bounds redirects, download sizes, SVG features, image dimensions, and concurrency.
- Enabling Libravatar and Gravatar sends each service a hash derived from the sender address. This hash is not anonymous because anyone who already knows the address can compute it.
- Organization-directory lookup sends an exact display name to the matching institution's public directory. Domain icon fallback sends only the registrable domain.
- BIMI and website artwork improve recognition; they do **not** prove that a message is authentic. VMC/CMC certificate-chain validation is not implemented.

Do not attach your MailPortrait data directory, mailbox diagnostics, or contact images to a public issue. See [SECURITY.md](SECURITY.md) for private vulnerability reporting guidance.

## Verification

```sh
swift test
build/MailPortrait.app/Contents/MacOS/MailPortrait \
  --self-test --data-dir /tmp/mailportrait-self-test
```

The self-test prints a unique `ROLLBACK_FIXTURE` path. Verify the runnable rollback using that exact fixture:

```sh
MAILPORTRAIT_BINARY="$PWD/build/MailPortrait.app/Contents/MacOS/MailPortrait" \
  bash Scripts/rollback.sh --fixture /absolute/path/from/ROLLBACK_FIXTURE
```

These commands use file-backed synthetic Contacts and do not read or write the real address book. See [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) for the full release boundary.

## Architecture

- `PortraitCore`: domain routing, source policy, image validation/composition, journaled Contacts changes
- `MailPortrait`: native UI, Gmail and Mail ingestion, Contacts synchronization, background lifecycle
- `PortraitContactsBridge`: narrowly scoped Contacts change-history calls

The design and trust boundaries are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Contributing

Issues and pull requests are welcome. Use synthetic fixtures, keep all I/O bounded, and preserve the read-back and rollback invariants. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE) and [docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md).
