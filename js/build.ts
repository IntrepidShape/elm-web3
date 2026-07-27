// build.ts — codegen the JS fallback artifact from the TypeScript source.
//
// The package ships `elm-web3-ports.ts` as the canonical, type-checked
// source. Consumers WITHOUT a TS toolchain can grab the pre-built
// `elm-web3-ports.js` produced by this script. Run on every release:
//
//   bun js/build.ts
//
// Output:
//   elm-web3-ports.js  — minified ESM bundle for the browser
//
// The .d.ts file is co-published so JS consumers still get type info
// when their tooling supports declaration files. It stays hand-written,
// deliberately: `tsc --declaration` can only emit what the implementation
// asserts about itself, and there the sub channel is one open record
// (`Web3Sub = { tag: string; [k: string]: unknown }`), so generating would
// replace 40 typed reply payloads with `unknown` -- a worse contract than
// the drifted one it replaced. Drift is handled by detection instead:
// `scripts/check-port-parity.ts` fails CI when the .d.ts tag sets and the
// implementation disagree.
//
// Freshness of THIS artifact is enforced the same way: CI runs this script
// and then `git diff --exit-code js/elm-web3-ports.js`.

const dir = import.meta.dir;

const built = await Bun.build({
  entrypoints: [`${dir}/elm-web3-ports.ts`],
  outdir:      dir,
  target:      "browser",
  minify:      true,
  naming:      "[dir]/[name].js",
});

if (!built.success) {
  for (const log of built.logs) console.error(log);
  throw new Error("elm-web3-ports.ts build failed");
}

console.log(`✓ ${dir}/elm-web3-ports.js  (${(await Bun.file(`${dir}/elm-web3-ports.js`).size / 1024).toFixed(1)} KB)`);
