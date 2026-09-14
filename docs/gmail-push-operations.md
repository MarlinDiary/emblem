# Gmail instant updates

This feature is on the development branch. The tagged 0.19.0 release still uses regular Gmail checks. Do not advertise a configured relay as a verified live mailbox watch.

## Data flow

Gmail `users.watch` (INBOX and SENT) → Pub/Sub authenticated HTTPS Push → Cloudflare Worker → per-account SQLite Durable Object with hibernatable WebSockets → Emblem's macOS-managed background helper → the process holding the library lease → `history.list` → inbox senders and To/Cc sent recipients → existing avatar lookup and journaled Contacts sync.

The foreground app exits on Command-Q. The helper is a separate `SMAppService` login item: it starts at login, stays connected while at least one mailbox has a valid Push registration, and yields library writes to the visible app. Without a Push-ready account it keeps the existing bounded, approximately one-minute job. macOS approval in Login Items remains required when the OS requests it.

The listener also probes writer ownership without retaining the lease. When the foreground process exits it starts a catch-up pass within the ten-second ownership check, so unfinished photo work does not wait for the next 15-minute Gmail safety check.

Notifications are **hints**, not authoritative cursors. Emblem replays its persisted cursor, never jumps to the notification/watch history ID, coalesces a burst per account, and continues long history pagination immediately. Every WebSocket connection asks the Mac to catch up, including after wake or a dropped connection. A file lock and a small pending-event file bridge foreground/background ownership; Contacts writes still use the existing single-writer lease and rollback journal.

## Timing and fallback

- Gmail notification starts an incremental check immediately (background bursts are coalesced for 200 ms), not after the next polling timer.
- The WebSocket uses 45-second protocol pings, a 15-second ping deadline, and reconnect backoff from 1 to 60 seconds.
- Socket liveness is recorded separately from the library lease on every valid frame and successful protocol ping. A known disconnect clears only its own connection record; a replaced connection cannot erase a newer heartbeat. Silent/stale heartbeats expire after 120 seconds. A registered watch without a live socket immediately uses the regular check policy, while its listener continues reconnecting.
- A healthy Push account gets a 15-minute safety check for delayed/dropped Gmail notifications. A failed or non-Push account retains regular checks, with 5-minute API error backoff.
- Apple Mail fallback retains approximately one-minute checks when enabled; it covers other accounts and unhealthy Gmail connections, not another address merely sharing `gmail.com`.
- Gmail watch renews **automatically daily**, and also when less than 48 hours remain. No weekly manual action is required. Failed renewals retry after 5 minutes and leave regular checks available.
- Device registration lasts 180 days and renews automatically with less than seven days left. Disconnect removes the local credentials and attempts to unregister this Mac, without stopping another Mac's mailbox watch.
- Sleep, logout and offline periods pause delivery. Push does not wake a powered-off Mac. On wake/reconnect, the Mac catches up from history; if Google expires that cursor it safely rebuilds the inbox without deleting senders.
- Google does not guarantee delivery of every notification or an exact latency. Local lookup, Contacts and network latency also affect when the avatar appears. Measure real new-mail → avatar latency separately from an initial watch notification.

## Privacy

Registration sends a Google ID token plus the account email to prove the mailbox belongs to the signing-in account. OAuth now requests `openid email` alongside the existing read-only `gmail.metadata` scope; an older grant may need one browser reauthorization. Gmail access and refresh tokens **never** go to the relay.

Google's notification envelope contains the account email and a history ID. The Worker receives it, HMACs the normalized email, and immediately forwards only the history hint. Durable storage contains the keyed account identifier (object name), device UUID, SHA-256 channel-token hash, registration/expiration timestamps. It stores no plaintext email, history, subject, body, address book or images. Expiry alarms remove stale device rows. There are at most ten devices per account and two handoff sockets per device. Observability/logging is disabled; deployment operators must not add request-payload logging. Cloudflare/Google still process network traffic and infrastructure metadata under their own policies. Pub/Sub may retain undelivered notification envelopes for up to the configured one hour.

The Mac keeps its opaque channel token in Keychain, the account registration, short-lived socket-presence timestamps and pending hints in its restricted local data directory. Disconnect revokes this device when the relay is reachable; offline revocation falls back to registration expiry. Google account revocation is also available from the Google Account connected-app settings.

## Deploy

Use the **same project as the desktop OAuth client**. Gmail rejects a topic whose project ID differs from the project making `watch`. Verify project number ↔ project ID with `gcloud projects describe`; the client identifier prefix only verifies the project number locally.

```sh
cd Push
npm ci
npm test
npm run deploy:dry
cd ..
# First complete gcloud auth login and Wrangler login.
export EMBLEM_GOOGLE_CLIENT_ID='YOUR_EXISTING_DESKTOP_CLIENT.apps.googleusercontent.com'
export EMBLEM_GOOGLE_PROJECT_NUMBER='YOUR_PROJECT_NUMBER'
# Optional: project ID, otherwise resolved from the project number.
bash Scripts/configure-gmail-push.sh
```

The script creates/reuses `emblem-gmail-events`, grants Gmail's publisher only on that topic, creates a keyless `emblem-pubsub-push` service account and grants Pub/Sub's service agent token creation only on that identity. Creating the subscription also requires the operator's `iam.serviceAccounts.actAs` permission. It deploys the relay, sets four Worker secrets without printing their values, and configures `emblem-gmail-push` with exact OIDC email and audience validation. An existing HMAC is preserved; rotation requires every device to reconnect.

`/health` is liveness only. `/ready` returns 503 until all deployment secrets exist; 200 readiness still does not prove Pub/Sub or a real mailbox watch works. All `/v1` endpoints return 503 while unconfigured. Registration is rate-limited and JWTs are verified using Google's RSA public keys, with bounded key fetching; no production test-token bypass exists.

Build after exporting the public values returned by the setup script:

```sh
EMBLEM_GMAIL_PUSH_ENDPOINT='https://push.emblem.protoyard.com' \
EMBLEM_GMAIL_PUBSUB_TOPIC='projects/YOUR_PROJECT_ID/topics/emblem-gmail-events' \
EMBLEM_GOOGLE_PROJECT_NUMBER='YOUR_PROJECT_NUMBER' \
EMBLEM_GOOGLE_CLIENT_ID='YOUR_EXISTING_DESKTOP_CLIENT.apps.googleusercontent.com' \
  bash Scripts/build-app.sh /absolute/isolated/build-directory
```

All four values are required together. Do not put tokens, client JSON or service-account keys in this repository, CI output, issues or evidence reports. Open Emblem Settings and reconnect the existing account once if needed. Keep the installed stable app and its data until acceptance completes.

## Acceptance before release

1. Run Swift tests, Worker RSA tests and real workerd integration tests, build, verify code signature, run isolated self-test and rollback.
2. Confirm deployed readiness, exact subscription topic/endpoint/OIDC identity/audience and topic publisher IAM.
3. Enable the mailbox watch from the correctly configured app; verify its saved expiry and persistent helper after Command-Q, not merely closing the window.
4. Receive a **real new email**: measure mail receipt → hint → Gmail cursor → sender/avatar → independent Contacts read-back. Do not publish private message/address data.
5. Repeat with foreground ownership, background-only ownership, reconnect, sleep/wake, missed hints, expired history, a Gmail API error and revoked channel. Check other Mail accounts retain their fallback cadence.
6. Sign/notarize/staple, install one bundle, verify login item points to that exact bundle, then publish a tagged release and update the privacy site.

Rollback a release using the preserved signed stable app and its verified backup. A client rollback leaves discovered rows and Contacts intact; journal-based undo is separate. To stop cloud delivery, delete only `emblem-gmail-push` and the named relay when no Macs need them. Do not broadly reset project IAM or rotate HMAC as a rollback shortcut.

Sources: [Gmail Push](https://developers.google.com/workspace/gmail/api/guides/push), [users.watch](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/watch), [authenticated Pub/Sub](https://docs.cloud.google.com/pubsub/docs/authenticate-push-subscriptions), [WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/).

## Outgoing-recipient acceptance

- Send to a new address and CC a second one; both appear once and resolve automatically when discovery/avatar/Contacts sync are enabled.
- Include your account/send-as address and a Bcc-only address; neither is enrolled by outgoing discovery.
- A sent recipient with a previous inbox receipt keeps that receipt time and list position. Existing manual choices and externally edited Contacts remain protected.
- A legacy Gmail account imports Sent with its own page token, preserving the saved history and inbox pagination. An archive failure uses a separate five-minute retry and incoming history continues. A new-mail hint cancels a slow Sent backfill request without advancing its page token or adding retry delay; one archive page is serviced per pass.
- Apple Mail uses its documented top-level Sent mailbox, not localized folder-name guesses. The first/daily sweep is resumable in 200-message pages; recent checks overlap five minutes and fall back to paging after a large catch-up. The local library is persisted before each outgoing cursor advances.
- Verify these on the configured installed bundle with real sent mail before marking the release complete; transport/fixture tests do not establish live-mail latency or Contacts acceptance.
