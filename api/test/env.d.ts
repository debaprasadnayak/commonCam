/// <reference types="@cloudflare/vitest-plugin/types" />
import type { D1Migration } from "cloudflare:test";
import type { Env } from "../src/index";

declare global {
  namespace Cloudflare {
    interface Env extends import("../src/index").Env {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
