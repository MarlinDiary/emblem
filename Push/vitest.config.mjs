import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: "./wrangler.jsonc" },
    miniflare: {
      bindings: {
        HMAC_SECRET: "fixture-hmac-secret-at-least-thirty-two-bytes",
        GOOGLE_CLIENT_ID: "fixture.apps.googleusercontent.com",
        PUBSUB_AUDIENCE: "https://push.emblem.protoyard.com/v1/google-push",
        PUBSUB_SERVICE_ACCOUNT: "fixture@example.iam.gserviceaccount.com",
      },
    },
  })],
  test: { include: ["test/worker.integration.test.mjs"] },
});
