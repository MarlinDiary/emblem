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

## Build54 native icon

The portrait and ring now share one compound vector path and one foreground
material group. The glass disk is removed; the cutout exposes the background.
Icon Composer exported Default, Dark and Mono at 1024px for design generations
26 and 27; these and small-size/compatible output were reviewed. The resource
regression first failed on the previous three-layer source, then passed with
the same inputs after the change. `actool` produces native `Assets.car` image
stacks and a compatible ICNS. Runtime application sources are unchanged from
build53; prior mail timings are not relabelled as measurements of build54.

RC4 is a preview, not stable promotion. Exact signed archive, installation,
registered helper and runtime-matrix checks are recorded independently. Preserve
build53's complete observations before replacing the installed bundle; build54
has a separate natural observation cohort, not a continuation or reset of the
previous cohort's elapsed-time claim.

## Build55 approved warm-gray icon

RC5 adopts the user-approved four-vector native icon: head above a gray Multiply
lens, body below it, separate recess behind the body. The lower body arc shares
the lens geometry and the lens has no bright specular upper rim. Default/Dark/
Mono, generation26 fallback and small-size exports have their own review record.
Packaging preserves native materials; application Swift sources are unchanged.

Exact signed public archive, native resource layers, notarization, installation,
registered helper and isolated runtime matrix have independent verification
records. Build54 observations are preserved. Build55 starts a new natural
72-hour cohort; earlier cohorts and bounded tests are not relabelled as its
elapsed time. Stable0.19 feed stays unchanged while long-duration acceptance,
Google verification and clean-Mac account onboarding remain open.

## Build56 non-blocking Mail scan exit

The build55 cohort failed after about nine hours. The resident helper completed
its last Gmail check at 13:47 NZST on 16 September while holding the library
writer lease; maximum check age then grew to about 77,700s although push
availability, idle CPU and memory checks stayed green, and the foreground stayed
on Opening Your Library until the helper was restarted. All 14 cooperative
threads were waiting in `Process.waitUntilExit()` after their Mail scan workers
had exited.

Foundation lists launched tasks by unretained address on the launching thread.
A waiter on a reused Swift executor thread can match a recycled address and wait
for an exit notification queued on another thread's run loop. Mail scan workers
now report exit through the termination handler, with pipe I/O on GCD; timeout
and cancellation still kill only that child. The 150-scan regression first
failed on build55 sources at the 25-second deadline, then passed; an isolated
6,000-call probe had no stalls. Build56 is not a published preview; signing,
installation and any new natural cohort need their own records.

## Build57 Push ping, helper watchdog and acceptance checks

Build56's helper crashed at 12:45 NZST on 17 September, about 40 minutes into its
cohort. Build55 crashed the same way at 17:41 and 21:11 on 15 September and 04:30
on 16 September; launchd restarted each one and the build55 summary did not say
so. Three of the four reports were written within 17 seconds of wake. URLSession
delivered one ping's result twice as its connection failed, and resuming the
same continuation again trapped. The ping regression reproduced that trap before
the fix; the first report is now the only one used.

The helper now runs a GCD watchdog. Its heartbeat must pass through the utility
cooperative pool and the main actor; after 120 seconds without one while holding
the writer lease, or 600 seconds idle, the helper records `watchdog-restart` and
exits so flock releases the lease and launchd restarts it. Uptime excludes sleep.
Isolated fixtures stall the pool and the main thread, give an idle stall its
longer grace and keep a healthy helper running. Decoding an unchanged library
copy took about 0.1 seconds, far below the lease threshold.

Closed Apple Mail is no longer reported as missing automation permission. The
fixture Contacts worker no longer uses `waitUntilExit()`, and a source check
keeps that call out of app sources.

The monitor now fails on stale Gmail checks (45 minutes while online and expected,
after a 20-minute grace following sleep, reboot or reconnect), helper restarts
within one boot and Emblem crash reports in the window, recording report names
only. Replaying the build55 samples fails all three. Build57 is not a published
preview; its signing, installation and cohort need their own records.

## Build58 library writes, photo storage and idle work

Measured on the installed build57 with a 1,061-sender library: every pass rewrote the
91.7 MB `senders.json`, 37 times in 12 minutes, about 407 GB a day, while only two
rows had changed between consecutive rewrites; one pass rewrote it nine times in 32
seconds, once per three provisional monograms. Encoding was not the cost: 0.28 s at a
203 MB peak, against 0.31 s and 518 MB for the pre-build53 codec.

Photos are now stored once by content hash beside the library. That copy migrates to a
3 MB library plus 30 MB in 996 photo files: 65.7 MB of stored bytes deduplicate to
30.8 MB because senders of one organisation share artwork, and base64 is gone from
disk. It loads in 0.10 s and a bookkeeping save writes 3 MB in 0.070 s instead of
91.7 MB in 0.28 s, with every photo byte-identical after the round trip. The
pre-migration file is left untouched for rollback and removed seven days later; a photo
file that goes missing costs one candidate, not the library.

Bookkeeping saves are deferred 30 seconds and batched, while sync, quit and the end of
a background pass still flush immediately. Apple Mail fallback scans step from 60 s to
5 and 15 minutes while they keep examining nothing — the measured helper examined zero
messages every 60–75 s for days because its only account was already covered by the
Gmail API — and reset on real mail or a routing change; the helper's own wake interval
follows the same backoff. The Contacts enumeration is skipped while change history
reports nothing new. Reading that cursor moved off the main actor after it blocked a
discovery pass for about 40 seconds without Contacts access. The change journal is
written without pretty printing.

Build58 was signed with the Developer ID identity, not notarized, and installed over
build57 at 17:54 NZST on 27 September; the previous library was archived and the replaced
bundle kept. The live migration turned a 91.26 MB `senders.json`, left intact, into a
3.64 MB `senders-v2.json` beside 998 photo files of 30.9 MB: 1,062 rows, 998 references
with no missing or orphaned file, and 2,339 photo comparisons byte-identical.

Four windows were then measured on that installed build. Twelve minutes while the
foreground app finished its first pass: 35 library writes of 3.64 MB, 127.3 MB, no photo
file rewritten. Six minutes with the foreground app open and idle: no write at all.
Twelve minutes with the app closed, the condition of the 407 GB/day measurement: no pass
and no write, because the Apple Mail fallback had already backed off to 900 seconds.
Thirty minutes with the app closed, spanning four passes: 53 library writes, 196.6 MB,
about 9.4 GB a day, while the change journal recorded one Contacts write. No window
rewrote a photo file.

Build58 is not a published preview; its signing, installation and cohort need their own
records, and the write-volume claims above are single-machine measurements.

## Build59 deferred sync bookkeeping

Those 53 rewrites had one cause. Every finished lookup and every provisional monogram
kicks a sync pass, and the pass flushed the whole library whether or not it had written
anything to Contacts; with the app closed, rewrites landed two to four seconds apart for
a minute at a time. A pass now reports whether it completed a Contacts write. Only then
is the library flushed immediately; otherwise its bookkeeping joins the next deferred
save, which the end of a background pass, a sync error and quit still force. The
regression reproduces the measured shape — six bookkeeping-only passes after one applied
photo — and rewrote the library seven times before the change.

Build59 was signed with the same identity, again not notarized, and installed over
build58 at 19:31 NZST on 27 September after the same library archive; its bundle differs
from build58's only in bundle version and source revision, with an identical designated
requirement and entitlements. Its own thirty minutes with the app closed, the window that
measured 53 rewrites: one pass of 69 seconds, 3 library writes, 10.9 MB, no Contacts write
and no photo file rewritten, about 0.5 GB a day, or near 1 GB if every 15-minute wake ran
a full pass. A comparable build58 pass of 70 seconds wrote 23 times.

Build58's cohort was ended after 62 minutes and 63 samples when build59 replaced it:
Push healthy throughout, idle CPU median 0.0%, RSS 95th percentile 185 MB, no helper
restart, no crash report, longest Gmail check age 1,296 s. Those observations stay
build58's; build59 has its own natural cohort, and one 30-minute window is not a
multi-day measurement.

## Build60 icon palette

The approved four-vector icon keeps its geometry, layering, multiply lens and absent
specular, but its background, lens gradient and recess all sat in one narrow light band:
at 32 px the portrait dissolved into the dish. The background gradient is now a deeper
stone, 0.55/0.575/0.44 instead of 0.79/0.805/0.73; the lens runs #8A8A74 to #F7F7EF at
0.9 opacity instead of #B9B8A8 to #FFFFFA at 0.8, and the recess is #E4E4D6. Nothing was
added: no ring, no specular, no new vector, no changed path. Ring, stamp-edge, deeper
refraction and dark-ground alternatives were compiled and rejected; deeper refraction
alone only made the dish hazier, which is why the palette was the change. The resource
regression locks the new values as it locked the previous ones, and each candidate was
compared against the system's own composite, in light and dark appearance, at 512, 128,
64, 32 and 16 px.

Build60 was signed with the same identity, again not notarized, and installed over
build59 at 22:45 NZST on 27 September after the same library archive; its bundle differs
from build59's only in bundle version and source revision, with an identical designated
requirement and entitlements. The installed bundle's icon, rendered by the system's own
icon service, is byte-identical to the approved candidate. Application sources are
unchanged from build59, so build59's write measurements are not repeated here and are
not relabelled as build60's.

Build59's cohort was ended after 3 hours 11 minutes and 148 samples when build60 replaced
it: Push healthy in 0.993 of eligible samples, one sample stale by heartbeat while a
worker ran, idle CPU median 0.0% and 95th percentile 7.2%, RSS 95th percentile 215 MB,
no helper restart, no crash report, no stale Gmail check, longest check age 1,150 s.
Build60 starts its own 72-hour cohort.

## Build61 larger glyph

Beside Apple's own icons, rendered by the same icon service, Emblem's glyph read as too
small: its lens spanned 55% of the tile, Apple's Contacts circle about 63%, and Mail,
FaceTime and Music glyphs about 72-75%. All four vectors now scale by 1.28 about the
centre, so the lens spans 70%. Colours, layer order, refraction and the disabled
specular are unchanged, and the shoulders still end exactly on the lens circle. The
website's flat and 3D icons follow the same geometry. Application sources are unchanged
from build60.

Build61 was signed with the same identity, again not notarized, and installed over
build60 on 28 September after the same library archive; its bundle differs from
build60's only in bundle version and source revision, with an identical designated
requirement and entitlements, and the installed icon rendered by the system's own icon
service is byte-identical to the committed source. Build60's cohort ended after 63
minutes and 64 samples: Push healthy throughout, idle CPU median 0.0% and 95th
percentile 2.1%, RSS 95th percentile 167 MB, no helper restart, crash report or stale
Gmail check, longest check age 1,033 s. Build61 starts its own 72-hour cohort.
