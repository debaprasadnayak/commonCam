import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
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
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
