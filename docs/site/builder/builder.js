// Stock 1.40C + a published patch -> the flashable files. Nothing leaves the
// browser; the stock OS is read from the file the user picks.
import { apply } from "./obpatch.js";
import { encode as elupEncode } from "./elup.js";
import { readEntry } from "./zip.js";

const SYX = "OCTATRACK_OS1.40C.syx";

// The user may pick the Elektron zip or the .syx inside it.
export async function stockSyx(file) {
  if (file[0] === 0x50 && file[1] === 0x4b) {
    const syx = await readEntry(file, SYX);
    if (!syx) throw new Error(`${SYX} is not in that zip`);
    return syx;
  }
  if (file[0] === 0xf0) return file;
  throw new Error("expected the Elektron zip or OCTATRACK_OS1.40C.syx");
}

// `eft(files, args, env)` runs elektron-firmware-tool on an in-memory
// filesystem: files is {path: bytes}, the result is the same map afterwards.
export async function build({ file, patch, meta, eft, onStep = () => {} }) {
  const syx = await stockSyx(file);

  onStep("unpacking stock MAIN OS");
  let fs = await eft({ "/in.syx": syx }, ["-i", "/in.syx", "-d", "3", "-o", "/raw"]);
  const stock = fs["/raw/section_3_MAIN_OS.bin"];
  if (!stock) throw new Error("elektron-firmware-tool did not produce section 3");

  onStep("applying the octabam patch");
  const image = await apply(stock, patch);

  onStep("building the container");
  fs = await eft(
    { "/in.syx": syx, "/image.bin": image },
    ["-i", "/in.syx", "-c", "3", "/image.bin", "-V", meta.version, "-o", "/out.syx"],
    { EFT_EMIT_CONTAINER: "/elek.bin" },
  );
  const elek = fs["/elek.bin"], outSyx = fs["/out.syx"];
  if (!elek || !outSyx) throw new Error("elektron-firmware-tool wrote no image");

  onStep("wrapping for the card");
  return {
    bin: elupEncode(elek),
    syx: outSyx,
    rmx: image,
    names: {
      bin: `OCTATRACK_${meta.version}.bin`,
      syx: `OCTATRACK_OS1.40C_${meta.version}.syx`,
      rmx: `${meta.imageName}.RMX`,
    },
  };
}
