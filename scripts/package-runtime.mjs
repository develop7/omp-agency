#!/usr/bin/env node
/**
 * Stage the minimal installable Agency plugin runtime and generate the
 * distribution catalog + Pages site.
 *
 * Modes:
 *   package-runtime.mjs --out <dir>
 *       Stage the runtime closure into <dir> (no catalog; this tree is what
 *       becomes the orphan distribution commit).
 *   package-runtime.mjs --out <dir> --verify [--no-stage]
 *       Verify a staged tree: manifest extension path exists, every relative
 *       import inside staged JS resolves inside the tree, and the Nickel
 *       runtime evaluates a `cli` workflow request against a staged state
 *       file. With --no-stage, verify the existing tree without re-staging.
 *   package-runtime.mjs --out <dir> --catalog <repo> <ref> <sha> <version> [--verify]
 *       Also emit .omp-plugin/marketplace.json (typed GitHub source pinned to
 *       the distribution tag + orphan distribution commit SHA, with an
 *       explicit per-plugin version) and the Pages site (index.html +
 *       marketplace.json) under marketplace/. The catalog step runs AFTER the
 *       distribution commit exists so sha is the real dist commit.
 */

import { readFile, writeFile, mkdir, stat, rm, cp } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const USAGE = `usage: package-runtime.mjs --out <dir> [--catalog <repo> <ref> <sha> <version>] [--verify]`;

// ── Runtime closure ──────────────────────────────────────────────────────────

const RUNTIME_FILES = [
  "src/agency-tools.ts",
  "src/workflow-vocabulary.ts",
  "pure/dist/agency-api.js",
  "nickel-vm/scripts/workflow-runtime.mjs",
  "nickel-vm/dist/nickel_vm.js",
  "nickel-vm/dist/nickel_vm_bg.wasm",
];

/** Directories copied recursively into the staged package. */
const RUNTIME_DIRS = ["skills", "agents"];

// ── Argv ─────────────────────────────────────────────────────────────────────

function parseArgv(argv) {
  const parsed = { out: undefined, catalog: null, verify: false, noStage: false };
  const rest = [...argv];
  while (rest.length > 0) {
    const flag = rest.shift();
    if (flag === "--out") {
      parsed.out = rest.shift();
      if (parsed.out === undefined) fail("--out requires a directory");
    } else if (flag === "--no-stage") {
      parsed.noStage = true;
    } else if (flag === "--catalog") {
      const repo = rest.shift();
      const ref = rest.shift();
      const sha = rest.shift();
      const version = rest.shift();
      if (repo === undefined || ref === undefined || sha === undefined || version === undefined) {
        fail("--catalog requires <repo> <ref> <sha> <version>");
      }
      if (!/^[A-Za-z0-9._/-]+\/[A-Za-z0-9._-]+$/.test(repo)) fail(`invalid catalog repo: ${repo}`);
      if (!/^[A-Za-z0-9._/-]+$/.test(ref)) fail(`invalid catalog ref: ${ref}`);
      if (!/^[0-9a-f]{4,64}$/.test(sha)) fail(`invalid catalog sha: ${sha}`);
      if (!/^[A-Za-z0-9._+-]+$/.test(version) || version.includes("..")) {
        fail(`invalid catalog version: ${version}`);
      }
      parsed.catalog = { repo, ref, sha, version };
    } else if (flag === "--verify") {
      parsed.verify = true;
    } else {
      fail(`unknown argument: ${flag}\n${USAGE}`);
    }
  }
  if (parsed.out === undefined) fail(`--out is required\n${USAGE}`);
  return parsed;
}

function fail(message) {
  process.stderr.write(`package-runtime: ${message}\n`);
  process.exit(1);
}

// ── Staging ──────────────────────────────────────────────────────────────────

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

/** Copy the source package.json verbatim; verifyManifest then proves the
 * source's own omp.extensions declaration against the staged tree. */
async function stageManifest(repoRoot, outDir) {
  await cp(join(repoRoot, "package.json"), join(outDir, "package.json"));
}

async function stage(repoRoot, outDir) {
  if (await exists(outDir)) {
    await rm(outDir, { recursive: true, force: true });
  }
  await mkdir(outDir, { recursive: true });
  await stageManifest(repoRoot, outDir);
  for (const file of RUNTIME_FILES) {
    const source = join(repoRoot, file);
    if (!(await exists(source))) fail(`missing runtime file in the build tree: ${file}`);
    const target = join(outDir, file);
    await mkdir(dirname(target), { recursive: true });
    await cp(source, target);
  }
  for (const dir of RUNTIME_DIRS) {
    const source = join(repoRoot, dir);
    if (!(await exists(source))) fail(`missing runtime directory in the build tree: ${dir}`);
    await cp(source, join(outDir, dir), { recursive: true });
  }
}

// ── Catalog + Pages site ─────────────────────────────────────────────────────

/** Split "owner/name" once; every catalog consumer reads the same derivation. */
function repoParts(repoName) {
  const [owner, name] = repoName.split("/");
  if (!owner || !name) fail(`cannot derive owner/name from repo "${repoName}"`);
  return { owner, name };
}

function catalogObject({ repo, ref, sha, version }, repoName) {
  const { owner, name } = repoParts(repoName);
  return {
    $schema: "https://anthropic.com/claude-code/marketplace.schema.json",
    name,
    owner: { name: owner },
    metadata: {
      description: "Near-autonomous workflow for coding agents — talk, do, and quality gates",
      version,
    },
    plugins: [
      {
        name: "agency",
        description:
          "Near-autonomous workflow: talk (design/exploration), do (implement → review → CI → ship), and structural quality gates (hickey, lowy, code-police).",
        version,
        source: { source: "github", repo, ref, sha },
        category: "development",
        license: "MIT",
      },
    ],
  };
}

function indexHtml({ repo, ref, sha, version }, repoName, pagesCatalogUrl) {
  const { name: marketplaceName } = repoParts(repoName);
  // OMP fetches HTTP(S) .json URLs directly as marketplace catalogs, so the
  // add command must point at the published catalog, not the git repo (a
  // owner/repo shorthand would clone main and bypass the distribution tag).
  const installCommand = `omp plugin marketplace add ${pagesCatalogUrl}`;
  const installFlag = `omp plugin install agency@${marketplaceName}`;
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>Agency — OMP plugin marketplace</title>
    <style>
      body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem; color: #1a1a2e; }
      code { background: #f2f2f5; padding: 0.15rem 0.4rem; border-radius: 4px; }
      pre { background: #f2f2f5; padding: 0.75rem 1rem; border-radius: 6px; overflow-x: auto; }
      dl dt { font-weight: 600; margin-top: 1rem; }
      dl dd { margin-left: 0; }
    </style>
  </head>
  <body>
    <h1>Agency</h1>
    <p>
      Near-autonomous workflow for coding agents on
      <a href="https://github.com/can1357/oh-my-pi">OMP (Oh My Pi)</a> — talk, do, hickey, lowy,
      code-police, fact-check, elegance, ralph, forge-pr.
    <h2>Install</h2>
    <pre>${installCommand}
${installFlag}</pre>
    <p>
      This page is a marketplace catalog: the raw catalog lives at
      <a href="./marketplace.json">./marketplace.json</a>. The pinned
      distribution build is
      <a href="https://github.com/${repo}/tree/${ref}">tag <code>${ref}</code></a>
      (commit <code>${sha}</code>), packaged for plugin version ${version}.
    </p>
    <h2>Local development</h2>
    <p>Source checkouts must run <code>just build nickel-build</code> before linking.</p>
  </body>
</html>
`;
}

async function generateCatalog(outDir, catalog, repoName) {
  const catalogJson = `${JSON.stringify(catalogObject(catalog, repoName), null, 2)}\n`;
  await mkdir(join(outDir, ".omp-plugin"), { recursive: true });
  await writeFile(join(outDir, ".omp-plugin", "marketplace.json"), catalogJson);
  const marketplaceDir = join(outDir, "marketplace");
  await mkdir(marketplaceDir, { recursive: true });
  await writeFile(join(marketplaceDir, "marketplace.json"), catalogJson);
  const { owner, name } = repoParts(repoName);
  const pagesCatalogUrl = `https://${owner}.github.io/${name}/marketplace.json`;
  await writeFile(join(marketplaceDir, "index.html"), indexHtml(catalog, repoName, pagesCatalogUrl));
}

// ── Verification ─────────────────────────────────────────────────────────────

const IMPORT_RE = /(?:^|[\s(])(?:import\s+[^'"]*?from\s+|import\s*\(\s*|require\s*\(\s*|export\s+[^'"]*?from\s+)['"](\.[^'"]+)['"]/g;

function collectFiles(files, dir, prefix = "") {
  return (async () => {
    const entries = await (await import("node:fs/promises")).readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const relativePath = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
      if (entry.isDirectory()) {
        await collectFiles(files, join(dir, entry.name), relativePath);
      } else {
        files.push(relativePath);
      }
    }
  })();
}

/** Verify every relative import in staged JS/TS resolves inside the staged tree. */
async function verifyImports(outDir) {
  const files = [];
  await collectFiles(files, outDir);
  const jsFiles = files.filter((file) => /\.(m?js|cjs|ts)$/.test(file) && !file.endsWith(".d.ts"));
  for (const file of jsFiles) {
    const content = await readFile(join(outDir, file), "utf8");
    for (const match of content.matchAll(IMPORT_RE)) {
      const specifier = match[1];
      if (!specifier.startsWith(".")) continue;
      const base = resolve(dirname(join(outDir, file)), specifier);
      if (!base.startsWith(resolve(outDir) + sep)) {
        fail(`staged file ${file} imports ${specifier} outside the runtime package`);
      }
      if (await exists(base)) continue;
      if (await exists(`${base}.js`)) continue;
      if (await exists(`${base}.mjs`)) continue;
      if (await exists(`${base}.cjs`)) continue;
      // TS sources keep Node-style ".js" specifiers pointing at ".ts" files.
      if (/\.(m|c)?js$/.test(base) && (await exists(base.replace(/\.js$/, ".ts")))) continue;
      if (await exists(join(base, "index.js"))) continue;
      if (await exists(join(base, "index.mjs"))) continue;
      fail(`staged file ${file} imports missing ${specifier} (resolved ${relative(outDir, base)})`);
    }
  }
  return jsFiles.length;
}

/** Verify the manifest's declared extension entry points exist. */
async function verifyManifest(outDir) {
  const manifest = JSON.parse(await readFile(join(outDir, "package.json"), "utf8"));
  const extensions = manifest.omp?.extensions;
  if (!Array.isArray(extensions) || extensions.length === 0) {
    fail("staged package.json declares no omp.extensions");
  }
  for (const extension of extensions) {
    if (!(await exists(join(outDir, extension)))) {
      fail(`staged package.json declares missing extension ${extension}`);
    }
  }
}

/** Evaluate a `cli` workflow request through the staged Nickel runtime. */
async function verifyNickel(outDir) {
  const statePath = join(outDir, ".do-results.json");
  const state = {
    vcs: "git",
    forge: "github",
    noVcs: true,
    minimal: false,
    review: false,
    base: "main",
    active: "sync",
    status: "running",
    steps: [{ name: "sync", status: "passed" }],
    from: "default",
    task: "runtime-package-verify",
  };
  await writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`);
  try {
    const runtimeUrl = pathToFileURL(join(outDir, "nickel-vm/scripts/workflow-runtime.mjs")).href;
    const runtime = await import(runtimeUrl);
    const result = await runtime.evaluateWorkflow({ operation: "cli", cwd: outDir });
    if (result.exit !== 0) {
      fail(`staged Nickel runtime evaluation failed (exit ${result.exit}): ${(result.stderr || result.stdout).slice(0, 300)}`);
    }
    if (!/step = /i.test(result.stdout)) {
      fail(`staged Nickel runtime produced unexpected output: ${result.stdout.slice(0, 200)}`);
    }
  } finally {
    await rm(statePath, { force: true });
  }
}

/** Verify the generated catalog is internally consistent with the staged tree. */
async function verifyCatalog(outDir, catalog) {
  const staged = JSON.parse(await readFile(join(outDir, ".omp-plugin", "marketplace.json"), "utf8"));
  const entry = staged.plugins[0];
  const problems = [];
  if (entry.source?.source !== "github") problems.push("source is not typed github");
  if (entry.source?.repo !== catalog.repo) problems.push(`source.repo != ${catalog.repo}`);
  if (entry.source?.ref !== catalog.ref) problems.push(`source.ref !== ${catalog.ref}`);
  if (entry.source?.sha !== catalog.sha) problems.push(`source.sha !== ${catalog.sha}`);
  if (typeof entry.version !== "string" || entry.version.length === 0) problems.push("entry version missing");
  if (entry.version !== catalog.version) problems.push("entry version mismatch");
  if (staged.plugins[0].source && typeof staged.plugins[0].source === "string") problems.push("relative source in distribution catalog");
  const pages = JSON.parse(await readFile(join(outDir, "marketplace", "marketplace.json"), "utf8"));
  const html = await readFile(join(outDir, "marketplace", "index.html"), "utf8");
  if (!html.includes('href="./marketplace.json"')) problems.push("index.html missing ./marketplace.json link");
  if (!html.includes("omp plugin marketplace add https://")) {
    problems.push("index.html add command must use the Pages catalog URL");
  }
  if (problems.length > 0) fail(`catalog inconsistency: ${problems.join("; ")}`);
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const argv = parseArgv(process.argv.slice(2));
  const repoRoot = resolve(import.meta.dirname, "..");
  const outDir = resolve(argv.out);
  if (!argv.noStage) {
    await stage(repoRoot, outDir);
  } else if (!(await exists(outDir))) {
    fail(`--no-stage requires an existing staged tree at ${outDir}`);
  }
  const repoName = await remoteRepo(repoRoot);
  if (!repoName) fail(`cannot determine GitHub repo identity from ${repoRoot}/.git/config`);
  if (argv.catalog) {
    await generateCatalog(outDir, argv.catalog, repoName);
  }
  if (argv.verify) {
    const extensionFiles = await verifyImports(outDir);
    await verifyManifest(outDir);
    await verifyNickel(outDir);
    if (argv.catalog) {
      await verifyCatalog(outDir, argv.catalog);
    }
    process.stdout.write(
      `package-runtime: staged ${repoName} runtime at ${outDir} — ${extensionFiles} import-bearing files verified` +
        `${argv.catalog ? ", catalog + pages site verified" : ""}\n`,
    );
  } else {
    process.stdout.write(`package-runtime: staged ${repoName} runtime at ${outDir}\n`);
  }
}

async function remoteRepo(repoRoot) {
  try {
    const config = await readFile(join(repoRoot, ".git", "config"), "utf8");
    const match = config.match(/url\s*=\s*.*github\.com[:/](.+?)(?:\.git)?\s*$/m);
    return match ? match[1] : null;
  } catch {
    // Missing/unreadable .git/config is expected outside a git checkout;
    // main() turns the null into a loud failure, so swallowing here is safe.
    return null;
  }
}

main().catch((error) => {
  process.stderr.write(`package-runtime: ${error instanceof Error ? error.stack : error}\n`);
  process.exit(1);
});