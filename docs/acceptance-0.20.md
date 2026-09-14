# 0.20 release acceptance

This is an evidence ledger, not a statement that every boundary has passed.
Private mailbox/contact records and credentials are intentionally excluded.

## Implemented and exercised locally

- Bounded provisional monograms before network lookup; unchanged app-owned
  monograms on both new and originally empty cards may upgrade.
- Existing personal photos, manual choices, external edits and ignored identities
  retain protection.
- Typed preservation during ignore; one edited card no longer aborts the rest
  of a batch, and feedback distinguishes kept original/edited cards from removal.
- General organization Person JSON-LD, scoped Schema.org microdata and h-card;
  exact email/full-name proof on the organization's registrable domain remains
  mandatory. Ambiguous/nested/different-person photos are rejected.
- Pinned offline first-party Google, LinkedIn, Raycast, Tesla and Cursor artwork;
  required dark/light selected-card border and circular-safe geometry tests.
- Native UI exports are enabled in CI. Remaining private corpus tests remain
  deliberately opt-in, not labelled as passing mandatory visual acceptance.
- Foreground-only Sparkle, signed feed/archive, explicit installation, async quit
  saving and updater/background-agent coordination.
- Universal packaging added. Cross-compilation alone does not prove Intel/macOS
  14 runtime compatibility: CI exercises the built package on 14, 15 and 26.

## Real integration findings

Build 46 was installed through the native signed Sparkle workflow (45 to 46),
with exact artifact hash, notarization and registered login-agent version read
back. An owned test mailbox notification arrived in about 2.8 seconds, but a
Contacts write/read-back occupied the helper's main actor for roughly a minute.
The full first-photo acceptance was not marked passing.

Automatic Contacts mutations now run in a headless child, using the same
write-ahead journal, identity/photo/history guards and explicit edit protection.
The UI and Push socket actor remain free. Launched writes are drained on caller
cancellation; ignore waits for the prior write before undoing it. Later manual
choices and new mail received during an IPC await retain their correct row IDs.
Fixture subprocess cancellation, identity conflict, same-card upgrade, protected
undo and late-selection regressions pass. Final source and installed-version results are recorded in the release verification artifact; earlier counts must not be relabelled as final acceptance.

The resident helper now runs as an accessory AppKit application: no Dock/window
at startup, and explicit user reopen launches or activates one foreground app.
Contacts IPC has its own prohibited-policy AppKit session, never SwiftUI/updater.
Public installed-app OAuth configuration is bundled without user credentials.

## Release gates still requiring their own evidence

- Google public verification and a genuinely clean Mac's OAuth onboarding.
- Full 72-hour natural background run, automatic daily Watch renewal, natural
  sleep/wake/offline/reboot events and sustained CPU/RSS thresholds. A monitor
  measures these without forcing the user's Mac to reboot or sleep.
- Full native Sparkle 45 → 46, exact archive and registered login-agent read-back **passed**. Final later-version replacement is recorded separately.
- Final installed version's real mail-to-hint/history and first-photo-to-Contacts
  measurements. Prior version's measurements must not be relabelled as current.

Stable promotion waits for the relevant release gates. Preview distribution can
publish completed implementation without asserting pending acceptance passed.

The source-built ad-hoc CI matrix is distinct from the downloadable signed
archive. The separate Signed release runtime workflow verifies the exact public
ZIP SHA256, Developer ID, stapled ticket and isolated execution on the OS matrix.
Neither cross-compilation nor a different SDK build substitutes for that gate.

## Final build52 sample (14 September 2026)

Compiled source: `ac15a3b02900b27003bafd5e980a447b9457bf9c`.
Main merge: `2fe764e4fd725610aab79552a6c908a0035e049d`.
[RC2](https://github.com/MarlinDiary/emblem/releases/tag/v0.20.0-rc.2)
archive SHA256: `32b3a9c85e8a61d9c64aa010ce2db351e39f16e3356802cd9db2d5bf255b48a7`.

- Source CI all green: unit/rendering, relay, source-built package14/15/15-intel/26/26-intel.
- Local Swift428 total:416 passing,12 private opt-in skips,zero failures; Operations11;relay9.
- Real own INBOX+SENT controlled recipient:Push1.807s,target history3.098s,
  applied Contacts journal4.637s,independent native Contacts photo readback5.372s.
  Foreground absent,same WebSocket,no safety poll due,no timed full-library reads.
  This validates an outgoing participant as well as the real notification path,
  not a universal latency guarantee or a separately controlled external sender.
- Same85.76MB utility-QoS serialization under launchd:Background5.401s versus
  app-style Interactive0.198s,both exit0;temporary services/copy removed.
  Resident sockets still sleep,finite activities allow idle system sleep,and
  image serialization stays off the UI actor. Interactive is a resource class,
  not an instruction to show windows or enter the Dock.
- Later Contacts history changes are conservatively kept during ignore;manual
  deletion of this workflow's temporary own cards was independently read back.

Exact public signed SDK27 ZIP runtime passed on macOS14,15,15-intel,26 and26-intel
([run34811072985](https://github.com/MarlinDiary/emblem/actions/runs/34811072985)).
Its exact hash, Developer ID and stapled ticket were independently verified,
followed by isolated worker launch, accessory startup and fixture undo on each OS.
Natural72h observations have a separate record and remain pending. Neither
real OAuth onboarding nor older-OS full GUI behavior is inferred from fixture CI.
The temporary Sparkle acceptance feed is removed after45→46 acceptance.

## Build53 bounded photo serialization

The on-disk sender JSON array stays unchanged. Encoding now scopes one row at a
time and reserves a bounded buffer, rather than building an entire Foundation
base64 encoder tree. Existing asynchronous durability/revision guards remain.
Same deterministic1000 independently allocated64000-byte payload rows:
debug reference peak437.19MiB versus bounded163.91MiB. An isolated unchanged
88,188,393-byte real library copy measured508.83MiB versus187.67MiB; all decoded
fields, photo bytes and order compared equal. No live Contacts/library writes
or account requests were made by these codec probes. Final signed release
measurements and runtime CI have separate records. A short codec benchmark does
not substitute for the fresh build53 natural72-hour resident cohort; the
original build52 observations and peaks are retained.

## Build 54 native progressive scroll tops

All scrolling surfaces share the system soft top scroll-edge style on macOS26+: sender list/detail, grouped Settings forms, source preview, Help, history, batch lists and the address popover. Photos are not blurred or covered by a custom overlay. Reduced transparency/increased contrast select the more legible system hard style; older systems retain their original appearance. Policy/source-surface/viewport regressions supplement native composited scrolling review; offscreen exports alone do not prove WindowServer blur. Prior build53 memory/mail and72-hour observations remain separately labelled, not final54 acceptance.
