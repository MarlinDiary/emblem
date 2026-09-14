# Architecture

Emblem is a sandboxed-style local companion rather than a Mail plug-in. Three modules enforce the primary boundaries.

## Modules

### PortraitCore

`PortraitCore` owns email/domain parsing, Public Suffix List routing, BIMI and website discovery policy, image validation, circular composition, candidate ranking, and journaled contact changes. It has no Gmail token storage or application UI.

### Emblem

The executable owns SwiftUI/AppKit views, Gmail metadata ingestion, bounded Apple Mail scanning, automatic orchestration, the Keychain adapter, the foreground/background library lease, and Contacts synchronization.

The sender column is an `NSTableView` source list wrapped in `NSViewRepresentable`. AppKit requests only visible cells. `rowsRevision`, section/search identity, batch presentation, and native selection are tracked separately so unrelated `AppModel` publications do not rebuild all rows. On launch, legacy-row normalization is completed in one local value and the image-bearing array is published once rather than once per sender.

### PortraitContactsBridge

The Objective-C bridge exposes only Contacts change-history operations unavailable through the required Swift surface. App-authored transactions use `com.protoyard.emblem` as their author so a stable no-external-change pass can skip reading every linked card.

## Data flow

1. Gmail history is checked for healthy connected Gmail accounts. Only metadata fields are requested.
2. Apple Mail covers other accounts and retrying Gmail accounts. Scanner responses are bounded batches produced by a short-lived worker.
3. Sender identity and received date are committed before the corresponding provider cursor advances.
4. Due avatar jobs are grouped by proven identity/site and resolved with bounded concurrency.
5. The UI renders the chosen candidate or a local monogram. Candidate inspection alone has no Contacts side effect.
6. When automatic sync is enabled, an eligible sender is matched or created in Contacts. Existing photos and ambiguous matches are preserved unless the user deliberately selects a replacement.
7. A write-ahead journal records the intended mutation, Contacts is changed, and the result is read back before the record becomes applied.

An empty Gmail history page advances only the Gmail cursor; it does not rewrite `senders.json`. Receipt-only changes for known senders are committed to `inbox-receipts.json` before the Gmail cursor advances; the overlay is folded into the main library on its next real save. A Contacts history token avoids a 649-card full read when no external change occurred. History enumeration runs off the main actor with a two-second deadline; missing, expired, failed, or timed-out history always falls back to a conservative full read.

## Identity boundaries

- Academic and shared-provider mailboxes remain separate.
- Rotating role addresses may share a display/contact identity only when the brand scope is proven by registrable domain and the app-managed contact remains unambiguous.
- Cross-domain person grouping requires exact full-name evidence, compatible address tokens, and an existing person-photo signal.
- Grouping is presentational; mutation expands to explicit member addresses and rechecks Contacts before writing.

## Image boundaries

- Person sources: centered aspect fill.
- Ordinary brand artwork: edge-color-aware safe canvas.
- Precomposed app icons: preserve the source canvas.
- Manifest `maskable` icons: may use full-bleed composition.
- Low-resolution, blank, overly blurred, oversized, or dynamically dependent images are rejected.

BIMI declarations and website artwork are recognition hints, not authentication. The current implementation does not validate VMC/CMC certificate chains.

## Network boundary

All discovery fetches use public HTTPS on port 443. Credential-bearing URLs, loopback/private/link-local destinations, unsafe redirects, excessive responses, and external/dynamic SVG resources are rejected. The resolver bounds time, payload size, dimensions, redirects, candidate count, and concurrency. It parses static metadata and does not execute page scripts.

## Storage and concurrency

Application data lives in `~/Library/Application Support/Emblem/`; Gmail credentials and OAuth client configuration live in Keychain. The foreground app and the `SMAppService` background job acquire the same non-blocking `flock` lease. A foreground request asks a running bounded job to cancel, await its tasks, checkpoint, and release the lease before the GUI opens the live library.

## Push development

The optional `Push/` relay receives authenticated Gmail Pub/Sub hints and routes them to hibernatable per-account WebSockets. The launchd helper keeps sockets independently of the foreground writer lease. A durable, separately locked hint inbox and distributed signal wake the library owner. Notifications never advance a Gmail cursor; the normal persisted history ingestion and Contacts journal remain authoritative. Daily watch renewal, device expiry alarms, reconnect catch-up and safety polling preserve recovery. See [operations](gmail-push-operations.md) for deployment, privacy and acceptance boundaries.

## Recovery boundary

Prepared journal records are never guessed away. Re-running sync cannot duplicate an unresolved mutation. Undo restores a previous photo or removes only an unchanged app-created contact. External contact edits, missing history, and inconsistent read-back stop destructive cleanup and retain evidence for review.
