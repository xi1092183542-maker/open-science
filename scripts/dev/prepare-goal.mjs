// Run npm ci --ignore-scripts in goal-dependencies and plugin-runtime first.
import { build } from "esbuild";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = path.resolve(import.meta.dirname, "../..");
const source = path.join(import.meta.dirname, "goal-dependencies/node_modules/@prevalentware/opencode-goal-plugin");
const runtime = path.join(import.meta.dirname, "plugin-runtime");
const output = path.join(root, "runtime/goal-plugin");
await mkdir(output, { recursive: true });
const bundled = await build({
  entryPoints: [path.join(source, "dist/server.js")],
  bundle: true, format: "esm", platform: "node",
  external: ["@opencode-ai/plugin"],
  outfile: path.join(output, "goal-plugin.server.js"),
  metafile: true,
});
await cp(path.join(source, "LICENSE"), path.join(output, "LICENSE"));
await writeFile(path.join(output, "distribution-inputs.json"), JSON.stringify({
  schema: 1,
  modules: Object.keys(bundled.metafile.inputs).map(name => path.relative(root, path.resolve(name)).replaceAll("\\", "/")).sort(),
}, null, 2) + "\n");
// Preserve notices for packages whose code esbuild embeds in the single file.
const { existsSync, readdirSync } = await import("node:fs");
const seen = new Set();
const inventory = [];
for (const input of Object.keys(bundled.metafile.inputs)) {
  let folder = path.dirname(path.resolve(input));
  let meta;
  while (folder !== path.dirname(folder)) {
    if (existsSync(path.join(folder, "package.json"))) {
      meta = JSON.parse(await readFile(path.join(folder, "package.json"), "utf8"));
      if (meta.name) break;
    }
    folder = path.dirname(folder);
  }
  if (seen.has(folder) || !meta?.name) continue;
  seen.add(folder);
  const notices = readdirSync(folder).filter(name => /^(license|copying|notice)(\.|$)/i.test(name));
  const destination = path.join(output, "bundled-notices", `${meta.name.replaceAll("/", "_")}@${meta.version}`);
  await mkdir(destination, { recursive: true });
  for (const notice of notices) await cp(path.join(folder, notice), path.join(destination, notice), { recursive: true });
  inventory.push({ name: meta.name, version: meta.version, license: meta.license ?? "UNDECLARED", notices });
}
await writeFile(path.join(output, "bundled-notices.json"), JSON.stringify(inventory, null, 2) + "\n");
for (const item of ["node_modules", "package.json", "package-lock.json"]) {
  await cp(path.join(runtime, item), path.join(output, item), { recursive: true });
}
const goal = JSON.parse(await readFile(path.join(source, "package.json"), "utf8"));
const sdk = JSON.parse(await readFile(path.join(runtime, "node_modules/@opencode-ai/plugin/package.json"), "utf8"));
await writeFile(path.join(output, ".version"), goal.version + "\n");
await writeFile(path.join(output, ".opencode-plugin-version"), sdk.version + "\n");
// Resolve from the staged tree, so a missing deployment dependency fails here.
const probe = `
for (const name of ["@opencode-ai/plugin", "@opencode-ai/plugin/tool", "@opencode-ai/plugin/v2/effect", "@opencode-ai/plugin/v2/effect/integration", "@opencode-ai/plugin/v2/effect/plugin", "@opencode-ai/plugin/v2/promise"]) await import(name);
const {tool} = await import("@opencode-ai/plugin");
if (tool.schema.string().parse("ok") !== "ok") throw new Error("schema check failed");
`;
await writeFile(path.join(output, "verify-runtime.mjs"), probe);
await import(pathToFileURL(path.join(output, "verify-runtime.mjs")));
console.log(`Prepared goal plugin ${goal.version} and SDK ${sdk.version}, with locked dependencies and licenses.`);
