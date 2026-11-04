#!/usr/bin/env python3
"""Remove a gate's newly created virtual cards after it passes.

Only ignored, single-link regular ``out/**/*.img`` files are candidates.
Untouched cards present before the gate, pinned trees, and nested Git
worktrees are preserved. A failed or interrupted gate keeps its cards for diagnosis.
``KEEP_CARDS=1`` keeps cards from passing gates too.

    python3 tools/verify/card_retention.py run -- make check-impl REMIX=bus
"""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RetentionError(RuntimeError):
    pass


def _stamp(path):
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
        return None
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_blocks)


def _safe_path(root, relative):
    """Recheck ancestors immediately before unlink, including late pins."""
    parent = root / "out"
    if parent.is_symlink() or (parent / ".keep-cards").exists():
        return False
    for name in relative.parts[1:-1]:
        parent /= name
        if parent.is_symlink() or (parent / ".git").exists() or (parent / ".keep-cards").exists():
            return False
    return True


def snapshot(root=ROOT):
    """Identity of eligible cards relative to root, without following links."""
    root = pathlib.Path(root).resolve()
    out = root / "out"
    if out.is_symlink():
        raise RetentionError("out/ is a symlink; refusing card cleanup")
    if not out.is_dir():
        return {}
    paths = []
    for directory, dirs, files in os.walk(out, followlinks=False):
        here = pathlib.Path(directory)
        if (here / ".keep-cards").exists():
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs if not (here / d).is_symlink()
                   and not (here / d / ".git").exists()]
        for name in files:
            if name.endswith(".img"):
                path = here / name
                try:
                    if _stamp(path) is not None:
                        paths.append(path.relative_to(root))
                except FileNotFoundError:
                    continue
    if not paths:
        return {}
    # Git does not report tracked files as ignored. Refuse an inspection error.
    result = subprocess.run(["git", "check-ignore", "-z", "--stdin"], cwd=root,
                            input="\0".join(map(str, paths)) + "\0", text=True,
                            capture_output=True)
    if result.returncode not in (0, 1):
        raise RetentionError(f"git check-ignore failed: {result.stderr.strip()}")
    ignored = {pathlib.Path(p) for p in result.stdout.split("\0") if p}
    answer = {}
    for path in paths:
        if path in ignored:
            try:
                stamp = _stamp(root / path)
            except FileNotFoundError:
                continue
            if stamp is not None:
                answer[path] = stamp
    return answer


def clean_new(root, before, label="gate", include_modified=False, keep=None):
    """Delete cards this gate created (or, after a complete suite, changed)."""
    root = pathlib.Path(root).resolve()
    keep = os.environ.get("KEEP_CARDS") == "1" if keep is None else keep
    if keep:
        return (0, 0)
    after = snapshot(root)
    new = {p: s for p, s in after.items() if p not in before or
           (include_modified and before[p] != s)}
    if not new:
        return (0, 0)
    if not shutil.which("lsof"):
        raise RetentionError("lsof is required before card cleanup")
    # A gate may be writing its log elsewhere in out/. Inspect the candidate
    # cards themselves, so an open log cannot prevent card cleanup.
    names = [str(root / p) for p in new]
    for start in range(0, len(names), 100):
        held = subprocess.run(["lsof", "-nP", "--", *names[start:start + 100]],
                              capture_output=True, text=True)
        if held.returncode != 1 or held.stdout.strip() or held.stderr.strip():
            raise RetentionError("a card has open handles or lsof could not verify it is idle")
    current = snapshot(root)
    if any(current.get(p) != stamp for p, stamp in new.items()):
        raise RetentionError("card manifest changed; nothing removed")
    removed = {}
    for path, stamp in sorted(new.items()):
        if not _safe_path(root, path) or _stamp(root / path) != stamp:
            raise RetentionError("card changed during cleanup; stopped")
        (root / path).unlink()
        removed[path] = stamp[2]
    receipt = {"gate": label, "files": {str(p): n for p, n in removed.items()},
               "count": len(removed), "bytes": sum(removed.values())}
    (root / "out/card-retention.json").write_text(json.dumps(receipt, indent=2) + "\n")
    with (root / "out/card-retention.jsonl").open("a") as log:
        log.write(json.dumps(receipt) + "\n")
    return (receipt["count"], receipt["bytes"])


class Gate:
    """Own this worktree's output until the gate and its cleanup finish.

    Nested runners inherit the locked file descriptor explicitly. Independent
    invocations fail before running; different shard roots use different locks.
    No process-global environment changes: shard workers run in threads.
    """
    def __init__(self, root, label, env=None, snapshot_cards=True, scope="cards"):
        self.root = pathlib.Path(root).resolve()
        self.label = label
        self.env = dict(os.environ if env is None else env)
        self.fd = None
        self.scope = scope
        self.snapshot_cards = snapshot_cards
        self.keep = self.env.get("KEEP_CARDS") == "1"

    @property
    def pass_fds(self):
        return (self.fd,)

    def __enter__(self):
        try:
            if not self.keep and not shutil.which("lsof", path=self.env.get("PATH")):
                raise RetentionError("lsof is required for card cleanup; install it before running gates")
            out = self.root / "out"
            if out.is_symlink():
                raise RetentionError("out/ is a symlink; refusing card cleanup")
            # Stored outside out/ and the shard checkout: refreshing/removing a
            # shard must not replace a held lock with a new, unlocked inode.
            common = subprocess.check_output(
                ["git", "rev-parse", "--git-common-dir"], cwd=ROOT, text=True).strip()
            locks = (ROOT / common).resolve() / "octabam-card-locks"
            locks.mkdir(exist_ok=True)
            lock = locks / (hashlib.sha256(f"{self.root}\0{self.scope}".encode()).hexdigest() + ".lock")
            inherited = json.loads(self.env.get("OCTABAM_CARD_LOCK", "null"))
            if inherited is not None and (not isinstance(inherited, list) or len(inherited) != 3):
                raise RetentionError("invalid inherited card lock")
            if inherited and inherited[:2] == [str(self.root), self.scope]:
                fd = int(inherited[2])
                # A stale environment variable is not permission to bypass the lock.
                a, b = os.fstat(fd), lock.lstat()
                if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                    raise RetentionError("inherited card lock does not match this worktree")
                self.fd = os.dup(fd)
            else:
                self.fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            st = os.fstat(self.fd)
            if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise RetentionError("card lock must be a single-link regular file")
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RetentionError("another gate run owns this worktree; use a separate worktree") from None
            self.env["OCTABAM_CARD_LOCK"] = json.dumps([str(self.root), self.scope, self.fd])
            self.before = {} if self.keep or not self.snapshot_cards else snapshot(self.root)
            return self
        except (OSError, ValueError, TypeError, RetentionError, subprocess.SubprocessError) as exc:
            self.__exit__(None, None, None)
            raise RetentionError(f"{self.label}: preflight: {exc}") from exc

    def __exit__(self, *unused):
        if self.fd is not None:
            # Close our reference; explicit LOCK_UN would also unlock the
            # parent's inherited open-file description while it is still running.
            os.close(self.fd)
            self.fd = None

    def finish(self, passed, include_modified=False):
        if not passed or self.keep:
            return
        try:
            count, size = clean_new(self.root, self.before, self.label, include_modified, keep=False)
            if count:
                print(f"card retention: {self.label}: removed {count} cards ({size / 2**20:.0f} MiB)", flush=True)
        except (OSError, RetentionError, subprocess.SubprocessError) as exc:
            raise RetentionError(f"{self.label}: cleanup: {exc}") from exc


def run(command, root=ROOT, env=None, include_modified=True):
    try:
        with Gate(root, " ".join(command), env) as cards:
            rc = subprocess.run(command, cwd=root, env=cards.env, pass_fds=cards.pass_fds).returncode
            cards.finish(rc == 0, include_modified)
            return rc if rc >= 0 else 128 - rc
    except RetentionError as exc:
        print(f"[FAIL] card retention: {exc}", file=sys.stderr, flush=True)
        return 2


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("run",))
    ap.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    command = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not command:
        ap.error("run requires a command after --")
    return run(command)


if __name__ == "__main__":
    sys.exit(main())
