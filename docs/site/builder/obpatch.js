// OBP1 applier. The format is defined in tools/web/obpatch.py.
const MAGIC = [0x4f, 0x42, 0x50, 0x31];

async function inflate(bytes) {
  const s = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}

export async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function same(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

function varint(buf, i) {
  let n = 0, shift = 0;
  for (;;) {
    const b = buf[i++];
    n += (b & 0x7f) * 2 ** shift;
    if (!(b & 0x80)) return [n, i];
    shift += 7;
  }
}

export async function apply(stock, patch) {
  const raw = await inflate(patch);
  if (!same(raw.subarray(0, 4), MAGIC)) throw new Error("not an OBP1 patch");
  const stockSha = raw.subarray(4, 36);
  const outSha = raw.subarray(36, 68);
  const outLen = new DataView(raw.buffer, raw.byteOffset + 68, 4).getUint32(0, true);
  if (!same(await sha256(stock), stockSha)) {
    throw new Error("this is not the stock 1.40C MAIN OS the patch was made against");
  }
  const out = new Uint8Array(outLen);
  let o = 0, i = 72;
  while (i < raw.length) {
    let tag, off;
    [tag, i] = varint(raw, i);
    const n = Math.floor(tag / 2);
    if (tag % 2 === 0) {
      [off, i] = varint(raw, i);
      out.set(stock.subarray(off, off + n), o);
    } else {
      out.set(raw.subarray(i, i + n), o);
      i += n;
    }
    o += n;
  }
  if (o !== outLen || !same(await sha256(out), outSha)) {
    throw new Error("patched output does not match the recorded hash");
  }
  return out;
}
