#!/usr/bin/env bun
/**
 * build-versions.ts -- render the version pills in docs-site/index.html from
 * the packages' own `elm.json` manifests, instead of by hand.
 *
 * The proofs page advertised "elm-web3 1.4.4 - elm-web3-ui 2.3.1" while the
 * published packages were 2.0.0 and 2.4.0. Nobody lied; the string was typed
 * once and then the packages moved. A page whose entire argument is "we show
 * you machine output, not claims" cannot carry a hand-typed version number.
 *
 * The page itself stays static and script-free (its footer promises exactly
 * that, and that promise is load-bearing) -- this runs at build time and
 * edits the committed HTML.
 *
 * USAGE
 *   bun run docs-site/build-versions.ts            # rewrite index.html
 *   bun run docs-site/build-versions.ts --check    # verify, never write
 *
 * SOURCES
 *   elm-web3      <repo>/elm.json
 *   elm-web3-ui   <repo>/../elm-web3-ui/elm.json, or $ELM_WEB3_UI_MANIFEST
 *
 * The UI manifest lives in a sibling repository, so a checkout of this repo
 * alone cannot see it. When it is absent this script says so and leaves the
 * committed value alone rather than guessing -- `--check` reports the ui
 * version as unverified and still passes, `--write` refuses to run.
 *
 * ANCHORS
 *   Each pill is `<span class="hero__version" data-pkg="NAME">X.Y.Z</span>`.
 *   `data-pkg` is the anchor; the markup around it is free to change.
 *
 * EXIT CODES
 *   0  written, or check passed
 *   1  check failed (a pill disagrees with its manifest), or a required
 *      manifest/anchor is missing
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const SITE_DIR = dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = dirname(SITE_DIR);
const INDEX_HTML = join(SITE_DIR, "index.html");

const SEMVER = /^\d+\.\d+\.\d+$/;

type Source = {
  readonly pkg: string;
  readonly manifest: string;
  /** Required manifests fail the build when missing; optional ones warn. */
  readonly required: boolean;
};

const SOURCES: readonly Source[] = [
  { pkg: "elm-web3", manifest: join(REPO_ROOT, "elm.json"), required: true },
  {
    pkg: "elm-web3-ui",
    manifest: process.env.ELM_WEB3_UI_MANIFEST ?? join(REPO_ROOT, "..", "elm-web3-ui", "elm.json"),
    required: false,
  },
];

function versionFrom(manifest: string): string | null {
  if (!existsSync(manifest)) return null;
  try {
    const parsed: unknown = JSON.parse(readFileSync(manifest, "utf8"));
    const version = (parsed as { version?: unknown }).version;
    if (typeof version !== "string" || !SEMVER.test(version)) return null;
    return version;
  } catch {
    return null;
  }
}

/** Replace the text inside the pill for `pkg`. Returns null if no such pill. */
function setPill(html: string, pkg: string, version: string): string | null {
  const pattern = new RegExp(
    `(<span class="hero__version" data-pkg="${pkg}">)([^<]*)(</span>)`,
  );
  if (!pattern.test(html)) return null;
  return html.replace(pattern, `$1${version}$3`);
}

function readPill(html: string, pkg: string): string | null {
  const m = html.match(new RegExp(`<span class="hero__version" data-pkg="${pkg}">([^<]*)</span>`));
  return m ? m[1] : null;
}

function main(): number {
  const check = process.argv.includes("--check");
  const original = readFileSync(INDEX_HTML, "utf8");
  let html = original;
  let failed = false;

  for (const source of SOURCES) {
    const version = versionFrom(source.manifest);

    if (version === null) {
      const where = source.manifest.replace(REPO_ROOT, ".");
      if (source.required) {
        console.error(`  FAIL ${source.pkg}: no usable version in ${where}`);
        failed = true;
      } else {
        console.log(
          `  skip ${source.pkg}: ${where} not available here -- version left as committed, NOT verified`,
        );
      }
      continue;
    }

    const current = readPill(html, source.pkg);
    if (current === null) {
      console.error(`  FAIL ${source.pkg}: no <span class="hero__version" data-pkg="${source.pkg}"> in index.html`);
      failed = true;
      continue;
    }

    if (current === version) {
      console.log(`  ok   ${source.pkg} ${version}`);
      continue;
    }

    if (check) {
      console.error(`  FAIL ${source.pkg}: page says ${current || "(empty)"}, manifest says ${version}`);
      failed = true;
      continue;
    }

    const next = setPill(html, source.pkg, version);
    if (next === null) {
      console.error(`  FAIL ${source.pkg}: pill anchor vanished mid-run`);
      failed = true;
      continue;
    }
    html = next;
    console.log(`  set  ${source.pkg} ${current || "(empty)"} -> ${version}`);
  }

  if (failed) {
    if (check) {
      console.error("\ndocs-site version pills disagree with the manifests. Re-render:");
      console.error("  bun run docs-site/build-versions.ts");
    }
    return 1;
  }

  if (!check && html !== original) writeFileSync(INDEX_HTML, html);
  return 0;
}

process.exit(main());
