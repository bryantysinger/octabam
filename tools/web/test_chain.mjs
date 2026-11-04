// The web builder's chain under node, for every remix in a webpatch output,
// against the files `make image` wrote (tools/web/publish.py).
//   node tools/web/test_chain.mjs ZIP [OUT_DIR=out/web]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { build } from "../../docs/site/builder/builder.js";
import { makeEft } from "../../docs/site/builder/eft-run.js";
import createModule from "../../docs/site/builder/eft.mjs";

const [zip, out = "out/web"] = process.argv.slice(2);
const rd = (p) => new Uint8Array(readFileSync(p));
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
const manifest = JSON.parse(readFileSync(join(out, "manifest.json"), "utf8"));
const stockZip = rd(zip);

let bad = 0;
for (const meta of manifest.remixes) {
  console.log(meta.name);
  const ref = (f) => rd(join(out, "ref", meta.name, f));
  const r = await build({
    file: stockZip, patch: rd(join(out, meta.patch)), meta,
    eft: makeEft(createModule), onStep: () => {},
  });
  for (const [n, got, want] of [[r.names.bin, r.bin, ref("card.bin")],
                                [r.names.syx, r.syx, ref("midi.syx")],
                                [r.names.rmx, r.rmx, ref("image.rmx")]]) {
    const ok = eq(got, want);
    if (!ok) bad++;
    console.log(" ", ok ? "identical" : "DIFFERS  ", n);
  }
}
process.exit(bad ? 1 : 0);
