#!/usr/bin/env node
// Run build/sprint.wasm under Node's WASI:  node tools/wasm/run.js [--wasm FILE] [--] ARGS...   (e.g. run file.sp)
// WASI has no working directory: the host cwd is mounted as "/" (so relative paths such as build/out.png work like
// the native binary) and also at its own absolute path; the directory of every file argument and /tmp are mounted too.
"use strict";
const { WASI } = require("node:wasi");
const fs = require("node:fs");
const path = require("node:path");
let args = process.argv.slice(2), wasmFile = path.join(__dirname, "..", "..", "build", "sprint.wasm");
if (args[0] === "--wasm") { wasmFile = args[1]; args = args.slice(2); }
if (args[0] === "--") args = args.slice(1);
const cwd = process.cwd();
const preopens = { "/": cwd, [cwd]: cwd };
if (fs.existsSync("/tmp")) preopens["/tmp"] = "/tmp";
for (const a of args) {
  const f = a.replace(/^--allow-(?:read|write)=/, "");
  if (a.startsWith("-") && f === a) continue;
  const abs = path.resolve(f);
  if (!fs.existsSync(abs)) continue;
  const dir = fs.statSync(abs).isDirectory() ? abs : path.dirname(abs);
  if (!dir.startsWith(cwd + path.sep) && dir !== cwd && !dir.startsWith("/tmp")) preopens[dir] = dir;
}
const wasi = new WASI({ version: "preview1", args: ["sprint", ...args], env: process.env, preopens, returnOnExit: true });
(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(wasmFile));
  const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  process.exitCode = wasi.start(inst);
})();
