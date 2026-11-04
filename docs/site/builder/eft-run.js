// Runs the WASM elektron-firmware-tool (tools/web/build_eft_wasm.sh) on an
// in-memory filesystem. A fresh module instance per call.
export function makeEft(createModule) {
  return async function eft(files, args, env = {}) {
    const out = [];
    const m = await createModule({
      noInitialRun: true,
      print: (s) => out.push(s),
      printErr: (s) => out.push(s),
      preRun: [(mod) => Object.assign(mod.ENV, env)],
    });
    for (const [path, bytes] of Object.entries(files)) {
      const dir = path.slice(0, path.lastIndexOf("/"));
      if (dir) m.FS.mkdirTree(dir);
      m.FS.writeFile(path, bytes);
    }
    m.FS.mkdirTree("/raw");
    let status = 0;
    try { status = m.callMain(args) ?? 0; } catch (e) { status = e?.status ?? 1; }
    if (status !== 0) throw new Error(`elektron-firmware-tool exited ${status}:\n${out.join("\n")}`);
    const result = {};
    const walk = (dir) => {
      for (const name of m.FS.readdir(dir)) {
        if (name === "." || name === "..") continue;
        const p = (dir === "/" ? "" : dir) + "/" + name;
        const st = m.FS.stat(p);
        if (m.FS.isDir(st.mode)) { if (!["/dev", "/proc", "/tmp", "/home"].includes(p)) walk(p); }
        else result[p] = m.FS.readFile(p);
      }
    };
    walk("/");
    return result;
  };
}
