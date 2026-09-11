// Bundle entry for the real omptype zod shim. esbuild aliases
// @oh-my-pi/omptype/zod to the pinned omptype derivation's src/zod.ts
// (see the build-plugin-test recipe in the justfile), so the plugin tests
// drive the same schema engine OMP injects as `pi.zod` — no node_modules.
export { z } from "@oh-my-pi/omptype/zod";