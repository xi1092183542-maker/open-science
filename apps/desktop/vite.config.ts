/// <reference types="vitest/config" />
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";
import path from "node:path";
import pkg from "./package.json";

const r = (p: string) => fileURLToPath(new URL(p, import.meta.url));

// Record actual module inputs, including fonts/assets. Installed dependency
// metadata alone cannot distinguish browser code from unused Node packages.
function distributionInputs(): Plugin {
  const root = r("../..");
  return {
    name: "distribution-inputs",
    apply: "build",
    generateBundle() {
      const modules = [...this.getModuleIds()]
        .filter((id) => !id.startsWith("\0") && path.isAbsolute(id.split("?")[0]))
        .map((id) => path.relative(root, id.split("?")[0]).split("\\").join("/"));
      this.emitFile({ type: "asset", fileName: "distribution-inputs.json",
        source: JSON.stringify({ schema: 1, modules: [...new Set(modules)].sort() }, null, 2) + "\n" });
    },
  };
}

export default defineConfig({
  plugins: [react(), distributionInputs()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
  },
  resolve: {
    alias: {
      "@": r("./src"),
      "@ai4s/shared": r("../../packages/shared/src/index.ts"),
      "@ai4s/sdk/mock-server": r("../../packages/sdk/src/mockServer.ts"),
      // Every ACP entry must precede the bare "@ai4s/sdk" prefix, which would
      // otherwise swallow them. `acp/stdio` (spawns an agent) and
      // `acp/serve-stdio` (IS the agent an editor spawns) are node-only;
      // nothing in the webview bundle may import either.
      "@ai4s/sdk/acp/serve-stdio": r("../../packages/sdk/src/acp/serve-stdio.ts"),
      "@ai4s/sdk/acp/stdio": r("../../packages/sdk/src/acp/stdio.ts"),
      "@ai4s/sdk/acp": r("../../packages/sdk/src/acp/index.ts"),
      "@ai4s/sdk": r("../../packages/sdk/src/index.ts"),
    },
  },
  test: {
    globals: true,
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    css: false,
    // `--expose-gc` so a test can prove a retained string was actually released
    // rather than asserting the shape of the code that releases it. Only the
    // computer-use serve channel needs it today; it costs nothing elsewhere.
    execArgv: ["--expose-gc"],
  },
});
