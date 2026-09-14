# Software updates

Emblem uses Sparkle 2.10.0 only in a ready, visible packaged application. Mail
workers, the login agent, diagnostics, demo and isolated data-directory sessions
never start it. System profiling is disabled. Automatic **checks** are controlled
in Settings; download/installation remains an explicit choice in native update UI.

The HTTPS appcast and archives require Ed25519 signatures. Update verification
runs before extraction. The private update-signing key stays in the maintainer's
Keychain; only the public key is shipped. The archive also contains Developer ID
signed nested updater code and an Apple-notarized/stapled app. HTTPS, Ed25519 and
Developer ID are complementary checks, not interchangeable.

During installation Emblem drains/cancels in-flight work, awaits durable library
saving and unregisters its old login agent without changing the background
preference. Relaunch re-registers the new installed build. A failed save cancels
termination instead of yielding an unsaved writer lease.

## Maintainer publication

Use the official pinned Sparkle tools with the existing Keychain account, never
export the private key into this repository or CI logs:

```sh
bin/generate_appcast --account com.protoyard.emblem \
  --download-url-prefix https://github.com/MarlinDiary/emblem/releases/download/TAG/ \
  /absolute/release-directory
bin/sign_update --account com.protoyard.emblem --verify /absolute/release-directory/appcast.xml
```

Generate/sign after all archive bytes, release notes and feed fields are final.
Any later feed edit invalidates its signature. Publish only matching artifacts
and verify the served feed and downloaded archive, including a tampered-input
negative test. Keep prerelease acceptance separate from stable promotion.

Source: [Sparkle documentation](https://sparkle-project.org/documentation/).

The 45-to-46 transition was exercised through the full native update UI, not
a standalone updater harness. Installed bytes, notarization and registered
background agent 46 matched, with account and background preferences retained.
