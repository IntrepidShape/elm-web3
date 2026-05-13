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
// when their tooling supports declaration files. It's hand-maintained
// in lockstep with the .ts source; a future revision can switch to
// `tsc --declaration` once the TS is strict enough.

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
