// Minimal QR Code encoder for the one-time download link (DESIGN §7.8): byte mode, error
// correction level M, versions 1-10 (up to 213 bytes, plenty for a LAN URL). Zero dependencies.
// Follows ISO/IEC 18004; structure after Project Nayuki's reference implementation (MIT).
// Returns a module matrix; rendering (canvas in the setup page) is the caller's job, so no
// markup is ever generated from it.

type Group = readonly [blocks: number, dataCodewords: number];

/** Level M block structure per version (index = version): ecc codewords per block, block groups. */
const M_BLOCKS: readonly (readonly [ecc: number, groups: readonly Group[]])[] = [
  [0, []], // no version 0
  [10, [[1, 16]]],
  [16, [[1, 28]]],
  [26, [[1, 44]]],
  [18, [[2, 32]]],
  [24, [[2, 43]]],
  [16, [[4, 27]]],
  [18, [[4, 31]]],
  [22, [[2, 38], [2, 39]]],
  [22, [[3, 36], [2, 37]]],
  [26, [[4, 43], [1, 44]]],
];
const ALIGN: readonly (readonly number[])[] = [[], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];
const FORMAT_BITS_M = 0;
export const MAX_VERSION = 10;

/** Element `i` of `a`; every index here is computed in range, so a miss is a bug, not data. */
function at<T>(a: readonly T[], i: number): T {
  const v = a[i];
  if (v === undefined) throw new RangeError(`QR index ${i} out of range`);
  return v;
}

/** GF(2^8) multiply modulo x^8 + x^4 + x^3 + x^2 + 1 */
function gfMul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}

function rsDivisor(degree: number): number[] {
  const r: number[] = Array<number>(degree - 1).fill(0).concat([1]);
  let root = 1;
  for (let i = 0; i < degree; i++) {
    for (let j = 0; j < r.length; j++) {
      r[j] = gfMul(at(r, j), root);
      if (j + 1 < r.length) r[j] = at(r, j) ^ at(r, j + 1);
    }
    root = gfMul(root, 2);
  }
  return r;
}

/** Reed-Solomon error correction codewords. */
export function rsRemainder(data: readonly number[], degree: number): number[] {
  const div = rsDivisor(degree);
  const r: number[] = Array<number>(degree).fill(0);
  for (const b of data) {
    const factor = b ^ (r.shift() ?? 0);
    r.push(0);
    div.forEach((c, i) => (r[i] = at(r, i) ^ gfMul(c, factor)));
  }
  return r;
}

/** 15-bit format information. */
export function formatBits(eclBits: number, mask: number): number {
  const data = (eclBits << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}

const dataCodewords = (v: number): number => at(M_BLOCKS, v)[1].reduce((n, [b, d]) => n + b * d, 0);
const countBits = (v: number): number => (v <= 9 ? 8 : 16);

export interface QrSymbol {
  version: number;
  size: number;
  /** modules[y][x], true = dark */
  modules: boolean[][];
}

/** Encode bytes as a QR symbol (strings are UTF-8 encoded). */
export function encodeQr(input: string | Uint8Array): QrSymbol {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let version = 1;
  while (version <= MAX_VERSION && 4 + countBits(version) + 8 * bytes.length > dataCodewords(version) * 8) version++;
  if (version > MAX_VERSION) throw new Error(`QR payload too long (${bytes.length} bytes)`);

  // Data bit stream: mode, count, bytes, terminator, byte padding, pad codewords.
  const bits: number[] = [];
  const put = (val: number, len: number): void => {
    for (let i = len - 1; i >= 0; i--) bits.push((val >>> i) & 1);
  };
  put(0b0100, 4);
  put(bytes.length, countBits(version));
  for (const b of bytes) put(b, 8);
  const capacity = dataCodewords(version) * 8;
  put(0, Math.min(4, capacity - bits.length));
  put(0, (8 - (bits.length % 8)) % 8);
  for (let pad = 0xec; bits.length < capacity; pad ^= 0xec ^ 0x11) put(pad, 8);
  const data: number[] = [];
  for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));

  // Split into blocks, add error correction, interleave.
  const [ecc, groups] = at(M_BLOCKS, version);
  const blocks: number[][] = [];
  let k = 0;
  for (const [count, len] of groups) {
    for (let i = 0; i < count; i++) {
      blocks.push(data.slice(k, k + len));
      k += len;
    }
  }
  const eccBlocks = blocks.map((b) => rsRemainder(b, ecc));
  const maxLen = Math.max(...blocks.map((b) => b.length));
  const codewords: number[] = [];
  for (let i = 0; i < maxLen; i++) for (const b of blocks) if (i < b.length) codewords.push(at(b, i));
  for (let i = 0; i < ecc; i++) for (const e of eccBlocks) codewords.push(at(e, i));

  // Function patterns.
  const size = version * 4 + 17;
  const modules: boolean[][] = Array.from({ length: size }, () => Array<boolean>(size).fill(false));
  const isFn: boolean[][] = Array.from({ length: size }, () => Array<boolean>(size).fill(false));
  const fn = (x: number, y: number, dark: boolean): void => {
    at(modules, y)[x] = dark;
    at(isFn, y)[x] = true;
  };
  for (let i = 0; i < size; i++) {
    fn(6, i, i % 2 === 0);
    fn(i, 6, i % 2 === 0);
  }
  for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]] as const) {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx;
        const y = cy + dy;
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        if (x >= 0 && x < size && y >= 0 && y < size) fn(x, y, d !== 2 && d !== 4);
      }
    }
  }
  const al = at(ALIGN, version);
  for (let i = 0; i < al.length; i++) {
    for (let j = 0; j < al.length; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) fn(at(al, i) + dx, at(al, j) + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  }
  const drawFormat = (mask: number): void => {
    const f = formatBits(FORMAT_BITS_M, mask);
    const bit = (i: number): boolean => ((f >>> i) & 1) === 1;
    for (let i = 0; i <= 5; i++) fn(8, i, bit(i));
    fn(8, 7, bit(6));
    fn(8, 8, bit(7));
    fn(7, 8, bit(8));
    for (let i = 9; i < 15; i++) fn(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) fn(size - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) fn(8, size - 15 + i, bit(i));
    fn(8, size - 8, true); // dark module
  };
  drawFormat(0); // reserve the area; redrawn with the chosen mask
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const v = (version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const dark = ((v >>> i) & 1) === 1;
      const a = size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      fn(a, b, dark);
      fn(b, a, dark);
    }
  }

  // Codewords in the zigzag order.
  let i = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const up = ((right + 1) & 2) === 0;
        const y = up ? size - 1 - vert : vert;
        if (!at(at(isFn, y), x) && i < codewords.length * 8) {
          at(modules, y)[x] = ((at(codewords, i >>> 3) >>> (7 - (i & 7))) & 1) === 1;
          i++;
        }
      }
    }
  }

  // Pick the mask with the lowest penalty (any mask yields a valid symbol).
  const MASKS: readonly ((x: number, y: number) => boolean)[] = [
    (x, y) => (x + y) % 2 === 0,
    (_x, y) => y % 2 === 0,
    (x) => x % 3 === 0,
    (x, y) => (x + y) % 3 === 0,
    (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
    (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
    (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
  ];
  const applyMask = (m: number): void => {
    const mask = at(MASKS, m);
    for (let y = 0; y < size; y++) {
      const row = at(modules, y);
      const fnRow = at(isFn, y);
      for (let x = 0; x < size; x++) if (!at(fnRow, x) && mask(x, y)) row[x] = !at(row, x);
    }
  };
  let best = 0;
  let bestScore = Infinity;
  for (let m = 0; m < 8; m++) {
    applyMask(m);
    drawFormat(m);
    const s = penalty(modules);
    if (s < bestScore) [best, bestScore] = [m, s];
    applyMask(m); // undo (XOR)
  }
  applyMask(best);
  drawFormat(best);
  return { version, size, modules };
}

/** ISO penalty rules 1 (runs), 2 (2x2 blocks), 3 (finder-like), 4 (balance). */
function penalty(m: readonly (readonly boolean[])[]): number {
  const n = m.length;
  let score = 0;
  const lines: (readonly boolean[])[] = [];
  for (let y = 0; y < n; y++) lines.push(at(m, y));
  for (let x = 0; x < n; x++) lines.push(m.map((row) => at(row, x)));
  for (const line of lines) {
    let run = 1;
    for (let i = 1; i <= n; i++) {
      if (i < n && line[i] === line[i - 1]) run++;
      else {
        if (run >= 5) score += run - 2;
        run = 1;
      }
    }
    const s = line.map((d) => (d ? "1" : "0")).join("");
    for (const p of ["10111010000", "00001011101"]) for (let i = s.indexOf(p); i !== -1; i = s.indexOf(p, i + 1)) score += 40;
  }
  for (let y = 0; y < n - 1; y++) {
    const r0 = at(m, y);
    const r1 = at(m, y + 1);
    for (let x = 0; x < n - 1; x++) {
      const c = at(r0, x);
      if (c === at(r0, x + 1) && c === at(r1, x) && c === at(r1, x + 1)) score += 3;
    }
  }
  const dark = m.flat().filter(Boolean).length;
  score += Math.floor(Math.abs((dark * 20) / (n * n) - 10)) * 10;
  return score;
}
