/**
 * Generate Elm modules for all contracts in the Foundry output directory.
 *
 * Usage:
 *   bun codegen/generate-all.ts [--out-dir <foundry-out>] [--elm-dir <elm-src>]
 *
 * Defaults:
 *   --out-dir  ../pulsechain/out
 *   --elm-dir  ../pulsechain/app-elm/src/Generated
 */

import { readdirSync, statSync, existsSync } from "fs";
import { join, basename } from "path";
import { $ } from "bun";

const args = process.argv.slice(2);

function getArg(flag: string, defaultVal: string): string {
  const idx = args.indexOf(flag);
  if (idx !== -1 && args[idx + 1]) return args[idx + 1];
  return defaultVal;
}

const outDir = getArg("--out-dir", "../pulsechain/out");
const elmDir = getArg("--elm-dir", "../pulsechain/app-elm/src/Generated");

// Collect contract artifacts: each is out/<ContractName>.sol/<ContractName>.json
const solDirs = readdirSync(outDir).filter((name) => {
  const full = join(outDir, name);
  return name.endsWith(".sol") && statSync(full).isDirectory();
});

// Skip test contracts (*.t.sol), forge-std, openzeppelin internals
const skipPatterns = [".t.sol", "Test", "Script", "console", "Vm.sol"];

let generated = 0;

for (const solDir of solDirs) {
  // Skip test/infrastructure contracts
  if (skipPatterns.some((pat) => solDir.includes(pat))) continue;

  const contractName = solDir.replace(".sol", "");
  const jsonPath = join(outDir, solDir, `${contractName}.json`);

  if (!existsSync(jsonPath)) continue;

  const moduleName = `Generated.${contractName}`;
  const outputPath = join(elmDir, `${contractName}.elm`);

  try {
    await $`bun ${join(import.meta.dir, "generate.ts")} ${jsonPath} ${moduleName} ${outputPath}`;
    generated++;
  } catch (err) {
    console.error(`Failed to generate ${contractName}: ${err}`);
  }
}

console.log(`\nGenerated ${generated} Elm modules in ${elmDir}`);
