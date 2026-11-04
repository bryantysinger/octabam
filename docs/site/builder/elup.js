// The CF-card OS UPGRADE wrapper. Mirrors tools/build/make_bin.py.
const XOR_A = 0x9e3b16a2, XOR_B = 0x764e28ca;
const C3 = 0x360fa955, C7 = 0xef4a9ab6;
const MAGIC = 0x454c5550;
export const DEFAULT_SEED = 0x2f1349d2;

const rot16 = (v) => ((v << 16) | (v >>> 16)) >>> 0;
const bswap = (v) =>
  (((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v >>> 8) & 0xff00) | (v >>> 24)) >>> 0;

function encodeWord(k, p) {
  const v0 = (k & 0x800000) === 0;
  const x = (k ^ (v0 ? C3 : C7) ^ p) >>> 0;
  return v0 ? (rot16(x) ^ XOR_A) >>> 0 : (bswap(x) ^ XOR_B) >>> 0;
}

export function encode(elek, seed = DEFAULT_SEED) {
  if (String.fromCharCode(...elek.subarray(0, 4)) !== "ELEK") {
    throw new Error("container does not start with ELEK");
  }
  const payloadLen = (4 + elek.length + 3) & ~3;
  const words = payloadLen / 4;
  const out = new Uint8Array(8 + (words + 1) * 4);
  const dv = new DataView(out.buffer);
  const plain = new Uint8Array(payloadLen);
  new DataView(plain.buffer).setUint32(0, elek.length, false);
  plain.set(elek, 4);
  const pv = new DataView(plain.buffer);
  dv.setUint32(0, MAGIC, false);
  dv.setUint32(4, seed, false);
  let k = seed >>> 0, acc = 0;
  for (let w = 0; w < words; w++) {
    const p = pv.getUint32(w * 4, false);
    k = encodeWord(k, p);
    dv.setUint32(8 + w * 4, k, false);
    acc = (acc + p) >>> 0;
  }
  dv.setUint32(8 + words * 4, encodeWord(k, acc), false);
  return out;
}
