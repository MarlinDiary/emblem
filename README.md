# Emblem

Emblem is a local-first macOS companion for sender avatars in Apple Mail. It discovers people and brands from Gmail or Apple Mail, finds high-quality public artwork, and keeps the matching cards in Apple Contacts up to date.

- Native SwiftUI and AppKit interface with macOS materials and controls
- No Mail plug-in, browser extension, hosted account, analytics, or menu-bar item
- Open source under the MIT License
- Current source: **0.20.0**; latest stable download: **0.19.0**

Download: [Emblem 0.19.0 for macOS](https://github.com/MarlinDiary/emblem/releases/download/v0.19.0/Emblem-0.19.0-macOS.zip) · Website: [emblem.protoyard.com](https://emblem.protoyard.com/) · Privacy: [emblem.protoyard.com/privacy](https://emblem.protoyard.com/privacy/)

[0.20.0 RC2 preview](https://github.com/MarlinDiary/emblem/releases/tag/v0.20.0-rc.2) adds Gmail Push, progressive avatars and signed app updates. Public Google review and multi-day acceptance remain separate gates. Build52 real own INBOX+SENT participant measured Push1.81s and independently verified first Contacts photo5.37s; this is a sample, not a delivery guarantee.

## What it does

### Inbox discovery

- Gmail is the primary provider for every healthy, fully caught-up connected Gmail account.
- Gmail access is limited to `gmail.metadata`: message identifiers, `From` headers, labels, and received dates. Emblem does not request bodies, subjects, attachments, send, or modify access.
- Apple Mail covers non-Gmail accounts and automatically becomes the fallback when a Gmail account needs to retry.
- The list follows inbox recency. Rotating transactional aliases from the same proven brand can share one display group and one app-managed contact; academic, shared-provider, and distinct person identities stay separate.

### Avatar discovery

Emblem evaluates sources by identity evidence, clarity, and circular suitability instead of applying one universal crop:

1. unique exact-name public profile matches for supported organization directories
2. circle-suitable BIMI artwork
3. verified first-party brand assets
4. Apple Touch Icons, Web App Manifest icons, and structured website logos
5. website icons and a registrable-domain icon fallback
6. optional Libravatar and Gravatar lookups
7. a crisp, deterministic monogram generated on the Mac immediately while better artwork is fetched; unchanged app-managed provisional photos can upgrade automatically

Raster candidates below the quality threshold, blank/placeholder portraits, and badly blurred brand images are rejected. Person photos use a centered fill; ordinary logos retain a safe area; declared app-icon canvases and maskable artwork preserve their intended geometry.

### Contacts sync

Automatic Contacts sync is opt-in. Once enabled, new eligible senders and selected replacement photos are synchronized without per-item confirmation.

- Existing personal photos are preserved unless you deliberately choose another photo.
- Every mutation is preceded by a durable journal intent and followed by a read-back check.
- Ignore is a stop signal. It undoes Emblem-managed changes and removes only unchanged contacts created by Emblem; later user edits are preserved.
- External Contact edits and deletions are detected through Contacts change history. A no-change background pass skips the full linked-card read.

### Background operation

**Continue after quitting** registers a macOS-managed login item with `SMAppService`. The foreground process exits on Command-Q; a bounded headless job checks incremental Gmail history first and uses Apple Mail as needed. Gmail Push notifications wake the resident helper immediately. A 15-minute safety check recovers missed hints when every account has healthy Push; non-Push/failed Gmail or Apple Mail fallback retains its one-minute scheduling while awake. Watches renew automatically each day. The older tagged 0.19.0 release uses polling; current `main` includes Push. See [Push operations and acceptance](docs/gmail-push-operations.md).

The foreground app and background job share an exclusive library lease, so they do not write the local library or Contacts concurrently.

## Performance

Version 0.18 replaces the sender sidebar's per-row SwiftUI tree with a virtualized AppKit source-list table. Only visible cells and avatars are created. Selection does not reload the table, and every section/search preserves its own scroll position.

Background passes transform the decoded library before publishing it once, retain that loaded revision, persist receipt-only Gmail changes in a small overlay, and bound Contacts history IPC before conservatively falling back to a linked-card read. Legacy photo-fingerprint enrichment is versioned and runs once. New mail and idle shutdown therefore do not copy, rescan, or re-encode every cached image.

Regression coverage includes a 1,800-row native table, a 903-row selection benchmark, empty Gmail history pages that leave the large sender library untouched, and a Contacts change-history fast path.

## App updates

The visible app checks an Ed25519-signed update feed with Sparkle. Disable automatic checks in Settings; installation is your choice. Workers and the background mail helper never launch update UI. See [software updates](docs/software-updates.md).

## Public Gmail readiness

Public Google verification and clean-Mac OAuth onboarding are separate release gates. Official packages can include complete public Desktop application configuration; source builds without it request a Desktop OAuth JSON before sign-in. An existing authorized account is not proof of public approval. See [Google verification](docs/google-verification.md) and [release acceptance](docs/acceptance-0.20.md).

## Requirements

- macOS 14 or later
- Xcode 26 or later to build
- Apple Silicon is the currently tested binary architecture
- Contacts permission for synchronization
- Apple Events permission only when the Apple Mail provider is enabled

Liquid Glass controls are used on macOS 26 or later; older supported systems receive standard native controls.

## Build

```sh
git clone https://github.com/MarlinDiary/emblem.git
cd emblem
swift test
bash Scripts/build-app.sh
open build/Emblem.app
```

`build-app.sh` never overwrites an existing output. It uses an unambiguous Developer ID Application identity when one is available and otherwise performs an ad-hoc local signature. The downloadable release is Developer ID signed, notarized by Apple, and has its notarization ticket stapled to the app bundle.

Dependencies are resolved by Swift Package Manager. AppAuth 3.0.0 is used for OAuth; third-party notices are included in the app bundle and repository.

## Gmail configuration

The repository contains no OAuth client secret, refresh token, mailbox data, or maintainer credentials.

For a source build:

1. Create an OAuth client of type **Desktop app** in a Google Cloud project with the Gmail API enabled.
2. Open Emblem → Settings → General → **Connect Gmail…**.
3. Choose the downloaded desktop client JSON once, then finish consent in the system browser.

Imported client configuration and private account authorization are stored in the macOS Keychain, not the sender library. Official packages can include Google’s public **installed-application** configuration at build time; this never includes user access/refresh tokens, Apple passwords or service-account keys:

```sh
EMBLEM_GOOGLE_DESKTOP_CONFIG_FILE='/absolute/path/to/desktop-client.json' \
  bash Scripts/build-app.sh
```

Google describes installed-app client configuration as [public, embedded application configuration](https://developers.google.com/identity/protocols/oauth2#installed-applications), not confidential user authorization. PKCE and browser consent remain required. The build validates Desktop type and rejects tokens and service-account configurations.

A broadly distributed OAuth client must satisfy Google's consent-screen and restricted-scope requirements. Testing-mode grants may have shorter lifetimes.

## Gmail Push and outgoing discovery development

`Push/` contains the optional Cloudflare relay, with RSA-verified Google registration and authenticated Pub/Sub delivery. The Mac receives hints over a persistent, OS-managed background WebSocket, replays its saved Gmail history cursor and renews the watch automatically. This needs deployment in the desktop client's Google Cloud project plus real-mail acceptance before a release. [Setup, timing, privacy and rollback](docs/gmail-push-operations.md).

## Privacy and security

- Sender addresses, cached images, settings, and mutation journals stay under `~/Library/Application Support/Emblem/` with restricted permissions.
- Gmail credentials and imported OAuth client configuration stay in the login Keychain.
- Website discovery accepts only public HTTPS endpoints on port 443, rejects credential-bearing/private-network URLs, and bounds redirects, download sizes, SVG features, image dimensions, and concurrency.
- Enabling Libravatar and Gravatar sends each service a hash derived from the sender address. This hash is not anonymous because anyone who already knows the address can compute it.
- Organization-directory lookup sends an exact display name to the matching institution's public directory. Domain icon fallback sends only the registrable domain.
- BIMI and website artwork improve recognition; they do **not** prove that a message is authentic. VMC/CMC certificate-chain validation is not implemented.

Do not attach your Emblem data directory, mailbox diagnostics, or contact images to a public issue. See [SECURITY.md](SECURITY.md) for private vulnerability reporting guidance.

## Verification

```sh
swift test
build/Emblem.app/Contents/MacOS/Emblem \
  --self-test --data-dir /tmp/emblem-self-test
```

The self-test prints a unique `ROLLBACK_FIXTURE` path. Verify the runnable rollback using that exact fixture:

```sh
EMBLEM_BINARY="$PWD/build/Emblem.app/Contents/MacOS/Emblem" \
  bash Scripts/rollback.sh --fixture /absolute/path/from/ROLLBACK_FIXTURE
```

These commands use file-backed synthetic Contacts and do not read or write the real address book. See [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) for the full release boundary.

## Architecture

- `PortraitCore`: domain routing, source policy, image validation/composition, journaled Contacts changes
- `Emblem`: native UI, Gmail and Mail ingestion, Contacts synchronization, background lifecycle
- `PortraitContactsBridge`: narrowly scoped Contacts change-history calls

The design and trust boundaries are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Contributing

Issues and pull requests are welcome. Use synthetic fixtures, keep all I/O bounded, and preserve the read-back and rollback invariants. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE) and [docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md).

The development branch also discovers the **To/Cc recipients of sent mail**, including people who have never emailed you. Gmail still uses `gmail.metadata`; it requests only From/To/Cc, IDs, labels and dates, not Bcc, bodies or subjects. Sent history and watch hints enter the same automatic avatar lookup and journaled Contacts sync as inbox senders. Legacy accounts backfill Sent separately without discarding their accepted inbox cursor. Apple Mail has an independent paged Sent import and overlapping recent delta when Gmail is unavailable. Outgoing activity does not replace inbox recency, and your own send-as addresses and ignored identities are excluded.

## Public website

`Site/` contains the reproducible static Cloudflare site, signed stable feed and privacy/terms. Run `cd Site && node build.mjs && node test.mjs`. Stable0.19 and Universal0.20 RC2 are labelled separately; preview acceptance is not stable promotion.
