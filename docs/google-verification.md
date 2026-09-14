# Google OAuth public verification

Status: public verification is not yet confirmed. A deployed relay and an
existing authorized account are not evidence of approval for new public users.

## Branding and public destinations

- App name: Emblem (legacy OAuth branding may still say MailPortrait)
- Homepage: https://emblem.protoyard.com/
- Privacy: https://emblem.protoyard.com/privacy/
- Terms: https://emblem.protoyard.com/terms/
- Authorized domain: protoyard.com
- OAuth application type: External, Desktop

Verify the domain and the actual project branding in Google Auth Platform.
Do not create another project/client to work around pending verification.

## Requested scopes and justification

| Scope | Why needed | Data boundaries |
| --- | --- | --- |
| `openid` | Validate the signed identity token during relay registration | Token validated, not retained as mailbox authorization |
| `email` | Bind the verified signed-in email to its notification channel | No Contacts upload |
| `gmail.metadata` | Read From/To/Cc and dates from inbox/sent, and incremental history; create/renew mailbox watch | No subjects, bodies, attachments, sending, modification or deletion |

`gmail.metadata` is restricted. Google decides whether this architecture requires
additional security assessment. Do not claim a waiver simply because the native
client keeps Gmail access/refresh tokens local. Pub/Sub notifications include
an account address and history hint before the relay derives its keyed account
identifier. Explain this transfer accurately in the verification application.

## Architecture to disclose

1. Desktop OAuth uses AppAuth, state and PKCE, with a random loopback port.
2. Client configuration and account authorization remain in macOS Keychain.
3. The Mac queries Gmail directly; Gmail tokens and mailbox contents do not go
   to Emblem's relay.
4. Google publishes email/history hints to the configured Pub/Sub topic.
5. Pub/Sub Push is authenticated with a keyless service identity and exact
   audience validation. The relay forwards hints over an authenticated WebSocket.
6. Relay storage contains keyed account routing and expiring device credentials.
   There is no hosted address book, mail-body database, advertising or telemetry.
7. Automatic Contacts changes and background operation are user-controlled;
   personal photos and external edits are protected. Disconnect stops this Mac's
   account checks; Google Account offers independent access revocation.

## Demonstration evidence required for submission

Record a dedicated test account only. Show the app/domain branding, OAuth
consent screen and every requested scope; sign-in; inbox and sent participant
discovery; photo selection; automatic Contacts insertion; preferences; disconnect
and Google access revocation. Use an unlisted demonstration video accepted by
Google. Do not include authorization codes, Keychain contents, private messages
or real personal contact lists in the recording.

A screenshot of "Authorization complete" proves only a loopback callback, not
successful token exchange, watch registration or public verification.

## Fresh-user limitation found and corrected

A token endpoint probe with the public desktop client ID and an intentionally
invalid fixture code returned HTTP 400, `client_secret is missing.` The app now
requests the full Desktop client JSON **before** starting sign-in when its
Keychain configuration is incomplete. It does not bundle or publish the secret.
Source builders must use their own project's full Desktop configuration. This
preflight improvement is not a completed fresh-Mac public onboarding test.

Sources: [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes),
[restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification),
[desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app).
