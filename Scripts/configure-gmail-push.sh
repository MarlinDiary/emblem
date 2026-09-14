#!/bin/bash
# Idempotent, narrowly scoped Gmail Pub/Sub setup. Requires an existing gcloud
# login and desktop OAuth client; never stores a private service-account key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${EMBLEM_GOOGLE_CLIENT_ID:?Set the existing public desktop OAuth client ID}"
: "${EMBLEM_GOOGLE_PROJECT_NUMBER:?Set its Google project number}"
PROJECT="${EMBLEM_GOOGLE_PROJECT_ID:-$(gcloud projects describe "$EMBLEM_GOOGLE_PROJECT_NUMBER" --format='value(projectId)')}"
NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
[[ "$NUMBER" == "$EMBLEM_GOOGLE_PROJECT_NUMBER" ]] || { echo 'OAuth/Cloud project mismatch.' >&2; exit 4; }
export EMBLEM_GMAIL_PUSH_ENDPOINT="${EMBLEM_GMAIL_PUSH_ENDPOINT:-https://push.emblem.protoyard.com}"
export EMBLEM_GMAIL_PUBSUB_TOPIC="projects/$PROJECT/topics/emblem-gmail-events"
python3 "$ROOT/Scripts/validate-push-config.py"
SA="emblem-pubsub-push@$PROJECT.iam.gserviceaccount.com"
ENDPOINT="$EMBLEM_GMAIL_PUSH_ENDPOINT/v1/google-push"
gcloud services enable pubsub.googleapis.com gmail.googleapis.com --project="$PROJECT"
gcloud beta services identity create --service=pubsub.googleapis.com --project="$PROJECT"
if ! gcloud pubsub topics describe emblem-gmail-events --project="$PROJECT" >/dev/null 2>&1; then
  gcloud pubsub topics create emblem-gmail-events --project="$PROJECT"
fi
gcloud pubsub topics add-iam-policy-binding emblem-gmail-events --project="$PROJECT" \
  --member='serviceAccount:gmail-api-push@system.gserviceaccount.com' --role=roles/pubsub.publisher >/dev/null
if ! gcloud iam service-accounts describe "$SA" --project="$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create emblem-pubsub-push --display-name='Emblem authenticated Gmail Push' --project="$PROJECT"
fi
# Grant on this one push identity, not on all service accounts in the project.
gcloud iam service-accounts add-iam-policy-binding "$SA" --project="$PROJECT" \
  --member="serviceAccount:service-$NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role=roles/iam.serviceAccountTokenCreator >/dev/null
cd "$ROOT/Push"
WRANGLER="${EMBLEM_WRANGLER:-$ROOT/Push/node_modules/.bin/wrangler}"
# An existing HMAC secret is preserved: rotating it would disconnect every Mac.
if ! "$WRANGLER" secret list | python3 -c 'import json,sys;sys.exit(0 if any(x["name"]=="HMAC_SECRET" for x in json.load(sys.stdin)) else 1)'; then
  openssl rand -hex 32 | "$WRANGLER" secret put HMAC_SECRET
fi
printf '%s' "$EMBLEM_GOOGLE_CLIENT_ID" | "$WRANGLER" secret put GOOGLE_CLIENT_ID
printf '%s' "$ENDPOINT" | "$WRANGLER" secret put PUBSUB_AUDIENCE
printf '%s' "$SA" | "$WRANGLER" secret put PUBSUB_SERVICE_ACCOUNT
"$WRANGLER" deploy
curl --fail --silent --show-error "$EMBLEM_GMAIL_PUSH_ENDPOINT/ready"
if gcloud pubsub subscriptions describe emblem-gmail-push --project="$PROJECT" >/dev/null 2>&1; then
  EXISTING_TOPIC="$(gcloud pubsub subscriptions describe emblem-gmail-push --project="$PROJECT" --format='value(topic)')"
  [[ "$EXISTING_TOPIC" == "$EMBLEM_GMAIL_PUBSUB_TOPIC" ]] || { echo 'Existing subscription has a different topic; inspect before updating.' >&2; exit 4; }
  gcloud pubsub subscriptions modify-push-config emblem-gmail-push --project="$PROJECT" \
    --push-endpoint="$ENDPOINT" --push-auth-service-account="$SA" --push-auth-token-audience="$ENDPOINT"
else
  gcloud pubsub subscriptions create emblem-gmail-push --project="$PROJECT" --topic=emblem-gmail-events \
    --push-endpoint="$ENDPOINT" --push-auth-service-account="$SA" --push-auth-token-audience="$ENDPOINT" \
    --ack-deadline=20 --message-retention-duration=1h --expiration-period=never
fi
# Exportable public configuration only. OAuth / channel / HMAC secrets are omitted.
printf '\nEMBLEM_GOOGLE_PROJECT_ID=%q\nEMBLEM_GOOGLE_PROJECT_NUMBER=%q\nEMBLEM_GMAIL_PUSH_ENDPOINT=%q\nEMBLEM_GMAIL_PUBSUB_TOPIC=%q\n' "$PROJECT" "$NUMBER" "$EMBLEM_GMAIL_PUSH_ENDPOINT" "$EMBLEM_GMAIL_PUBSUB_TOPIC"
echo 'GMAIL_PUSH_RESOURCES=CONFIGURED (mailbox watch and real delivery still need acceptance)'
