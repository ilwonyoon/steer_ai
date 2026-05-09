import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        isolatedStorage: false,
        singleWorker: true,
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          compatibilityDate: "2024-10-01",
          compatibilityFlags: ["nodejs_compat"],
          d1Databases: ["DB"],
          durableObjects: { USER_HUB: "UserHub" },
          bindings: {
            APPLE_JWKS_URL: "https://appleid.apple.com/auth/keys",
            APPLE_AUDIENCES: "ai.steer.mac,ai.steer.ios",
            APPLE_ISSUER: "https://appleid.apple.com",
            SESSION_JWT_SECRET: "test-secret-do-not-use-in-prod-aaaaaaaaaaaaaaaaaaaaa",
          },
        },
      },
    },
  },
});
