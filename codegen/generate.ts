/**
 * ABI-to-Elm code generator
 *
 * Reads a Foundry-compiled ABI JSON file and generates a type-safe Elm module
 * with encoders, decoders, type aliases for functions and events.
 *
 * Usage:
 *   bun codegen/generate.ts <abi-json-path> <ModuleName> <output-path>
 *
 * Example:
 *   bun codegen/generate.ts ../pulsechain/out/MyCurve.sol/MyCurve.json Generated.MyCurve ./test-output/Generated/MyCurve.elm
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { dirname } from "path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface AbiParam {
  name: string;
  type: string;
  indexed?: boolean;
  components?: AbiParam[];
  internalType?: string;
}

interface AbiItem {
  type: "function" | "event" | "constructor" | "fallback" | "receive" | "error";
  name?: string;
  inputs?: AbiParam[];
  outputs?: AbiParam[];
  stateMutability?: "pure" | "view" | "nonpayable" | "payable";
  anonymous?: boolean;
}

// ---------------------------------------------------------------------------
// Solidity type -> Elm type mapping
// ---------------------------------------------------------------------------

interface ElmType {
  elmType: string;
  encoder: string;
  decoder: string;
}

function solidityToElm(solType: string, components?: AbiParam[]): ElmType {
  // Dynamic arrays: T[]
  if (solType.endsWith("[]")) {
    const inner = solidityToElm(solType.slice(0, -2), components);
    const wrappedType = inner.elmType.includes(" ") ? `(${inner.elmType})` : inner.elmType;
    return {
      elmType: `(List ${wrappedType})`,
      encoder: `(E.list (\\item -> ${inner.encoder} item))`,
      decoder: `(D.list ${inner.decoder})`,
    };
  }

  // Fixed-size arrays: T[N]
  const fixedArrayMatch = solType.match(/^(.+)\[(\d+)\]$/);
  if (fixedArrayMatch) {
    const inner = solidityToElm(fixedArrayMatch[1], components);
    const wrappedType = inner.elmType.includes(" ") ? `(${inner.elmType})` : inner.elmType;
    return {
      elmType: `(List ${wrappedType})`,
      encoder: `(E.list (\\item -> ${inner.encoder} item))`,
      decoder: `(D.list ${inner.decoder})`,
    };
  }

  // Tuples (placeholder -- handled specially at call sites)
  if (solType === "tuple" && components) {
    return {
      elmType: "TupleRecord",
      encoder: "E.object",
      decoder: "D.succeed",
    };
  }

  if (solType === "bool") {
    return { elmType: "Bool", encoder: "E.bool", decoder: "D.bool" };
  }

  // All numeric types, address, string, bytes -> String
  if (
    solType.startsWith("uint") ||
    solType.startsWith("int") ||
    solType === "address" ||
    solType === "string" ||
    solType === "bytes" ||
    /^bytes\d+$/.test(solType)
  ) {
    return { elmType: "String", encoder: "E.string", decoder: "D.string" };
  }

  // Default fallback
  return { elmType: "String", encoder: "E.string", decoder: "D.string" };
}

// ---------------------------------------------------------------------------
// Name helpers
// ---------------------------------------------------------------------------

function toPascalCase(name: string): string {
  if (!name) return "";
  return name.charAt(0).toUpperCase() + name.slice(1);
}

function toCamelCase(name: string): string {
  if (!name) return "";
  return name.charAt(0).toLowerCase() + name.slice(1);
}

function functionSignature(name: string, inputs: AbiParam[]): string {
  const paramTypes = inputs.map(solidityParamType).join(",");
  return `${name}(${paramTypes})`;
}

function solidityParamType(param: AbiParam): string {
  if (param.type === "tuple" && param.components) {
    return `(${param.components.map(solidityParamType).join(",")})`;
  }
  if (param.type.startsWith("tuple") && param.type.endsWith("[]") && param.components) {
    return `(${param.components.map(solidityParamType).join(",")})[]`;
  }
  return param.type;
}

function ensureParamName(param: AbiParam, index: number): string {
  if (param.name && param.name.length > 0) {
    return toCamelCase(param.name);
  }
  return `arg${index}`;
}

// ---------------------------------------------------------------------------
// Elm code generation -- functions
// ---------------------------------------------------------------------------

function generateFunction(
  fn: AbiItem,
  _elmFnName: string,
  elmTypeName: string
): string {
  const lines: string[] = [];
  const inputs = fn.inputs || [];
  const outputs = fn.outputs || [];
  const mutability = fn.stateMutability || "nonpayable";
  const isPayable = mutability === "payable";
  const isView = mutability === "view" || mutability === "pure";

  const mutabilityLabel = isPayable ? "payable" : isView ? "view" : "nonpayable";
  lines.push(`-- FUNCTION: ${fn.name} (${mutabilityLabel})`);
  lines.push("");

  const sig = functionSignature(fn.name!, inputs);

  // Build all param fields, adding `value` for payable functions
  const allParamFields: { name: string; elmType: string; solType: string }[] = [];
  for (let i = 0; i < inputs.length; i++) {
    const p = inputs[i];
    const name = ensureParamName(p, i);
    const elmT = solidityToElm(p.type, p.components);
    allParamFields.push({ name, elmType: elmT.elmType, solType: p.type });
  }
  if (isPayable) {
    allParamFields.push({ name: "value", elmType: "String", solType: "wei amount" });
  }

  const hasParams = allParamFields.length > 0;

  // --- Params type alias ---
  if (hasParams) {
    lines.push(`type alias ${elmTypeName}Params =`);
    const fieldLines = allParamFields.map(
      (f) => `${f.name} : ${f.elmType}  -- ${f.solType}`
    );
    lines.push(`    { ${fieldLines.join("\n    , ")}`);
    lines.push(`    }`);
    lines.push("");
  }

  // --- Encoder ---
  if (hasParams) {
    lines.push(`encode${elmTypeName} : ${elmTypeName}Params -> E.Value`);
    lines.push(`encode${elmTypeName} params =`);
  } else {
    lines.push(`encode${elmTypeName} : E.Value`);
    lines.push(`encode${elmTypeName} =`);
  }

  lines.push(`    E.object`);

  const encodeEntries: string[] = [];
  encodeEntries.push(`( "method", E.string "${sig}" )`);

  if (inputs.length > 0) {
    const argParts = inputs.map((p, i) => {
      const name = ensureParamName(p, i);
      const elmT = solidityToElm(p.type, p.components);
      return `${elmT.encoder} params.${name}`;
    });
    encodeEntries.push(
      `( "args", E.list identity\n            [ ${argParts.join("\n            , ")}\n            ]\n          )`
    );
  } else {
    encodeEntries.push(`( "args", E.list identity [] )`);
  }

  if (isPayable) {
    encodeEntries.push(`( "value", E.string params.value )`);
  }

  lines.push(`        [ ${encodeEntries.join("\n        , ")}`);
  lines.push(`        ]`);
  lines.push("");

  // --- Return decoder ---
  if (outputs.length === 0) {
    lines.push(`decode${elmTypeName}Return : D.Decoder ()`);
    lines.push(`decode${elmTypeName}Return =`);
    lines.push(`    D.succeed ()`);
  } else if (outputs.length === 1) {
    const out = outputs[0];
    const elmT = solidityToElm(out.type, out.components);
    lines.push(`decode${elmTypeName}Return : D.Decoder ${elmT.elmType}`);
    lines.push(`decode${elmTypeName}Return =`);
    lines.push(`    D.index 0 ${elmT.decoder}`);
  } else {
    const returnTypeName = `${elmTypeName}Return`;
    lines.push(`type alias ${returnTypeName} =`);
    const retFields = outputs.map((p, i) => {
      const name = ensureParamName(p, i);
      const elmT = solidityToElm(p.type, p.components);
      return `${name} : ${elmT.elmType}`;
    });
    lines.push(`    { ${retFields.join("\n    , ")}`);
    lines.push(`    }`);
    lines.push("");

    const mapFn = outputs.length <= 8 ? `D.map${outputs.length}` : "D.map8";
    lines.push(`decode${elmTypeName}Return : D.Decoder ${returnTypeName}`);
    lines.push(`decode${elmTypeName}Return =`);
    lines.push(`    ${mapFn} ${returnTypeName}`);
    outputs.forEach((p, i) => {
      const elmT = solidityToElm(p.type, p.components);
      lines.push(`        (D.index ${i} ${elmT.decoder})`);
    });
  }

  lines.push("");
  lines.push("");
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Elm code generation -- events
// ---------------------------------------------------------------------------

function generateEvent(ev: AbiItem): string {
  const lines: string[] = [];
  const inputs = ev.inputs || [];
  const eventName = toPascalCase(ev.name!);

  lines.push(`-- EVENT: ${ev.name}`);
  lines.push("");

  // Type alias
  lines.push(`type alias ${eventName}Event =`);
  const fields = inputs.map((p, i) => {
    const name = ensureParamName(p, i);
    const elmT = solidityToElm(p.type, p.components);
    const indexedComment = p.indexed ? " (indexed)" : "";
    return `${name} : ${elmT.elmType}  -- ${p.type}${indexedComment}`;
  });
  lines.push(`    { ${fields.join("\n    , ")}`);
  lines.push(`    }`);
  lines.push("");

  // Decoder
  lines.push(`decode${eventName}Event : D.Decoder ${eventName}Event`);
  lines.push(`decode${eventName}Event =`);

  if (inputs.length === 0) {
    lines.push(`    D.succeed ${eventName}Event`);
  } else if (inputs.length <= 8) {
    // Elm has D.map (1 field), D.map2..D.map8
    const mapFn = inputs.length === 1 ? "D.map" : `D.map${inputs.length}`;
    lines.push(`    ${mapFn} ${eventName}Event`);
    inputs.forEach((p, _i) => {
      const name = ensureParamName(p, _i);
      const elmT = solidityToElm(p.type, p.components);
      lines.push(`        (D.field "${name}" ${elmT.decoder})`);
    });
  } else {
    // More than 8 fields: use andThen pipeline (rare for events)
    lines.push(`    D.map8 ${eventName}Event`);
    inputs.slice(0, 8).forEach((p, _i) => {
      const name = ensureParamName(p, _i);
      const elmT = solidityToElm(p.type, p.components);
      lines.push(`        (D.field "${name}" ${elmT.decoder})`);
    });
  }

  lines.push("");
  lines.push("");
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Module generator
// ---------------------------------------------------------------------------

function generateModuleElm(moduleName: string, abi: AbiItem[]): string {
  const lines: string[] = [];

  lines.push(`module ${moduleName} exposing (..)`);
  lines.push("");
  lines.push("import Json.Decode as D");
  lines.push("import Json.Encode as E");
  lines.push("");
  lines.push("");

  // Filter to functions and events only (skip constructor, fallback, receive, error)
  const functions = abi.filter((item) => item.type === "function" && item.name);
  const events = abi.filter((item) => item.type === "event" && item.name);

  // Detect overloaded function names for disambiguation
  const nameCounts = new Map<string, number>();
  for (const fn of functions) {
    nameCounts.set(fn.name!, (nameCounts.get(fn.name!) || 0) + 1);
  }

  const nameSeenCount = new Map<string, number>();

  for (const fn of functions) {
    const isOverloaded = (nameCounts.get(fn.name!) || 0) > 1;
    let elmFnName = toCamelCase(fn.name!);
    let elmTypeName = toPascalCase(fn.name!);

    if (isOverloaded) {
      const seen = (nameSeenCount.get(fn.name!) || 0) + 1;
      nameSeenCount.set(fn.name!, seen);
      if (seen > 1) {
        // Disambiguate by appending parameter type names
        const suffix = (fn.inputs || [])
          .map((p) => toPascalCase(p.type.replace(/\d+/g, "").replace("[]", "Array")))
          .join("_");
        elmFnName = `${elmFnName}_${suffix || seen.toString()}`;
        elmTypeName = `${elmTypeName}_${suffix || seen.toString()}`;
      }
    }

    lines.push(generateFunction(fn, elmFnName, elmTypeName));
  }

  for (const ev of events) {
    lines.push(generateEvent(ev));
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

const abiPath = process.argv[2];
const moduleName = process.argv[3];
const outputPath = process.argv[4];

if (!abiPath || !moduleName || !outputPath) {
  console.error(
    "Usage: bun codegen/generate.ts <abi-json-path> <ModuleName> <output-path>"
  );
  console.error(
    "Example: bun codegen/generate.ts ../pulsechain/out/MyCurve.sol/MyCurve.json Generated.MyCurve ./test-output/Generated/MyCurve.elm"
  );
  process.exit(1);
}

const artifact = JSON.parse(readFileSync(abiPath, "utf8"));
const abi: AbiItem[] = artifact.abi;

const elm = generateModuleElm(moduleName, abi);

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, elm);

const fnCount = abi.filter((a) => a.type === "function").length;
const evCount = abi.filter((a) => a.type === "event").length;
console.log(`Generated ${outputPath} (${fnCount} functions, ${evCount} events)`);
