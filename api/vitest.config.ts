import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { p8Key } from "./test/support/apnsKey";
import { createFakeAppStore, serialize } from "./test/support/fakeAppStore";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  // Locally generated stand-in for Apple's signing PKI; its root replaces Apple Root CA - G3.
  const appStore = await serialize(await createFakeAppStore());
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            MEDIA_SIGNING_KEY: "test-media-signing-key",
            TEST_APPLE_PKI: appStore,
            APPLE_ROOT_CA_G3: appStore.chain[2],
            // APNs is configured so push tests run the real sender; they stub `fetch` to api.sandbox.push.apple.com.
            APNS_KEY_ID: "TESTKEY",
            APNS_TEAM_ID: "TESTTEAM",
            APNS_PRIVATE_KEY: (await p8Key()).pem,
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
