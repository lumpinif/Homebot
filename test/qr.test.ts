import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { encodeQr, rsRemainder, formatBits, MAX_VERSION } from "../src/core/qr.ts";
import { must } from "../test-helpers/must.ts";

const canDecode = process.platform === "darwin" && existsSync("/usr/bin/swift");

test("qr: Apple's detector decodes our symbols, versions 1-10 (macOS + Swift only)", { skip: !canDecode && "needs macOS Swift", timeout: 120_000 }, async (t) => {
  const inputs = [
    "x",
    "http://felix-mac.local:8787/dl/AbCdEfGhIjKlMnOpQrStUv",
    "http://192.168.1.5:8787/dl/" + "Z".repeat(22),
    "homebot 你好 http://mac.local:8787/",
    // One length per version (level M byte capacities 14/26/42/62/84/106/122/150/180/213).
    ...[10, 20, 30, 50, 70, 100, 110, 140, 170, 213].map((n) => "h".repeat(n - 4) + `${n}`.padStart(4, "-")),
  ];
  const versions = new Set(inputs.map((s) => encodeQr(s).version));
  assert.equal(versions.size, MAX_VERSION, `covers every version 1-${MAX_VERSION}`);
  const file = join(await mkdtemp(join(tmpdir(), "homebot-test-")), "symbols.txt");
  await writeFile(file, inputs.map((s) => encodeQr(s).modules.map((r) => r.map((d) => (d ? 1 : 0)).join("")).join("\n")).join("\n\n") + "\n");
  let stdout: string;
  try {
    ({ stdout } = await promisify(execFile)("swift", ["scripts/qr-verify.swift", file], { timeout: 110_000 }));
  } catch (e) {
    // e.g. a sandbox that can't write Swift's module cache: no decoder, so no verdict either way.
    return t.skip(`Swift could not run the decoder: ${e instanceof Error ? String(("stderr" in e ? e.stderr : undefined) ?? e.message) : String(e).split("\n")[0]}`);
  }
  const [control, ...decoded] = stdout.trimEnd().split("\n");
  // M4 review N3: an Apple-generated symbol must decode first; otherwise the decoder itself is
  // unavailable here and our symbols are neither passed nor failed.
  if (control !== "CONTROL ok") return t.skip("Apple's detector can't decode even its own QR code in this environment");
  assert.deepEqual(decoded, inputs);
});

test("qr: Reed-Solomon matches the published HELLO WORLD 1-M example", () => {
  const data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17];
  assert.deepEqual(rsRemainder(data, 10), [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]);
});

test("qr: format information matches the published table", () => {
  assert.equal(formatBits(1, 4).toString(2).padStart(15, "0"), "110011000101111"); // L, mask 4
  assert.equal(formatBits(0, 0).toString(2).padStart(15, "0"), "101010000010010"); // M, mask 0
});

test("qr: structure — size, finder patterns, timing, dark module, version growth", () => {
  const url = "http://felix-mac.local:8787/dl/AbCdEfGhIjKlMnOpQrStUv";
  const q = encodeQr(url);
  assert.equal(q.size, 17 + 4 * q.version);
  assert.equal(q.version, 4); // 54 bytes at level M
  const cell = (y: number, x: number) => must(q.modules[y])[x];
  const corners: [number, number][] = [[0, 0], [q.size - 7, 0], [0, q.size - 7]];
  for (const [ox, oy] of corners) {
    for (let d = 0; d < 7; d++) {
      assert.equal(cell(oy, ox + d), true, "finder top edge");
      assert.equal(cell(oy + 6, ox + d), true, "finder bottom edge");
    }
    assert.equal(cell(oy + 1, ox + 1), false, "finder ring");
    assert.equal(cell(oy + 3, ox + 3), true, "finder center");
  }
  for (let i = 8; i < q.size - 8; i++) assert.equal(cell(6, i), i % 2 === 0, "timing row");
  assert.equal(cell(q.size - 8, 8), true, "dark module");
  assert.equal(encodeQr("x").version, 1);
  assert.equal(encodeQr("x".repeat(213)).version, MAX_VERSION);
  assert.throws(() => encodeQr("x".repeat(214)), /too long/);
});

test("qr: version 7+ carries version information", () => {
  const q = encodeQr("y".repeat(110)); // 6-M holds 106 bytes, 7-M 122
  assert.equal(q.version, 7);
  // Version info for v7 is 000111110010010100 (ISO table); bit 0 at (x = size-11, y = 0),
  // mirrored at (x = 0, y = size-11).
  const top: number[] = [];
  const left: number[] = [];
  const cell = (y: number, x: number) => must(q.modules[y])[x];
  for (let i = 0; i < 18; i++) {
    top.push(cell(Math.floor(i / 3), q.size - 11 + (i % 3)) ? 1 : 0);
    left.push(cell(q.size - 11 + (i % 3), Math.floor(i / 3)) ? 1 : 0);
  }
  assert.equal(top.reverse().join(""), "000111110010010100");
  assert.equal(left.reverse().join(""), "000111110010010100");
});
