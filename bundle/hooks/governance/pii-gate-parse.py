# pii-gate-parse.py — helper for pii-gate-pretooluse.sh.
#
# Reads a PreToolUse hook payload on stdin. If the target path is inside the published
# governance tree (~/.claude/hooks/ or ~/.claude/skills/) AND the tool carries pending text,
# writes that text to <outdir>/<same basename as the target> and prints the target path.
# Otherwise prints nothing and exits 0 (= the gate allows).
#
# The basename is preserved because check-no-pii.sh exempts machine-local files by basename.
# Lives as its own file rather than an inline heredoc: an inline python block inside a shell
# hook is the exact edit shape that keeps getting mangled by outer quoting on this machine.
import json
import os
import sys


def drive_forms(x):
    """C:/Users/... and /c/Users/... name the same place under git-bash."""
    out = {x}
    if len(x) > 2 and x[1] == ":":
        out.add("/" + x[0] + x[2:])
    if x.startswith("/") and len(x) > 2 and x[2] == "/":
        out.add(x[1] + ":" + x[2:])
    return out


def _read_env_var(name):
    """B9: read a KEY=value (optionally `export KEY=value`) out of the gitignored, machine-local
    ~/.claude/.governance-local.env. The real path lives ONLY there, so this published file stays
    clean; a naive hardcoded checkout dir would be both an identity leak and wrong on every other
    machine (see end-session.sh's GH_REPO note)."""
    path = os.path.expanduser("~") + "/.claude/.governance-local.env"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                s = ln.strip()
                if s.startswith("export "):
                    s = s[7:].strip()
                if s.startswith(name + "="):
                    v = s[len(name) + 1:].strip()
                    if len(v) >= 2 and v[0] in "'\"" and v[-1] == v[0]:
                        v = v[1:-1]
                    return v or None
    except Exception:
        return None
    return None


def _read_mirror_roots():
    """B9: machine-local checkout roots that carry a mirror of the framework, one per line,
    '#' comments and blanks ignored. Same source sync-governance-copies.sh reads."""
    path = os.path.expanduser("~") + "/.claude/.governance-mirrors"
    out = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                s = ln.strip()
                if s and not s.startswith("#"):
                    out.append(s)
    except Exception:
        pass
    return out


def main():
    if len(sys.argv) < 2:
        return 0
    outdir = sys.argv[1]
    try:
        payload = sys.stdin.read()
    except Exception:
        return 0
    if not payload.strip():
        return 0
    try:
        d = json.loads(payload)
    except Exception as exc:
        # A non-empty payload that is not JSON is not "nothing to do" — it is the gate being
        # fed something it does not understand. Report it loudly (the caller turns a non-zero
        # exit into a visible MALFUNCTION + open gate) instead of silently allowing.
        sys.stderr.write("payload is not JSON: %s\n" % exc)
        return 4
    if not isinstance(d, dict):
        return 0
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        return 0
    p = ti.get("file_path") or ti.get("notebook_path") or ""
    if not isinstance(p, str) or not p.strip():
        return 0

    home_expand = os.path.expanduser("~").replace("\\", "/").rstrip("/")
    home = home_expand.lower()
    low = p.replace("\\", "/").lower()
    roots = []

    def _add_root(base, sub):
        b = (base or "").replace("\\", "/").rstrip("/").lower()
        if b:
            for hh in drive_forms(b):
                roots.append(hh + sub)

    for h in drive_forms(home):
        # These are exactly the trees sync-governance-copies.sh copies into the installer
        # bundle, i.e. the private->public crossing. Keep this list in step with that hook:
        # it syncs hooks/ and skills/ to every mirror AND the bundle, and docs/ to the bundle.
        # docs/ was missed on the first arming (2026-09-01) — GOVERNANCE-AGENT-GUIDE.md is
        # published and is exactly where a worked example naming a real path would be written.
        roots.append(h + "/.claude/hooks/")
        roots.append(h + "/.claude/skills/")
        roots.append(h + "/.claude/docs/")
        # The installer bundle is the publishable artifact itself: anything written straight
        # into it bypasses the sync and reaches the repo on the next push with no other check.
        roots.append(h + "/.claude/governance-installer/bundle/")

    # B9: two publication surfaces the roots above did NOT cover, both resolved from gitignored
    # machine-local config so this file stays clean:
    #  1. the repo checkout's bundle/ — a write straight into it reaches the PUBLIC repo on the
    #     next push (its dir name has no ".claude" substring, so the wrapper's fast prefilter also
    #     had to be widened to let it reach this parser);
    #  2. every mirror's .claude/hooks|skills — a mirror can be a real project repo (e.g.
    #     Gold-B-s-Agent) and the sync copies live governance files straight into it.
    repo = (os.environ.get("GOV_REPO_PATH") or _read_env_var("GOV_REPO_PATH")
            or (home_expand + "/claude-code-governance"))
    _add_root(repo, "/bundle/")
    for m in _read_mirror_roots():
        _add_root(m, "/.claude/hooks/")
        _add_root(m, "/.claude/skills/")

    if not any(f.startswith(r) for f in drive_forms(low) for r in roots):
        return 0

    parts = []

    def add(v):
        if isinstance(v, str) and v:
            parts.append(v)

    add(ti.get("content"))
    add(ti.get("new_string"))
    add(ti.get("new_source"))
    eds = ti.get("edits")
    if isinstance(eds, list):
        for e in eds:
            if isinstance(e, dict):
                add(e.get("new_string"))
    if not parts:
        return 0

    base = os.path.basename(p.replace("\\", "/").rstrip("/")) or "pending.txt"
    # Own subdirectory so the scratch copy can never collide with the caller's own scratch
    # names (py.err, .patterns) no matter what the edited file happens to be called.
    # Forward slashes throughout: the caller sed-substitutes this path out of the scanner's
    # report, and a Windows backslash in the sed PATTERN is an escape, so the substitution
    # silently misses and the human is shown a temp path instead of the file they edited.
    destdir = outdir.replace("\\", "/").rstrip("/") + "/pending"
    try:
        os.makedirs(destdir)
    except Exception:
        pass
    dest = destdir + "/" + base
    try:
        with open(dest, "w", encoding="utf-8", errors="replace", newline="") as fh:
            fh.write("\n".join(parts))
    except Exception as exc:
        sys.stderr.write("cannot write scratch copy: %s\n" % exc)
        return 3
    # "<real target path>\t<scratch copy>" — the caller would otherwise need an ls|grep|head
    # pipeline (4 process spawns) to rediscover a name this process already knows.
    sys.stdout.write(p + "\t" + dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
