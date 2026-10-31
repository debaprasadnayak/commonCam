import { defineConfig, mergeConfig } from "vitest/config";
import base from "./vitest.config";

export default defineConfig(async () =>
  mergeConfig(await base(), {
    test: {
      include: ["test/stress.audit.ts"],
      fileParallelism: false,
      maxWorkers: 1,
      testTimeout: 30_000,
    },
  }),
);
