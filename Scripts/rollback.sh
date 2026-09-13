#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "--fixture" && $# == 2 ]]; then
  BIN="${MAILPORTRAIT_BINARY:-$ROOT/build/MailPortrait.app/Contents/MacOS/MailPortrait}"
  [[ -x "$BIN" ]] || { echo 'Set MAILPORTRAIT_BINARY to the built executable.' >&2; exit 2; }
  exec "$BIN" --rollback-fixture --data-dir "$2"
fi
cat <<'TEXT'
MailPortrait rollback

Real contacts:
  Open MailPortrait, choose Changes, and select the relevant entry.
  Existing contact: Restore Previous Photo (keeps the contact and other fields).
  App-created contact: Delete Contact Created by MailPortrait (requires confirmation and unchanged history).
  If there were subsequent external edits, inspect and delete in Apple Contacts instead.
  iCloud deletion synchronizes to other devices. Removing a sender from the app list is NOT contact deletion.
  Keep the local changes.json journal until all desired rollbacks are completed.

Isolated automated fixture (never calls Apple Contacts):
  MAILPORTRAIT_BINARY=/absolute/path/to/MailPortrait ./Scripts/rollback.sh --fixture /absolute/fixture/path

Uninstall only after reviewing contact changes. Deleting the app alone does not undo contact changes.
TEXT
