# Emblem Push Relay

The relay turns authenticated Gmail/Google Cloud Pub/Sub notifications into an authenticated WebSocket hint for Emblem. It never receives Gmail OAuth access or refresh tokens, subjects, bodies, attachments, or contact data.

## Data boundary

- Registration proves the Gmail address with a Google OpenID Connect ID token.
- The relay immediately HMACs the normalized address. Durable Object names and stored device registrations contain no plaintext address.
- Each Mac creates a random channel token. The relay stores only its SHA-256 digest.
- Pub/Sub sends only `emailAddress` and `historyId`; neither is logged or persisted. The short-lived `historyId` hint is broadcast to a room and the app retrieves sender metadata directly from Gmail.
- Worker observability is disabled. Registrations expire automatically after 180 days and are renewed by Emblem.

## Required secrets

Set `HMAC_SECRET`, `GOOGLE_CLIENT_ID`, `PUBSUB_AUDIENCE`, and `PUBSUB_SERVICE_ACCOUNT` with `wrangler secret put`. Never commit `.dev.vars`.

## Verification

```sh
npm ci
npm test
npm run deploy:dry
```

See `../docs/gmail-push-operations.md` for Google Cloud and release configuration.
