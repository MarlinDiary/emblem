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

## Release gates still requiring their own evidence

- Google public verification and a genuinely clean Mac's OAuth onboarding.
- Full 72-hour natural background run, automatic daily Watch renewal, natural
  sleep/wake/offline/reboot events and sustained CPU/RSS thresholds. A monitor
  measures these without forcing the user's Mac to reboot or sleep.
- Real full-app Sparkle download/install/relaunch and login-agent read-back.
- Final installed version's real mail-to-hint/history and first-photo-to-Contacts
  measurements. Prior version's measurements must not be relabelled as current.

Stable promotion waits for the relevant release gates. Preview distribution can
publish completed implementation without asserting pending acceptance passed.
