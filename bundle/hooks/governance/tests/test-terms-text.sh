#!/usr/bin/env bash
# test-terms-text.sh - the accepted texts say what 2.0.0 does (legal conditions C1, C7, C8, C9, C11;
# plan 2026-09-30 task P9). Created 2026-09-30.
#
# WHAT IT CHECKS, over ONE tree root in the repo/staging layout (NOTICE-AUTO-UPDATE.md, README.md,
# install.sh, bundle/TERMS-VERSION, bundle/hooks/governance/{gov-update,close-push,consent-lib}.sh):
#   (a) C9  every case-insensitive "no liability" in NOTICE, README, install.sh, gov-update.sh,
#           close-push.sh and consent-lib.sh is one of the two carved-out DRAFTS phrasings, both in
#           the NOTICE (10.1 item 9's heading sentence; the summary's item 10) - any other match fails
#   (b)     NOTICE: the terms-summary markers exactly once each, no auto-update-waiver marker, the
#           last line is "Terms version: <n>", and it states USD 100, gross negligence, the
#           Anthropic non-affiliation, and has sections 2a, 10.3 and 10.5
#   (c) C8  NOTICE/README/Agent Guide carry none of the retired claims (GOV_AUTO_UPDATE, "installs
#           itself", "throw-away sandbox", the old unattended-signing sentence; and since the
#           round-1 review, F5: every "an agent CANNOT accept" form (D1; round 2 widened it to
#           "agent cannot", "cannot accept", "can not accept", "can't accept"), "run by no hook",
#           the typed phrase "I ENABLE PUSH AT SESSION CLOSE" and "typed phrase" (owner decision
#           2026-10-01: a plain y/N),
#           "it downloads nothing", the removed --enable-close-push flag (D2), "Automatic updates
#           will", "last successful check", "tell you to reinstall by hand", the old re-accept
#           reason (D5)). Matched on the text with line breaks folded to spaces, so a claim
#           wrapped over two lines is still found (MEASURED: three of them were, and a per-line
#           grep missed all three).
#   (d)     the summary gov_terms_summary prints (the lines install.sh shows before I ACCEPT) has at
#           most 12 items, numbered 1..n, and no line wider than 100 columns (the A.1 wrapping
#           rule). NOTE: the plan wrote "<= 12 lines"; the binding DRAFTS B.14 text is 10 items over
#           19 lines, so the bound is on ITEMS (flagged in the P9 report).
#   (e)     README's hook table has no SessionEnd row and has a consent-guard.sh row
#   (f) C1  bundle/TERMS-VERSION == NOTICE footer == TERMS_PINNED (1 until the first public push;
#           after it, gov-release.sh --terms-bump raises both, and this pin is raised with them)
#   (g) D1/D7 NOTICE states the honest forms: "safeguard", "not a guarantee", "has no switch of
#           its own" (the close commit), "whole `~/.claude/hooks/`" (uninstall scope), "published
#           version number" (what the version check downloads) - line breaks folded, as in (c).
#           (The typed phrase left this list on 2026-10-01: owner decision, a plain y/N; the
#           phrase and every "an agent cannot" form are now RETIRED claims in (c).)
#   (h) round 2 README pins (findings 3, 4, 5, 14, 18 and the owner decision 2026-10-01), folded:
#           the `--uninstall` options row, the "## Uninstall" section and the `--uninstall` line
#           in the update code block state the real scope (WHOLE ~/.claude/hooks/ and
#           ~/.claude/docs/, the ENTIRE settings.json hooks section, agents/ not removed); the
#           consent-guard.sh row says regular expressions, "can do what you can", names built at
#           run time and marker removal inside an interpreter, and no longer "is never blocked";
#           "## Push at session close" says y/N and names no phrase and no always-on machine;
#           "always on" appears only in "## Cutting a release (maintainer)"; no "phrase" (other
#           than "passphrase") anywhere in README
#   (i) D2  README's options table has no --enable-close-push row and has a --no-close-push row;
#           the consent-guard.sh row's event column names Read (the matcher ships with Read)
#   (h) round 3 (fix round 3 group A, 2026-10-02; owner decision 2026-10-01 "disclose the marker"):
#           "## Push at session close" now MUST name `.governance-source` and `gov-release.sh` and
#           say a recorded no "does not turn it off" (it used to be forbidden to name the marker);
#           the maintainer section says gov-release.sh creates the marker after EVERY release, any
#           process can create it (a plain touch), a directory does not count, the guard's list is
#           not closed, --enable asks/records nothing, --disable records OFF while push stays ON,
#           and no longer "only the owner creates" / "once" / "first run"; the guard row says its
#           list of write forms is not closed; the Uninstall section says the marker is not removed
#   (j) round 3: the same disclosure and the other round-3 sentences (verify-r3 findings 3, 5, 6, 7,
#           8 and the minors) in NOTICE, the Human Guide, the Agent Guide and the
#           live-state-orchestrator skill: every new sentence present (REQ_J), every old
#           unconditional / false one absent (FORB_J). ONE awk over the four files, folded and
#           lowercased as in (c).
#   (j) round 3b (fix round 3b group G3, 2026-10-02; VERIFY ROUND 4 blocking 5/6 and the minors):
#           the same awk also pins the impact-safe-executor (key I) and plan-and-execute (key P)
#           skills and README rows outside the three (h) sections (key R): the push carries every
#           commit the upstream lacks (not "the commits of the closing session"); gov-release.sh makes
#           the marker on every run that pushes the signed tag (not "after every successful
#           release"); deleting the marker turns push off only with no `y` recorded ("run it and also
#           delete", not "delete that file instead"); the scripts refuse to RECORD an acceptance (a
#           re-install whose terms are accepted is not refused); both machine kinds in every close
#           skill. (h) gains the same README sentences inside "## Push at session close" and the
#           maintainer section. Mutants j4 (README rows) and h16 (README push section) are new.
# THEN it proves every check can fail: one mutant per check on a temp copy of the files (must fire),
# plus a benign edit that must NOT fire. It asserts the printed text of each check, not only a count.
# The round-3 mutants (h14, h15, j1, j2) each break every round-3 pin of their file at once and
# assert each pin by name, so every pattern is shown to fire on its own text.
#
# Read-only on the real tree. No sandbox HOME is created (nothing here reads or writes ~/.claude).
# The Agent and Human Guides are read at <root>/bundle/docs/, the skills at
# <root>/bundle/skills/{live-state-orchestrator,impact-safe-executor,plan-and-execute}/SKILL.md.
# Usage: bash test-terms-text.sh [<root>]    (default: found from this file's location; env
#        GOV_TERMS_ROOT overrides). Output ends with: terms-text selftest: pass=<n> fail=<n>
#        (exit 1 on any fail or when nothing was checked)
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOV_DIR="$(cd "$HERE/.." && pwd)"
TERMS_PINNED=1
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no [$3] in [$(printf '%s' "$2" | head -c 600)])" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 ([$3] present in [$(printf '%s' "$2" | head -c 600)])" ;; *) ok "$1" ;; esac; }

ROOT="${1:-${GOV_TERMS_ROOT:-}}"
if [ -z "$ROOT" ]; then
  # bundle/hooks/governance/tests -> the root three levels up; the live ~/.claude/hooks/governance
  # -> the staging copy ~/.claude/governance-installer.
  for _c in "$GOV_DIR/../../.." "$GOV_DIR/../../governance-installer"; do
    if [ -f "$_c/NOTICE-AUTO-UPDATE.md" ] && [ -f "$_c/README.md" ] && [ -d "$_c/bundle/hooks/governance" ]; then
      ROOT="$(cd "$_c" && pwd)"; break
    fi
  done
fi
if [ -z "$ROOT" ] || [ ! -f "$ROOT/NOTICE-AUTO-UPDATE.md" ]; then
  echo "  FAIL no tree root with NOTICE-AUTO-UPDATE.md found (pass one, or set GOV_TERMS_ROOT)"
  echo "terms-text selftest: pass=0 fail=1"
  exit 1
fi
echo "terms-text: tree root $ROOT"

# The two carved-out phrasings (C9), as lines with leading blanks and CR removed.
ALLOW_1='9. **No liability, as far as the law allows.** To the fullest extent the law allows, the maintainer'
ALLOW_2='10. Free, AS IS (MIT). No liability as far as the law allows; section 10.1 says what the law'
# The files (a) scans, relative to a root.
SCAN_A="NOTICE-AUTO-UPDATE.md README.md install.sh bundle/hooks/governance/gov-update.sh bundle/hooks/governance/close-push.sh bundle/hooks/governance/consent-lib.sh"

_lf() { tr -d '\r' < "$1"; }
# _cnt <text> <pattern> -> _N = how many times <pattern> occurs in <text> (literal). Pure bash, no
# fork: it runs ~6 times per run_checks, and run_checks runs ~50 times.
_cnt() { local s="$1" p="$2" t; _N=0; [ -n "$p" ] || return 0; t="${s//"$p"/}"; _N=$(( (${#s} - ${#t}) / ${#p} )); }
# _fcount <file> <label> <mode> -> ONE awk pass over the file folded to one line (CR dropped, a
# blockquote '>' at a line start dropped, every run of blanks and newlines one space), so a
# sentence wrapped over lines still matches; case-insensitive. The patterns come one per line in
# env PATS. mode "present": prints " <label>:[<pat>]x<n>" for each pattern found; mode "absent":
# prints " missing[<pat>]" for each pattern not found. One process per file, not per pattern
# (MEASURED: a pipeline per pattern made a run take minutes on Windows).
_fcount() {
  # Folded per line (round 3): a gsub over the whole joined file is quadratic in gawk (MEASURED
  # 64 s for 260 KB on a loaded machine); per line it is linear and the folded text is the same.
  awk -v lbl="$2" -v mode="$3" '
    { sub(/\r$/, ""); sub(/^[ \t]*>[ \t]*/, ""); gsub(/[ \t]+/, " "); sub(/^ /, ""); sub(/ $/, "")
      if ($0 != "") t = t tolower($0) " " }
    END {
      n = split(ENVIRON["PATS"], P, "\n")
      for (i = 1; i <= n; i++) {
        if (P[i] == "") continue
        p = tolower(P[i]); c = 0; s = t
        while ((k = index(s, p)) > 0) { c++; s = substr(s, k + length(p)) }
        if (mode == "present" && c > 0) printf " %s:[%s]x%d", lbl, P[i], c
        if (mode == "absent" && c == 0) printf " missing[%s]", P[i]
      }
    }' "$1"
}
# The retired claims (c) and the required honest forms (g), one per line.
RETIRED_C='GOV_AUTO_UPDATE
installs itself
throw-away sandbox
without a passphrase, so that releases can be signed without a human
cannot accept them for you
cannot accept the terms for you
never accepted on your behalf — not by the software, and not by an AI agent
refuses to record an acceptance made inside an AI-agent session
Refused inside an AI-agent session
run by no hook
it downloads nothing
--enable-close-push
Automatic updates will
automatic update is running
last successful check
tell you to reinstall by hand
re-accept: gov-update.sh --accept-terms
I ENABLE PUSH AT SESSION CLOSE
typed phrase
agent cannot
cannot accept
can not accept
can'"'"'t accept'
REQUIRED_G='safeguard
not a guarantee
has no switch of its own
whole `~/.claude/hooks/`
published version number'
# (j) round 3: "<key>|<pattern>", key N = NOTICE, H = Human Guide, A = Agent Guide, S = the
# live-state-orchestrator skill; round 3b: I = impact-safe-executor, P = plan-and-execute, R = README
# (rows outside the sections (h) owns). Matched folded and lowercased (ASCII only; Hebrew as is).
REQ_J=$(cat <<'EOF'
N|except on a machine that has a file named `~/.claude/.governance-source`, where it is on without asking
N|(section 10.3, which also states the one exception)
N|the personal-data scanner recognises fixed shapes
N|a name you did not list, client data and other confidential content can pass it
N|`--disable` alone does not turn it off: run it and also delete that file — deleting the file alone turns push off only when no `y` is recorded under the current terms
N|only when it is on: you turned it on, or the machine has the file named in section 10.3
N|two exceptions: on a machine with no local-modification baseline
N|with `GOV_UPDATE_OVERWRITE_LOCAL=1` your file is replaced, after being backed up
N|(on a machine that has the file `~/.claude/.governance-source`, run it and also delete that file — `--disable` alone does not turn it off there, and deleting the file alone turns it off only when no `y` is recorded under the current terms
N|when `node` is installed, the entire `hooks` section
N|without `node` that section is left in place, and the uninstall does not say so
N|it does not remove `~/.claude/.governance-source`
N|except on a machine that has the file named in section 10.3, where it is on without any answer
N|or the machine has a file named `~/.claude/.governance-source`, which turns it on without asking
N|on a machine without the file described in the next paragraph, turning it on needs a terminal and your answer
N|(where the file of the next paragraph exists, run it and also delete that file)
N|**the one exception: a file named `~/.claude/.governance-source`.**
N|no question is asked and no record is needed
N|does not turn it off. the file marks the machine on which the framework's releases are made
N|`gov-release.sh`, the release tool that is installed with the framework, creates it on every release run made from that machine's own repository that gets as far as pushing the signed release tag — also a run whose final check then fails
N|`ls -l ~/.claude/.governance-source`
N|to return to the rule above, delete the file
N|can create that file, as it can do anything else you can
N|(`consent-guard.sh`) refuses only the command forms it recognises
N|on a machine without the file named in section 10.3, push at session close goes back to off; where that file exists it stays on
N|exception: where a file named ~/.claude/.governance-source exists (gov-release.sh creates it), it is on (section 10.3).
N|carrying every commit of the current branch that the remote does not have yet — the closing session's commits and any earlier commit of yours on that branch that was never pushed
N|every commit of that branch the upstream does not have yet, including commits you made yourself and never pushed, not only the closing session's
N|refuse to record an acceptance when they detect an AI-agent session
N|a re-install on a machine whose current terms are already accepted records no acceptance and is not refused
H|`deny-git-bypass.sh` חוסם רק את הצורות שהוא מזהה
H|`GOV_GIT_DESTRUCTIVE_OK=1`
H|alias, `git -c alias.*`, דגל בתוך משתנה או סקריפט עוטף עוברים אותו
H|כבוי, עד שאתה מדליק אותו
H|`~/.claude/.governance-source`
H|`gov-release.sh` יוצר את הקובץ הזה בכל הרצה שמגיעה עד דחיפת ה-tag החתום
H|אם רשמת קודם `y` (תחת אותה גרסת תנאים), ה-push נשאר דולק
H|ה-push שולח כל commit בענף שעוד לא נמצא ב-upstream
H|ls -l ~/.claude/.governance-source
H|זה שומר, לא ערובה
H|ואם השומר עצמו נתקל בשגיאה פנימית הוא מעביר את הפעולה
A|or by `gov-release.sh` on every release run from that machine's own repository (`GOV_REPO_PATH`) that gets as far as pushing the signed tag
A|so a run whose rehearsal then fails leaves it too
A|deleting it turns push off only when no `enabled=1` record under the current terms remains
A|every commit of that branch the upstream lacks, the human's own unpushed local commits included
A|the scripts refuse to record an acceptance or an on when they detect an ai-agent session
A|a re-install whose current terms are already accepted is not refused and records no acceptance
A|a directory of that name does not count
A|`close-push.sh --enable` asks nothing and records nothing
A|records off while push stays on
A|is not closed: a safeguard, not a guarantee
S|on a client, the human's recorded choice
S|where the regular file `~/.claude/.governance-source` exists
S|never accept terms, yourself; never create or delete that file
S|creates it on every release run that gets as far as pushing the signed tag, even one whose rehearsal then fails
S|the push carries every commit of that branch the upstream lacks
I|on a client, the human's recorded choice
I|on a machine where the regular file `~/.claude/.governance-source` exists (the maintainer's), always, with no question and no record
I|it carries every commit of that branch the upstream lacks, the human's own unpushed local commits included
I|never accept terms, yourself; never create or delete that file
P|or always on the maintainer's machine (the file `~/.claude/.governance-source` exists; `GOV_CLOSE_PUSH=0` pauses it)
P|the push carries every commit of the branch its upstream lacks
P|never accept terms, yourself; never create or delete that file
R|refused when an ai-agent session is detected and the current terms are not yet accepted on this machine
R|refuse to record an acceptance when they detect one
R|a re-install whose current terms are already accepted is not refused and records no acceptance
R|every release run of it that gets as far as pushing the signed tag
R|push stays on until that file is deleted too
R|refuse to record an acceptance or an on when they detect an ai-agent session
R|creates the file on every release run that gets as far as pushing the signed tag
EOF
)
FORB_J=$(cat <<'EOF'
N|carrying the commits of the closing session
N|after every successful release
N|delete that file instead
N|installer and `gov-update.sh --accept-terms` refuse when they detect
N|finds only the names you listed
N|turning it on always needs a terminal and your answer
N|you accept. push at session close goes back to off
N|turn it on under section 10.3. 6.
N|is off unless you turn it on. this document tells you
N|default no). a push cannot be taken back. 6.
N|typed in your own terminal. these are safeguards
N|close-push.sh --disable`. pause it: `gov_close_push=0`
N|push at session close — only when you turned it on.
N|the framework's skills, and the entire `hooks`
N|**(a) push at session close — off unless you turn it on (section 10.3).**
N|turn it off at any time: `close-push.sh --disable`; pause it
N|turn push at session close off:** `bash ~/.claude/hooks/governance/close-push.sh --disable`;
H|תמיד דורשות אישור, ו-`deny-git-bypass.sh` חוסם אותן
H|— כבר לא דורש אותך. בסוף סשן
H|claude לא יכול לערוך קבצים
H|אחרי כל release מוצלח
A|created only by the owner
A|gov-release.sh's first run
A|pauses a push the human turned on, everywhere
A|after every successful release
A|the scripts refuse when they detect an ai-agent session
S|this machine — the human's recorded choice; otherwise
S|after every successful release
S|never create or delete that file, and never accept terms
I|push of the session's commits
I|this machine — the human's recorded choice; otherwise
P|this machine — the human's recorded choice; otherwise
R|creates the file after every successful release
R|every successful release it makes
R|the installer refuses when it detects one
R|only deleting that file does
R|refused when an ai-agent session is detected (a safeguard
R|refuse when they detect an ai-agent
EOF
)

# run_checks <root> -> one line per check: "PASS (x) ..." or "FAIL (x) ...".
run_checks() {
  local r="$1" n="$1/NOTICE-AUTO-UPDATE.md" rd="$1/README.md" ag="$1/bundle/docs/GOVERNANCE-AGENT-GUIDE.md" \
        hg="$1/bundle/docs/GOVERNANCE-HUMAN-GUIDE.md" sk="$1/bundle/skills/live-state-orchestrator/SKILL.md" \
        ski="$1/bundle/skills/impact-safe-executor/SKILL.md" skp="$1/bundle/skills/plan-and-execute/SKILL.md" \
        f rel line t allowed_seen1=0 allowed_seen2=0 bad_a="" \
        miss="" c s items lines wide seq tv foot last ph sec jmiss=""
  # Forks are what a run costs on Windows (MEASURED round 2, a loaded machine: ~0.4 s each, and
  # the mutants run this ~60 times), so each file is read by as few processes as possible: (a) one
  # awk over the six files, (b)+(f) one awk over NOTICE, (e)+(h)+(i) one awk over README.
  local -a files=()
  for rel in $SCAN_A; do
    if [ -f "$r/$rel" ]; then files+=("$r/$rel"); else bad_a="$bad_a $rel:MISSING"; fi
  done
  local row un blk gr push mnt all p hx n1 n2 n3 sess cgr enr nor ev
  hx=$(awk '
    function f(x) { gsub(/[ \t]+/, " ", x); return tolower(x) }
    { sub(/\r$/, "") }
    blkn > 0 { blk = blk $0 " "; blkn-- }
    /^bash install\.sh --uninstall +#/ && blk == "" { blk = $0 " "; blkn = 2 }
    index($0, "| `--uninstall` |") == 1 && row == "" { row = $0 }
    /^\| [^|]+ \| `consent-guard\.sh` \|/ { cgr++; if (gr == "") gr = $0 }
    /^\| *SessionEnd *\|/ { sess++ }
    /^\| `--enable-close-push` \|/ { enr++ }
    /^\| `--no-close-push` \|/ { nor++ }
    /^## / { sec = "" }
    /^## Uninstall/ { sec = "un"; next }
    /^## Push at session close/ { sec = "push"; next }
    /^## Cutting a release \(maintainer\)/ { sec = "mnt"; next }
    sec != "" { S[sec] = S[sec] $0 " " }
    { all = all $0 " " }
    END {
      ev = ""; if (gr != "") { split(gr, A, "|"); ev = A[2] }
      print f(row); print f(S["un"]); print f(blk); print f(gr); print f(S["push"]); print f(S["mnt"]); print f(all)
      printf "%d|%d|%d|%d|%s\n", sess, cgr, enr, nor, ev
    }' "$rd")
  { IFS= read -r row; IFS= read -r un; IFS= read -r blk; IFS= read -r gr; IFS= read -r push; IFS= read -r mnt
    IFS= read -r all; IFS='|' read -r sess cgr enr nor ev; } <<< "$hx"

  # (a) C9
  if [ "${#files[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rel="${line%%:*}"; t="${line#*:}"; c="${t%%:*}"; t="${t#*:}"
      t="${t#"${t%%[![:space:]]*}"}"   # leading blanks dropped, no fork
      if [ "$rel" = "NOTICE-AUTO-UPDATE.md" ] && [ "$t" = "$ALLOW_1" ]; then allowed_seen1=1; continue; fi
      if [ "$rel" = "NOTICE-AUTO-UPDATE.md" ] && [ "$t" = "$ALLOW_2" ]; then allowed_seen2=1; continue; fi
      bad_a="$bad_a $rel:$c"
    done <<EOF
$(R="$r" awk '{ sub(/\r$/, "") } tolower($0) ~ /no liability/ { p = FILENAME; if (index(p, ENVIRON["R"] "/") == 1) p = substr(p, length(ENVIRON["R"]) + 2); print p ":" FNR ":" $0 }' "${files[@]}")
EOF
  fi
  [ "$allowed_seen1$allowed_seen2" = "11" ] || bad_a="$bad_a carve-out-phrasings-missing(item9=$allowed_seen1,summary10=$allowed_seen2)"
  if [ -z "$bad_a" ]; then echo "PASS (a) every 'no liability' is a carved-out DRAFTS phrasing"
  else echo "FAIL (a) 'no liability' outside the two carved-out phrasings:$bad_a"; fi

  # (b) NOTICE structure - ONE awk pass (round 2: the 24 grep/tail forks it replaced took ~14 s
  # per run on a loaded machine, and the mutants run this ~50 times)
  # Line 1 of its output: what is missing; line 2: the footer's version number, for (f).
  c=$(awk '
    BEGIN { ns = split("USD 100|gross negligence|not affiliated with or endorsed by Anthropic|## 2a.|### 10.3|### 10.5", S, "|") }
    { sub(/\r$/, ""); last = $0 }
    $0 == "<!-- terms-summary:begin -->" { bx++ }
    index($0, "terms-summary:begin")     { bs++ }
    $0 == "<!-- terms-summary:end -->"   { ex++ }
    index($0, "terms-summary:end")       { es++ }
    index($0, "auto-update-waiver")      { w++ }
    { for (i = 1; i <= ns; i++) if (index($0, S[i])) F[i] = 1 }
    END {
      if (bx + 0 != 1) printf " terms-summary:begin x%d", bx
      if (bs + 0 != 1) printf " terms-summary:begin-substring x%d", bs
      if (ex + 0 != 1) printf " terms-summary:end x%d", ex
      if (es + 0 != 1) printf " terms-summary:end-substring x%d", es
      if (w + 0 != 0)  printf " auto-update-waiver-marker x%d", w
      if (last !~ /^Terms version: [0-9]+$/) printf " last-line=[%s]", last
      for (i = 1; i <= ns; i++) if (!F[i]) printf " missing[%s]", S[i]
      ft = ""; if (last ~ /^Terms version: [0-9]+$/) { ft = last; sub(/^Terms version: /, "", ft) }
      printf "\n%s\n", ft
    }' "$n")
  { IFS= read -r miss; IFS= read -r foot; } <<< "$c"
  if [ -z "$miss" ]; then echo "PASS (b) NOTICE markers, footer and required clauses"
  else echo "FAIL (b) NOTICE:$miss"; fi

  # (c) retired claims, line breaks folded - and (j), round 3: ONE awk over NOTICE, README, the
  # two guides and the skill, folded and lowercased (LC_ALL=C: ASCII only, Hebrew byte for byte).
  # Line 1 of its output is (c), line 2 is (j). (Round 3 merged the three (c) passes and the new
  # (j) pass into this one process; a first draft folded the joined text and reached f2 at 999 s.)
  # gawk stops (fatal, no END) on a missing input file, so only files that exist are passed and the
  # missing ones are named here; a pass that did not reach its END fails both checks (fail-closed).
  miss=""; jmiss=""
  local -a cj=()
  for f in "$n" "$rd" "$ag"; do [ -f "$f" ] || miss="$miss ${f##*/}:MISSING"; done
  for f in "$n:N" "$rd:R" "$ag:A" "$hg:H" "$sk:S" "$ski:I" "$skp:P"; do
    if [ -f "${f%:*}" ]; then cj+=("${f%:*}"); else case "${f##*:}" in R) ;; *) jmiss="$jmiss no-file[${f##*:}]" ;; esac; fi
  done
  [ "${#cj[@]}" -gt 0 ] || cj=(/dev/null)   # never let awk read stdin
  c=$(RET="$RETIRED_C" REQ_J="$REQ_J" FORB_J="$FORB_J" LC_ALL=C awk '
    FNR == 1 { k = FILENAME; sub(/.*\//, "", k)
               # a SKILL.md is keyed by its directory (round 3b: three skills)
               d = FILENAME; sub(/\/SKILL\.md$/, "", d); sub(/.*\//, "", d)
               key = (k == "NOTICE-AUTO-UPDATE.md") ? "N" : (k == "README.md") ? "R" : \
                     (k == "GOVERNANCE-AGENT-GUIDE.md") ? "A" : (k == "GOVERNANCE-HUMAN-GUIDE.md") ? "H" : \
                     (k == "SKILL.md" && d == "live-state-orchestrator") ? "S" : \
                     (k == "SKILL.md" && d == "impact-safe-executor") ? "I" : \
                     (k == "SKILL.md" && d == "plan-and-execute") ? "P" : k
               if (k == "SKILL.md") k = d "/SKILL.md"
               seen[key] = 1; lbl[key] = k }
    # folded PER LINE: gawk gsub over the whole joined text MEASURED 64 s for these 260 KB on
    # this machine (quadratic); per line it is 0.7 s, and the folded text is the same.
    { sub(/\r$/, ""); sub(/^[ \t]*>[ \t]*/, ""); gsub(/[ \t]+/, " "); sub(/^ /, ""); sub(/ $/, "")
      if ($0 != "") T[key] = T[key] tolower($0) " " }
    END {
      out = ""; n = split(ENVIRON["RET"], P, "\n"); split("N R A", K, " ")
      for (j = 1; j <= 3; j++) {
        x = K[j]; if (!(x in seen)) continue
        for (i = 1; i <= n; i++) {
          if (P[i] == "") continue
          p = tolower(P[i]); c = 0; s = T[x]
          while ((q = index(s, p)) > 0) { c++; s = substr(s, q + length(p)) }
          if (c > 0) out = out sprintf(" %s:[%s]x%d", lbl[x], P[i], c)
        }
      }
      print out
      out = ""
      for (m = 1; m <= 2; m++) {
        n = split(ENVIRON[m == 1 ? "REQ_J" : "FORB_J"], P, "\n")
        for (i = 1; i <= n; i++) {
          if (P[i] == "") continue
          x = substr(P[i], 1, 1); q = substr(P[i], 3); p = tolower(q)
          if (!(x in seen)) continue   # named by the caller (no-file[x])
          c = index(T[x], p)
          if (m == 1 && !c) out = out sprintf(" missing[%s:%s]", x, q)
          if (m == 2 && c)  out = out sprintf(" present[%s:%s]", x, q)
        }
      }
      print out
      print "#end"
    }' "${cj[@]}" 2>/dev/null)
  { IFS= read -r t; IFS= read -r p; IFS= read -r s; } <<< "$c"
  if [ "$s" = "#end" ]; then miss="$miss$t"; jmiss="$jmiss$p"
  else miss="$miss awk-pass-did-not-finish"; jmiss="$jmiss awk-pass-did-not-finish"; fi
  if [ -z "$miss" ]; then echo "PASS (c) no retired claim in NOTICE/README/Agent Guide"
  else echo "FAIL (c) retired claim present:$miss"; fi

  # (d) the printed summary
  s=$( ( . "$r/bundle/hooks/governance/consent-lib.sh" && gov_terms_summary "$n" ) 2>/dev/null | tr -d '\r')
  # one awk pass: items (^ ?N. ), non-empty lines, lines over 100 columns, the first number out of
  # sequence. '|' separates the fields (a tab would collapse empty ones under read).
  c=$(printf '%s\n' "$s" | LC_ALL=C awk '
    /./ { lines++ }
    /^ ?[0-9]+\. / { items++; k = $0; sub(/^ /, "", k); sub(/\..*/, "", k)
                     if (k + 0 != items && seq == "") seq = "item" items "=" k }
    length($0) > 100 { wide = wide sprintf(" line%d=%dcols", NR, length($0)) }
    END { printf "%d|%d|%s|%s", items, lines, wide, seq }')
  IFS='|' read -r items lines wide seq <<< "$c"
  miss=""
  [ "$items" -ge 1 ] || miss="$miss no-items(summary empty or unreadable)"
  [ "$items" -le 12 ] || miss="$miss items=$items>12"
  [ -z "$wide" ] || miss="$miss wider-than-100-columns:$wide"
  [ -z "$seq" ] || miss="$miss numbering-broken:$seq"
  if [ -z "$miss" ]; then echo "PASS (d) summary: $items items over $lines lines, none wider than 100 columns"
  else echo "FAIL (d) summary:$miss"; fi

  # (e) README hook table
  miss=""
  [ "${sess:-0}" = "0" ] || miss="$miss SessionEnd-row x$sess"
  [ "${cgr:-0}" -ge 1 ] || miss="$miss no-consent-guard.sh-row"
  if [ -z "$miss" ]; then echo "PASS (e) README hook table: no SessionEnd row, a consent-guard.sh row"
  else echo "FAIL (e) README hook table:$miss"; fi

  # (f) terms version
  tv=""; [ -f "$r/bundle/TERMS-VERSION" ] && IFS= read -r tv < "$r/bundle/TERMS-VERSION"
  tv="${tv//[[:space:]]/}"   # CR and blanks dropped (foot comes from the (b) pass)
  if [ -n "$tv" ] && [ "$tv" = "$foot" ] && [ "$tv" = "$TERMS_PINNED" ]; then
    echo "PASS (f) terms version $tv (TERMS-VERSION = NOTICE footer = pinned)"
  else
    echo "FAIL (f) terms version: TERMS-VERSION=[$tv] NOTICE footer=[$foot] pinned=[$TERMS_PINNED]"
  fi

  # (g) the honest forms NOTICE must state, line breaks folded
  miss=$(PATS="$REQUIRED_G" _fcount "$n" NOTICE absent)
  if [ -z "$miss" ]; then echo "PASS (g) NOTICE states the safeguard, the close commit, the uninstall scope, the version file"
  else echo "FAIL (g) NOTICE:$miss"; fi

  # (h) README round-2 pins, folded and lowercased (so a wrap or a case change does not hide them)
  # (the pieces come from the README pass at the top: folded, lowercased, one per line)
  miss=""
  [ -n "${row// /}" ] || miss="$miss no-uninstall-row"
  for p in 'whole `~/.claude/hooks/`' '`~/.claude/docs/`' 'entire `hooks` section' 'not removed' '`~/.claude/agents/`'; do
    case "$row" in *"$p"*) ;; *) miss="$miss uninstall-row-lacks[$p]" ;; esac
  done
  case "$row" in *'remove all governance files'*) miss="$miss uninstall-row-has[remove all governance files]" ;; esac
  for p in 'whole `~/.claude/hooks/` directory' 'whole `~/.claude/docs/` directory' 'including any hook of your own' \
           'entire `hooks` section' 'including ones you added' 'not removed:' '`~/.claude/agents/`' '`terms-accepted` and `close-push`'; do
    case "$un" in *"$p"*) ;; *) miss="$miss uninstall-section-lacks[$p]" ;; esac
  done
  case "$un" in *'backs up all files before removal. claude.md is not removed'*) miss="$miss uninstall-section-has[the old two-line text]" ;; esac
  for p in 'whole ~/.claude/hooks/' '~/.claude/docs/' 'entire settings.json "hooks"' 'agents/'; do
    case "$blk" in *"$p"*) ;; *) miss="$miss uninstall-line-lacks[$p]" ;; esac
  done
  case "$blk" in *'remove the framework (backed up first'*) miss="$miss uninstall-line-has[remove the framework]" ;; esac
  for p in 'regular expressions' 'a safeguard, not a guarantee' 'names built at run time' 'marker removal inside an interpreter' \
           'can do what you can' 'a read is denied when it runs through an interpreter'; do
    case "$gr" in *"$p"*) ;; *) miss="$miss guard-row-lacks[$p]" ;; esac
  done
  case "$gr" in *'is never blocked'*) miss="$miss guard-row-has[is never blocked]" ;; esac
  for p in 'y/n question' 'default no'; do
    case "$push" in *"$p"*) ;; *) miss="$miss push-section-lacks[$p]" ;; esac
  done
  for p in phrase 'always on'; do
    case "$push" in *"$p"*) miss="$miss push-section-has[$p]" ;; esac
  done
  # round 3 (owner decision 2026-10-01: disclose the marker): the client section names it now
  for p in '.governance-source' 'gov-release.sh' 'does not turn it off' 'with one exception'; do
    case "$push" in *"$p"*) ;; *) miss="$miss push-section-lacks[$p]" ;; esac
  done
  # round 3b: the push carries the branch tip; the marker comes with every run that pushes the tag;
  # deleting it with a `y` recorded leaves push on
  for p in 'every commit of that branch the upstream lacks, including your own local commits that were never pushed' \
           'creates it on every release run from that machine'"'"'s own repository (`gov_repo_path`) that gets as far as pushing the signed tag' \
           'a `y` recorded under the current terms keeps push on'; do
    case "$push" in *"$p"*) ;; *) miss="$miss push-section-lacks[$p]" ;; esac
  done
  case "$push" in *'after every successful release'*) miss="$miss push-section-has[after every successful release]" ;; esac
  case "$mnt" in *'push at session close is always on'*) ;; *) miss="$miss maintainer-section-lacks[push at session close is always on]" ;; esac
  for p in 'or by `gov-release.sh` on every release run that pushes the signed tag' 'a directory of that name does not count' \
           'a plain `touch` is enough' 'its list is not closed' '`close-push.sh --enable` asks nothing and records nothing' \
           'records off while push stays on' 'every run that has pushed the tag then creates' \
           'so a run whose rehearsal fails leaves it too' \
           'a machine on which a run gets as far as pushing the signed tag becomes a source machine'; do
    case "$mnt" in *"$p"*) ;; *) miss="$miss maintainer-section-lacks[$p]" ;; esac
  done
  for p in 'which only the owner creates' 'once, in his own terminal' "\`gov-release.sh\`'s first run" 'the first successful run creates' \
           'after every successful release' 'every successful run' 'run it successfully becomes'; do
    case "$mnt" in *"$p"*) miss="$miss maintainer-section-has[$p]" ;; esac
  done
  for p in 'list of recognised write forms is **not closed**' 'any program, script or write option not on its list'; do
    case "$gr" in *"$p"*) ;; *) miss="$miss guard-row-lacks[$p]" ;; esac
  done
  case "$un" in *'`~/.claude/.governance-source` is not removed either'*) ;; *) miss="$miss uninstall-section-lacks[the marker is not removed]" ;; esac
  for p in '(it is off unless you did)' 'pauses push at session close you turned on'; do
    case "$all" in *"$p"*) miss="$miss readme-has[$p]" ;; esac
  done
  # "always on" only in the maintainer section (the changelog's unrelated "Unchanged and always on:
  # the `bundle/` publish-target block" is the one other use, counted out by name)
  _cnt "$all" 'always on'; n1=$_N; _cnt "$mnt" 'always on'; n2=$_N; _cnt "$all" 'unchanged and always on: the `bundle/`'; n3=$_N
  [ "$n1" = "$((n2 + n3))" ] || miss="$miss always-on-outside-the-maintainer-section"
  _cnt "$all" phrase; n1=$_N; _cnt "$all" passphrase; n2=$_N
  [ "$n1" = "$n2" ] || miss="$miss phrase-in-README(x$((n1 - n2)))"
  if [ -z "$miss" ]; then echo "PASS (h) README: uninstall scope (row, section, code line), the guard row's limits, push y/N for clients, always-on only for the maintainer, no phrase"
  else echo "FAIL (h) README:$miss"; fi

  # (i) README options table and the guard row's events
  miss=""
  [ "${enr:-0}" = "0" ] || miss="$miss enable-close-push-row x$enr"
  [ "${nor:-0}" -ge 1 ] || miss="$miss no-no-close-push-row"
  t="$ev"   # the guard row's event column, raw (case-sensitive: "Read")
  case "$t" in *Read*) ;; *) miss="$miss guard-row-events-lack-Read[${t:-no row}]" ;; esac
  if [ -z "$miss" ]; then echo "PASS (i) README: no --enable-close-push row, a --no-close-push row, guard row events include Read"
  else echo "FAIL (i) README:$miss"; fi

  # (j) round 3 - computed in the (c) pass above (a missing file is named, never skipped)
  if [ -z "$jmiss" ]; then echo "PASS (j) rounds 3/3b: marker disclosed, scanner, uninstall, own-file, branch-tip push, marker timing, guides, skills, README rows"
  else echo "FAIL (j) round 3:$jmiss"; fi
}

# ── 1. The real tree: every check passes ────────────────────────────────────────────────────────
echo "[1] the real tree"
REAL=$(run_checks "$ROOT")
printf '%s\n' "$REAL" | sed 's/^/    /'
for _id in a b c d e f g h i j; do
  has "($_id) passes on the real tree" "$REAL" "PASS ($_id)"
done
hasnt "no check fails on the real tree" "$REAL" "FAIL ("

# ── 2. Mutants: each check must fire ────────────────────────────────────────────────────────────
SBX=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/gov-terms-text-$$")
mkdir -p "$SBX"
trap 'rm -rf "$SBX"' EXIT
# fresh -> a new copy of exactly the files run_checks reads, in $SBX/t
fresh() {
  # Round 3: one tar pipe for all ten files, paths kept (it was five cp's; a fork is ~0.4 s on a
  # loaded machine and fresh runs ~65x). A missing source file is simply absent from the copy.
  rm -rf "$SBX/t"; mkdir -p "$SBX/t"
  (cd "$ROOT" && exec tar -cf - $FRESH_FILES 2>/dev/null) | tar -xf - -C "$SBX/t" 2>/dev/null
}
FRESH_FILES="NOTICE-AUTO-UPDATE.md README.md install.sh bundle/TERMS-VERSION
  bundle/docs/GOVERNANCE-AGENT-GUIDE.md bundle/docs/GOVERNANCE-HUMAN-GUIDE.md
  bundle/skills/live-state-orchestrator/SKILL.md bundle/skills/impact-safe-executor/SKILL.md
  bundle/skills/plan-and-execute/SKILL.md bundle/hooks/governance/gov-update.sh
  bundle/hooks/governance/close-push.sh bundle/hooks/governance/consent-lib.sh"
T="$SBX/t"; N="$T/NOTICE-AUTO-UPDATE.md"; R="$T/README.md"
# mut <label> <check id> <expected text> -> run the checks on the mutated copy, assert that check
# FAILS with that text and that every OTHER check still passes (the mutant hits one thing only).
mut() {
  local o _id
  o=$(run_checks "$T"); _MO="$o"   # kept, so a follow-up assertion on the same mutant needs no second run
  has "$1: ($2) fires" "$o" "FAIL ($2)"
  has "$1: ($2) names it" "$o" "$3"
  for _id in a b c d e f g h i j; do
    [ "$_id" = "$2" ] && continue
    has "$1: ($_id) unaffected" "$o" "PASS ($_id)"
  done
}
# insert_before_end <file> <line> -> the line goes just above the summary's end marker
insert_before_end() { awk -v ins="$2" '$0 == "<!-- terms-summary:end -->" { print ins } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

echo "[2] mutants (must fire)"
# the footer must stay last, so the bare sentence goes above it
fresh; awk '/^Terms version:/ { print "The maintainer accepts no liability for anything."; print ""; } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "a1 bare sentence in NOTICE" a "NOTICE-AUTO-UPDATE.md:"
fresh; printf '# the maintainer accepts NO LIABILITY here\n' >> "$T/bundle/hooks/governance/close-push.sh"
mut "a2 bare sentence in close-push.sh (scripts are scanned, any case)" a "close-push.sh:"
fresh; sed 's/No liability as far as the law allows; section 10.1 says what the law/No liability; section 10.1 says what the law/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "a3 summary item 10 loses its carve-out" a "summary10=0"
fresh; printf '| x | no liability | y |\n' >> "$R"
mut "a4 bare phrase in README" a "README.md:"

fresh; awk '{ print } $0 == "<!-- terms-summary:begin -->" { print "<!-- terms-summary:begin -->" }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b1 duplicated begin marker" b "terms-summary:begin x2"
fresh; awk '/^### 10.3/ { print "<!-- auto-update-waiver:begin -->"; print "<!-- auto-update-waiver:end -->"; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b2 an auto-update waiver block" b "auto-update-waiver-marker x2"
fresh; sed 's/USD 100/USD 50/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b3 the USD 100 cap removed" b "missing[USD 100]"
fresh; sed 's/^### 10\.5 /### 10.6 /' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b4 section 10.5 renumbered" b "missing[### 10.5]"
fresh; sed 's/not affiliated with or endorsed by Anthropic/an Anthropic product/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b5 the non-affiliation removed" b "missing[not affiliated with or endorsed by Anthropic]"
fresh; sed 's/gross negligence/negligence/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "b6 the gross-negligence carve-out removed" b "missing[gross negligence]"

# (b) last line and (f) share the footer; a trailing line breaks both, so assert (b) separately.
fresh; printf 'trailing text\n' >> "$N"
_o=$(run_checks "$T")
has "b7 a line after the footer: (b) fires" "$_o" "FAIL (b) NOTICE: last-line=[trailing text]"
has "b7 a line after the footer: (f) fires too (the footer is gone)" "$_o" "FAIL (f)"

fresh; printf '\nSet GOV_AUTO_UPDATE=0 to pause.\n' >> "$R"
mut "c1 GOV_AUTO_UPDATE in README" c "README.md:[GOV_AUTO_UPDATE]x1"
fresh; awk '/^## 4\./ { print "It runs in a throw-away sandbox."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "c2 throw-away sandbox in NOTICE" c "NOTICE-AUTO-UPDATE.md:[throw-away sandbox]x1"
fresh; awk '/^## 4\./ { print "The framework Installs Itself."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "c3 installs itself in NOTICE (any case)" c "NOTICE-AUTO-UPDATE.md:[installs itself]x1"
fresh; printf '\nkept on the maintainer'"'"'s machine without a passphrase, so that releases can be signed without a human typing one.\n' >> "$R"
mut "c4 the old unattended-signing sentence in README" c "without a passphrase, so that releases can be signed without a human"
# F5 (round-1 review): the retired D1/D2/D5/D7 claims, several wrapped over two lines as they were
AG="$T/bundle/docs/GOVERNANCE-AGENT-GUIDE.md"
fresh; awk '/^## 4\./ { print "   authorised to bind. An AI agent cannot accept them"; print "   for you."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "c5 'cannot accept them for you' wrapped over two lines in NOTICE" c "NOTICE-AUTO-UPDATE.md:[cannot accept them for you]x1"
fresh; awk '/^## 4\./ { print "Terms are never accepted on your behalf — not by the software, and not by an AI"; print "agent."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "c6 the 10.4 'never accepted on your behalf' sentence, wrapped" c "NOTICE-AUTO-UPDATE.md:[never accepted on your behalf — not by the software, and not by an AI agent]x1"
fresh; printf '\nWithout a terminal pass --enable-close-push to turn it on.\n' >> "$AG"
mut "c7 the removed --enable-close-push flag in the Agent Guide" c "GOVERNANCE-AGENT-GUIDE.md:[--enable-close-push]x1"
fresh; printf '\nAt session start it compares the versions; it downloads nothing.\n' >> "$R"
mut "c8 'it downloads nothing' in README" c "README.md:[it downloads nothing]x1"
fresh; printf '\n`gov-update.sh` is run by no\nhook.\n' >> "$AG"
mut "c9 'run by no hook' wrapped, in the Agent Guide" c "GOVERNANCE-AGENT-GUIDE.md:[run by no hook]x1"
fresh; printf '\noff (terms changed to v2; re-accept: gov-update.sh --accept-terms)\n' >> "$R"
mut "c10 the old stale-terms reason in README" c "README.md:[re-accept: gov-update.sh --accept-terms]x1"
fresh; printf '\nThe scripts refuse the command. Refused inside an AI-agent\nsession.\n' >> "$R"
mut "c11 'Refused inside an AI-agent session' wrapped, in README" c "README.md:[Refused inside an AI-agent session]x1"

fresh; sed 's/has no switch of its own/has no off switch/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "g1 the close-commit sentence removed" g "missing[has no switch of its own]"
fresh; sed 's/safeguard/protection/g' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "g2 'safeguard' gone from NOTICE" g "missing[safeguard]"
fresh; sed 's/not a guarantee/a promise/g; s/not guarantees/promises/g' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "g3 'not a guarantee' gone from NOTICE" g "missing[not a guarantee]"
fresh; sed 's/WHOLE `~\/\.claude\/hooks\/`/`~\/.claude\/hooks\/`/g; s/whole `~\/\.claude\/hooks\/`/`~\/.claude\/hooks\/`/g' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "g4 the uninstall scope loses 'whole'" g "missing[whole \`~/.claude/hooks/\`]"
fresh; sed 's/published version number/published version/g' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "g5 what the version check downloads is no longer named" g "missing[published version number]"
# round 2 / owner decision 2026-10-01: the typed phrase and every "an agent cannot" form are retired
fresh; awk '/^## 4\./ { print "Turn it on by typing `I ENABLE PUSH AT SESSION CLOSE`."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "c12 the retired push phrase back in NOTICE" c "NOTICE-AUTO-UPDATE.md:[I ENABLE PUSH AT SESSION CLOSE]x1"
fresh; printf '\nTurning it on needs your terminal and the typed\nphrase.\n' >> "$AG"
mut "c13 'typed phrase' wrapped, in the Agent Guide" c "GOVERNANCE-AGENT-GUIDE.md:[typed phrase]x1"
fresh; printf '\nThe scripts refuse: an AI agent cannot accept the terms or turn this on.\n' >> "$R"
mut "c14 an 'AI agent cannot accept' sentence in README" c "README.md:[agent cannot]x1"
fresh; printf '\nA session can'"'"'t accept\nthe terms for the user.\n' >> "$R"
mut "c15 a \"can't accept\" sentence wrapped, in README" c "README.md:[can't accept]x1"

# (h) README round-2 pins: each one can fail on its own
fresh; awk 'index($0, "| `--uninstall` |") == 1 { print "| `--uninstall` | Remove all governance files (backs up before removal) |"; next } { print }' "$ROOT/README.md" > "$R"
mut "h1 the --uninstall row back to 'Remove all governance files'" h "uninstall-row-has[remove all governance files]"
has "h1: the row names what it lacks" "$_MO" "uninstall-row-lacks[whole \`~/.claude/hooks/\`]"
fresh; awk '/^## Uninstall/ { on = 1 } on && /^## Testing/ { on = 0 } { if (on) sub(/ \(a manual decision\) and `~\/\.claude\/agents\/`/, " (a manual decision)"); print }' "$ROOT/README.md" > "$R"
mut "h2 the Uninstall section no longer says agents/ stays" h "uninstall-section-lacks[\`~/.claude/agents/\`]"
fresh; awk '/^## Uninstall/ { on = 1 } on && /^## Testing/ { on = 0 } { if (on) sub(/including any hook of your own you put there/, "your files"); print }' "$ROOT/README.md" > "$R"
mut "h3 the Uninstall section drops 'including any hook of your own'" h "uninstall-section-lacks[including any hook of your own]"
fresh; awk '/^bash install\.sh --uninstall +#/ { print "bash install.sh --uninstall  # remove the framework (backed up first; your recorded choices are kept)"; skip = 2; next } skip > 0 { skip--; next } { print }' "$ROOT/README.md" > "$R"
mut "h4 the --uninstall code line back to 'remove the framework'" h "uninstall-line-has[remove the framework]"
fresh; awk 'index($0, "| `consent-guard.sh` |") > 0 { sub(/ \(v2\.0\.0\) \|$/," Reading the records, and searching the scripts for these flags, is never blocked. (v2.0.0) |") } { print }' "$ROOT/README.md" > "$R"
mut "h5 the guard row says reads are never blocked again" h "guard-row-has[is never blocked]"
fresh; awk 'index($0, "| `consent-guard.sh` |") > 0 { sub(/, marker removal inside an interpreter \([^)]*\)/, "") } { print }' "$ROOT/README.md" > "$R"
mut "h6 the guard row drops marker removal inside an interpreter" h "guard-row-lacks[marker removal inside an interpreter]"
fresh; awk 'index($0, "| `consent-guard.sh` |") > 0 { gsub(/names built at run time/, "computed names") } { print }' "$ROOT/README.md" > "$R"
mut "h7 the guard row drops names built at run time" h "guard-row-lacks[names built at run time]"
fresh; awk 'index($0, "| `consent-guard.sh` |") > 0 { gsub(/can do what you can/, "may misbehave") } { print }' "$ROOT/README.md" > "$R"
mut "h8 the guard row drops the L1 sentence" h "guard-row-lacks[can do what you can]"
fresh; awk '/^## Push at session close/ { print; print ""; print "You type the push phrase when asked."; next } { print }' "$ROOT/README.md" > "$R"
mut "h9 a phrase back in the Push section" h "push-section-has[phrase]"
has "h9: the whole-README phrase count fires too" "$_MO" "phrase-in-README(x1)"
fresh; awk '/^## Push at session close/ { print; print ""; print "On the maintainer'"'"'s machine it is always on."; next } { print }' "$ROOT/README.md" > "$R"
mut "h10 the maintainer's always-on leaks into the client Push section" h "push-section-has[always on]"
has "h10: always-on outside the maintainer section fires too" "$_MO" "always-on-outside-the-maintainer-section"
fresh; sed 's/\*\*On the maintainer'"'"'s machine, push at session close is always on\*\*/**On the maintainer'"'"'s machine, push at session close is on**/' "$ROOT/README.md" > "$R"
mut "h11 the maintainer section loses 'always on'" h "maintainer-section-lacks[push at session close is always on]"
fresh; awk '/^## Push at session close/ { on = 1 } on && /^## Release/ { on = 0 } { if (on) gsub(/one y\/N question/, "a question"); print }' "$ROOT/README.md" > "$R"
_o=$(run_checks "$T")
has "h12 the Push section loses 'y/N question' from install.sh's sentence: still pinned by --enable's" "$_o" "PASS (h)"
fresh; awk '/^## Push at session close/ { on = 1 } on && /^## Release/ { on = 0 } { if (on) gsub(/y\/N question/, "question"); print }' "$ROOT/README.md" > "$R"
mut "h13 the Push section names no y/N question at all" h "push-section-lacks[y/n question]"
# round 3: the client Push section without its exception paragraph and its opener's pointer
fresh; awk '/^## Push at session close/ { on = 1 } on && /^## Release/ { on = 0 }
            on { sub(/ — with one exception, at the end of this section\./, ".") }
            on && /^\*\*The exception: a file named/ { skip = 1 } skip && /^$/ { skip = 0 } !skip { print }' "$ROOT/README.md" > "$R"
mut "h14 the Push section loses the marker exception (the old client-only wording)" h "push-section-lacks[.governance-source]"
for _p in 'gov-release.sh' 'does not turn it off' 'with one exception'; do
  has "h14: names push-section-lacks[$_p]" "$_MO" "push-section-lacks[$_p]"
done
# round 3: the old maintainer wording ("only the owner creates - once - or the first run"), the
# guard row and Uninstall section without the new sentences, and the old A13 kill-switch comment
fresh; sed -e 's/Every run that has pushed the tag then creates/The first successful run creates/' \
           -e 's/or by `gov-release.sh` on every release run that pushes the$/or by `gov-release.sh` after every successful release,/' \
           -e 's/^so a run whose rehearsal fails leaves it too/so every successful run leaves it/' \
           -e 's/^machine on which a run gets as far as pushing the signed tag becomes a source machine/machine that does run it successfully becomes a source machine/' \
           -e 's/a directory of that name does not count/a directory counts/' \
           -e 's/and a plain `touch` is enough/and so on/' \
           -e 's/its list is not closed/its list is long/' \
           -e 's/asks nothing and records nothing/asks nothing/' \
           -e 's/records OFF while push stays ON/records OFF/' \
           -e 's/list of recognised write forms is \*\*not closed\*\*/list of recognised write forms is closed/' \
           -e 's/any program, script or write option not on its list, //' \
           -e 's/^is not removed either (see/is kept (see/' "$ROOT/README.md" \
  | awk '{ print } /^\*\*On the maintainer.s machine, push at session close is always on\*\*/ {
           print "The machine is the one marked by `~/.claude/.governance-source`, which only the owner creates —"
           print "once, in his own terminal (`touch ~/.claude/.governance-source`), or by `gov-release.sh`'"'"'s first"
           print "run." }' > "$R"
printf '\nGOV_CLOSE_PUSH=0   # pause push at session close you turned on (it is off unless you did)\n' >> "$R"
printf '\n| `GOV_CLOSE_PUSH=0` | pauses push at session close you turned on |\n' >> "$R"
mut "h15 the old maintainer wording and the unscoped guard row, Uninstall and kill-switch lines" h "maintainer-section-has[the first successful run creates]"
for _p in 'maintainer-section-lacks[or by `gov-release.sh` on every release run that pushes the signed tag]' \
          'maintainer-section-lacks[every run that has pushed the tag then creates]' \
          'maintainer-section-lacks[so a run whose rehearsal fails leaves it too]' \
          'maintainer-section-lacks[a machine on which a run gets as far as pushing the signed tag becomes a source machine]' \
          'maintainer-section-has[after every successful release]' 'maintainer-section-has[every successful run]' \
          'maintainer-section-has[run it successfully becomes]' \
          'maintainer-section-lacks[a directory of that name does not count]' 'maintainer-section-lacks[a plain `touch` is enough]' \
          'maintainer-section-lacks[its list is not closed]' 'maintainer-section-lacks[`close-push.sh --enable` asks nothing and records nothing]' \
          'maintainer-section-lacks[records off while push stays on]' 'maintainer-section-has[which only the owner creates]' \
          'maintainer-section-has[once, in his own terminal]' "maintainer-section-has[\`gov-release.sh\`'s first run]" \
          'guard-row-lacks[list of recognised write forms is **not closed**]' \
          'guard-row-lacks[any program, script or write option not on its list]' \
          'uninstall-section-lacks[the marker is not removed]' 'readme-has[(it is off unless you did)]' \
          'readme-has[pauses push at session close you turned on]'; do
  has "h15: names $_p" "$_MO" "$_p"
done
# round 3b: the client Push section back to "the session's commits" and "after every successful
# release", without the `y`-recorded caveat
fresh; sed -e 's/^upstream — every commit of that branch the upstream lacks, including your own local commits that$/upstream —/' \
           -e 's/creates it on every release run from that machine.s$/creates it after every successful release made from that machine'"'"'s/' \
           -e 's/ (a `y` recorded under the current terms keeps push on: run$/ (run/' "$ROOT/README.md" > "$R"
mut "h16 the Push section back to the round-3 wording (session commits, successful release)" h "push-section-has[after every successful release]"
for _p in 'push-section-lacks[every commit of that branch the upstream lacks, including your own local commits that were never pushed]' \
          'push-section-lacks[creates it on every release run from that machine'"'"'s own repository (`gov_repo_path`) that gets as far as pushing the signed tag]' \
          'push-section-lacks[a `y` recorded under the current terms keeps push on]'; do
  has "h16: names $_p" "$_MO" "$_p"
done

fresh; awk '{ print } index($0, "| `--no-close-push` |") == 1 { print "| `--enable-close-push` | Turn push at session close on |" }' "$ROOT/README.md" > "$R"
_o=$(run_checks "$T")
has "i1 the --enable-close-push row is back: (i) fires" "$_o" "FAIL (i) README: enable-close-push-row x1"
has "i1 the --enable-close-push row is back: (c) fires too (a retired flag)" "$_o" "README.md:[--enable-close-push]x1"
fresh; grep -v -F '| `--no-close-push` |' "$ROOT/README.md" > "$R"
mut "i2 the --no-close-push row removed" i "no-no-close-push-row"
fresh; sed 's/^| PreToolUse (Edit\/Write, Bash, PowerShell, Read) | `consent-guard\.sh` |/| PreToolUse (Edit\/Write, Bash, PowerShell) | `consent-guard.sh` |/' "$ROOT/README.md" > "$R"
mut "i3 the guard row loses the Read event" i "guard-row-events-lack-Read[ PreToolUse (Edit/Write, Bash, PowerShell) ]"

fresh; insert_before_end "$N" "11. $(printf '%0101d' 0 | tr 0 x)"
mut "d1 a summary line wider than 100 columns" d "wider-than-100-columns"
fresh; insert_before_end "$N" "11. extra."; insert_before_end "$N" "12. extra."; insert_before_end "$N" "13. extra."
mut "d2 thirteen summary items" d "items=13>12"
fresh; insert_before_end "$N" "12. out of order."
mut "d3 summary numbering skips a number" d "numbering-broken:item11=12"
fresh; awk '{ if ($0 == "<!-- terms-summary:begin -->") skip = 1; if (!skip) print; if ($0 == "<!-- terms-summary:end -->") skip = 0 }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
_o=$(run_checks "$T")
has "d4 no summary at all: (d) fires" "$_o" "FAIL (d) summary: no-items"

fresh; awk '{ print } index($0, "| SessionStart | `pre-session.sh`") == 1 { print "| SessionEnd | `gov-update.sh --apply-at-session-end` | back again |" }' "$ROOT/README.md" > "$R"
mut "e1 a SessionEnd row in the hook table" e "SessionEnd-row x1"
# (e) and (i) both read the guard row; without it both fire, so assert each by its text.
fresh; grep -v -F '| `consent-guard.sh` |' "$ROOT/README.md" > "$R"
_o=$(run_checks "$T")
has "e2 the consent-guard.sh row removed: (e) fires" "$_o" "FAIL (e) README hook table: no-consent-guard.sh-row"
has "e2 the consent-guard.sh row removed: (i) fires too (no row, no Read event)" "$_o" "guard-row-events-lack-Read[no row]"
has "e2 the consent-guard.sh row removed: (h) fires too (the row's limits are gone)" "$_o" "guard-row-lacks[regular expressions]"
for _id in a b c d f g j; do has "e2: ($_id) unaffected" "$_o" "PASS ($_id)"; done

fresh; printf '2\n' > "$T/bundle/TERMS-VERSION"
mut "f1 TERMS-VERSION raised alone" f "TERMS-VERSION=[2] NOTICE footer=[1]"
fresh; sed 's/^Terms version: 1$/Terms version: 2/' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
mut "f2 NOTICE footer raised alone" f "TERMS-VERSION=[1] NOTICE footer=[2]"

# (j) round 3. j1: every new NOTICE sentence broken AND the old ones back (above section 4, so the
# footer stays last) -> every REQ_J/FORB_J pattern for N is named on its own.
OLD_N='push at session close is OFF unless you turn it on.

This document tells you
**(a) Push at session close — OFF unless you turn it on (section 10.3).**
other confidential content. The personal-data scanner finds only the names you listed in
`~/.claude/.pii-names`.
Turn it off: `bash ~/.claude/hooks/governance/close-push.sh --disable`. Pause it: `GOV_CLOSE_PUSH=0`
- **Push at session close — only when you turned it on.** `git fetch` and `git push` to your own
- **Turn push at session close off:** `bash ~/.claude/hooks/governance/close-push.sh --disable`;
  any hook or document of your own you put there — the framework'"'"'s skills, and the ENTIRE `hooks`
   answer, `y`, typed in your own terminal. These are safeguards, not guarantees: anything that
5. **Push at session close is OFF** unless you turn it on under section 10.3.
6. **Steps taken
asks the same question. There is no flag and no variable for it: turning it on always needs a
terminal and your answer.
Turn it off at any time: `close-push.sh --disable`; pause it: `GOV_CLOSE_PUSH=0`; for one
machine before you accept. Push at session close goes back to off. To turn it on again: accept the
    default No). A push cannot be taken back.
 6. In a governed project'
fresh; sed -e 's/where it is ON without asking (section 10\.3)/where it may be on (section 10.3)/' \
           -e 's/(section 10\.3, which also states the one$/(section 10.3, which states the one/' \
           -e 's/scanner recognises fixed shapes/scanner knows some shapes/' \
           -e 's/A name you did not list, client data and other confidential content can pass it/Other content can pass it/' \
           -e 's/`--disable` alone does not turn it off: run it and also delete that$/delete that file instead — `--disable` does not turn it off there/' \
           -e 's/^commit of that branch the upstream does not have yet, including/commit of that branch, including/' \
           -e 's/carrying every commit of the current branch that the remote$/carrying the commits of the closing session/' \
           -e 's/refuse to record an acceptance when they detect an$/refuse when they detect an/' \
           -e 's/ — a re-install on a machine whose$//' \
           -e 's/^   current terms are already accepted records no acceptance and is not refused — and turning push$/   and turning push/' \
           -e 's/only when it is on: you turned it on, or the machine has the file$/only when it is on, or the file/' \
           -e 's/named\. Two exceptions: on a machine with no local-modification$/named. One note: on a machine with no local-modification/' \
           -e 's/your file is replaced, after being backed up/your file is kept/' \
           -e 's/(on a machine that has the file `~\/\.claude\/\.governance-source`, run it and also delete/(delete/' \
           -e 's/skills, and, when `node` is$/skills, and/' \
           -e 's/Without `node` that section is left in place, and$/That section is gone, and/' \
           -e 's/It does not remove `~\/\.claude\/\.governance-source` (section 10\.3)\.//' \
           -e 's/ — except on a machine that has the file named in$//' \
           -e 's/which turns it ON without asking/which matters/' \
           -e 's/no variable for it: on a machine without the file$/no variable for it: the file/' \
           -e 's/(where the file of the next paragraph exists,$/(/' \
           -e 's/^\*\*The one exception: a file named/**A file named/' \
           -e 's/no question is asked and no record is needed/it is on/' \
           -e 's/^does not turn it off\. The file marks/does turn it off. The file marks/' \
           -e 's/creates it on every release run made from that machine.s own$/creates it after every successful release made from that machine'"'"'s own/' \
           -e 's/To check: `ls -l ~\/\.claude\/\.governance-source`/To check: look/' \
           -e 's/To return to the rule above,$/To go back,/' \
           -e 's/as it can do anything else you can/sometimes/' \
           -e 's/refuses only the command forms it recognises/refuses those commands/' \
           -e 's/where that file exists it stays on (10\.3)\. //' \
           -e 's/(gov-release\.sh creates it), it is ON/it is ON/' "$ROOT/NOTICE-AUTO-UPDATE.md" \
  | OLD="$OLD_N" awk '/^## 4\./ { print ENVIRON["OLD"]; print "" } { print }' > "$N"
mut "j1 the NOTICE back to its round-2b wording (marker undisclosed, old scanner sentence)" j "missing[N:"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j1: names missing[$_p]" "$_MO" "missing[$_p]"
done <<< "$(printf '%s\n' "$REQ_J" | grep '^N|' | sed 's/^N|/N:/')"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j1: names present[$_p]" "$_MO" "present[$_p]"
done <<< "$(printf '%s\n' "$FORB_J" | grep '^N|' | sed 's/^N|/N:/')"
hasnt "j1: no file reported missing" "$_MO" "no-file["
# j2: the Human Guide, the Agent Guide and the skill back to their round-2b wording.
fresh; HG="$T/bundle/docs/GOVERNANCE-HUMAN-GUIDE.md"; SK="$T/bundle/skills/live-state-orchestrator/SKILL.md"
sed -e 's/חוסם רק את הצורות שהוא מזהה/חוסם אותן/' -e 's/`GOV_GIT_DESTRUCTIVE_OK=1`/override/' \
    -e 's/עוברים אותו/נחסמים/' -e 's/כבוי, עד שאתה מדליק אותו/דולק/' \
    -e 's/`~\/\.claude\/\.governance-source`/a file/g' -e 's/ls -l ~\/\.claude\/\.governance-source/ls/' \
    -e 's/יוצר את הקובץ הזה בכל הרצה שמגיעה עד דחיפת ה-tag החתום/יוצר את הקובץ הזה אחרי כל release מוצלח/' \
    -e 's/אם רשמת קודם `y` (תחת אותה גרסת תנאים), ה-push נשאר דולק/אם רשמת y/' \
    -e 's/ה-push שולח כל commit בענף שעוד לא נמצא ב-upstream/ה-push שולח/' -e 's/זה שומר, לא ערובה/זה חוסם הכל/' \
    -e 's/ואם השומר עצמו נתקל בשגיאה פנימית הוא מעביר את הפעולה/ושגיאה עוצרת הכל/' \
    "$ROOT/bundle/docs/GOVERNANCE-HUMAN-GUIDE.md" > "$HG"
printf '%s\n' '- **פעולות git הרסניות** — push --force, reset --hard. תמיד דורשות אישור, ו-`deny-git-bypass.sh` חוסם אותן.' \
  '- **push בסגירת סשן** — כבר לא דורש אותך. בסוף סשן Claude עושה commit לקבצים שלו' \
  'מגרסה 2.0.0, בפרויקט עם governance, Claude לא יכול לערוך קבצים, לשלוח הודעות' >> "$HG"
sed -e 's/or by `gov-release.sh` on EVERY release run from that$/or by `gov-release.sh` after EVERY successful release from that/' \
    -e 's/so a run whose rehearsal then fails leaves it too/so it is there/' \
    -e 's/ — and deleting it turns push off only when no$/./' \
    -e 's/^human.s acts\. The scripts refuse to record an acceptance or an ON when they detect an AI-agent$/human'"'"'s acts. The scripts refuse when they detect an AI-agent/' \
    -e 's/^session (a re-install whose current terms are already accepted is not refused and records no$/session (/' \
    -e 's/upstream — every commit of that branch the upstream lacks, the$/upstream — the/' \
    -e 's/^directory of that name does not count)/directory counts too)/' \
    -e 's/`close-push.sh --enable` asks nothing and records nothing/`close-push.sh --enable` asks/' \
    -e 's/records OFF while push stays ON/turns it OFF/' -e 's/list of write forms is not$/list of write forms is/' \
    "$ROOT/bundle/docs/GOVERNANCE-AGENT-GUIDE.md" > "$AG"
printf '%s\n' "maintainer's machine (a regular FILE \`~/.claude/.governance-source\`, created only by the owner in" \
  "his own terminal or by gov-release.sh's first run) it is always on." \
  'pauses a push the human turned on, everywhere, without changing their choice' >> "$AG"
sed -e 's/ — on a client, the human/ — the human/' \
    -e 's/where the regular file `~\/\.claude\/\.governance-source` exists/somewhere/' \
    -e 's/never accept terms, yourself; never create or delete that file$/never accept terms, yourself;/' \
    -e 's/creates it on every release run that gets as far as pushing the signed tag, even one whose$/creates it after every successful release (even one whose/' \
    -e 's/(the push carries every commit of that branch the upstream lacks, the human.s own$/(the human'"'"'s own/' \
    "$ROOT/bundle/skills/live-state-orchestrator/SKILL.md" > "$SK"
printf '%s\n' "2. It pushes only when push at session close is on on this machine — the human's recorded choice;" \
  '   otherwise it prints `SKIP`' \
  '   close continues. Never turn it on, never create or delete that file, and never accept terms,' >> "$SK"
# round 3b: impact-safe-executor and plan-and-execute back to their round-3 wording (client case only,
# "the session's commits", no marker sentence)
SKI="$T/bundle/skills/impact-safe-executor/SKILL.md"; SKP="$T/bundle/skills/plan-and-execute/SKILL.md"
sed -e 's/An ordinary push of the current branch to its EXISTING upstream — it carries every commit of that branch the upstream lacks, the human.s own unpushed local commits included, not only this session.s — is allowed/An ordinary push of the session'"'"'s commits to the current branch'"'"'s EXISTING upstream is allowed/' \
    -e 's/ — on a client, the human.s recorded choice (`y` at install or `close-push.sh --enable` in their own terminal); on a machine where the regular file `~\/\.claude\/\.governance-source` exists (the maintainer.s), always, with no question and no record, whatever choice is recorded (unless `GOV_CLOSE_PUSH=0` pauses it);/ — the human'"'"'s recorded choice;/' \
    -e 's/never accept terms, yourself; never create or delete that file either:/never accept terms, yourself:/' \
    "$ROOT/bundle/skills/impact-safe-executor/SKILL.md" > "$SKI"
sed -e 's/the human.s recorded choice, or$/the human'"'"'s recorded choice;/' \
    -e 's/^   always on the maintainer.s machine (the file `~\/\.claude\/\.governance-source` exists; `GOV_CLOSE_PUSH=0` pauses it); otherwise/   otherwise/' \
    -e 's/never accept terms, yourself; never create or delete that file either: those are the$/never accept terms, yourself: those are the/' \
    -e 's/^   human.s acts\. The push carries every commit of the branch its upstream lacks, the human.s own$/   human'"'"'s acts./' \
    "$ROOT/bundle/skills/plan-and-execute/SKILL.md" > "$SKP"
mut "j2 the Human Guide, Agent Guide and the three skills back to their earlier wording" j "missing[H:"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j2: names missing[$_p]" "$_MO" "missing[$_p]"
done <<< "$(printf '%s\n' "$REQ_J" | grep -E '^[HASIP]\|' | sed 's/^\([HASIP]\)|/\1:/')"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j2: names present[$_p]" "$_MO" "present[$_p]"
done <<< "$(printf '%s\n' "$FORB_J" | grep -E '^[HASIP]\|' | sed 's/^\([HASIP]\)|/\1:/')"
hasnt "j2: the NOTICE pins are untouched by it" "$_MO" "[N:"
hasnt "j2: the README pins are untouched by it" "$_MO" "[R:"
# j4 (round 3b): README rows outside the (h) sections back to their round-3 wording
fresh; sed -e 's/Refused when an AI-agent session is detected and the current terms are not yet accepted on this machine (a re-install whose current terms are already accepted is not refused and records no acceptance; a safeguard/Refused when an AI-agent session is detected (a safeguard/' \
           -e 's/the installer and `gov-update.sh --accept-terms`$/the installer refuses when it detects one/' \
           -e 's/^refuse to record an acceptance when they detect one (a re-install whose current terms are already$/(a/' \
           -e 's/and every release run of it that gets as far as pushing the signed tag (even one whose$/and every successful release it makes (even one whose/' \
           -e 's/push stays on until that file is deleted too/only deleting that file does/' \
           -e 's/refuse to record an acceptance or an$/refuse when they detect an AI-agent/' \
           -e 's/^  ON when they detect an AI-agent session (a re-install whose current terms are already accepted is$/  session (/' \
           -e 's/creates the file on every$/creates the file after every/' \
           -e 's/^  release run that gets as far as pushing the signed tag (2026-10-01/  successful release (2026-10-01/' \
           "$ROOT/README.md" > "$R"
mut "j4 README rows back to their round-3 wording (refusal unscoped, successful release)" j "missing[R:"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j4: names missing[$_p]" "$_MO" "missing[$_p]"
done <<< "$(printf '%s\n' "$REQ_J" | grep '^R|' | sed 's/^R|/R:/')"
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  has "j4: names present[$_p]" "$_MO" "present[$_p]"
done <<< "$(printf '%s\n' "$FORB_J" | grep '^R|' | sed 's/^R|/R:/')"
hasnt "j4: no other file's pins fire" "$_MO" "[N:"
# j3: a missing file is named, never skipped
fresh; rm -f "$T/bundle/skills/live-state-orchestrator/SKILL.md"
mut "j3 the skill file missing" j "no-file[S]"

# ── 3. A benign edit must not fire ──────────────────────────────────────────────────────────────
echo "[3] benign edit (must not fire)"
fresh; awk '/^## 4\./ { print "Liability is limited as section 10.1 says; the version check is not automatic updating."; print "The scanner also finds the names you listed, and more; push at session close stays on there."; print "" } { print }' "$ROOT/NOTICE-AUTO-UPDATE.md" > "$N"
printf '\nהשומר `deny-git-bypass.sh` חוסם אותן כשהוא מזהה אותן; push בסגירת סשן כבר לא תלוי בזה.\n' >> "$T/bundle/docs/GOVERNANCE-HUMAN-GUIDE.md"
printf '\nA note on liability: see NOTICE section 10.1.\n' >> "$R"
printf '\nThere is no flag for it: close-push.sh --enable asks in your terminal (a safeguard only).\n' >> "$R"
printf '\nThe human turns it on with close-push.sh --enable; no hook runs that.\n' >> "$T/bundle/docs/GOVERNANCE-AGENT-GUIDE.md"
# round 3b: neighbours of the new forbidden strings - a successful release, the session's work, a refusal
printf '\nA successful release is tagged; the commits of a session are committed at close, and the installer refuses without a terminal.\n' >> "$R"
printf '\nAfter a successful release the tag exists; the session'"'"'s work is committed first.\n' >> "$T/bundle/skills/impact-safe-executor/SKILL.md"
_o=$(run_checks "$T")
hasnt "benign liability, flag and phrase wording in NOTICE, README and Agent Guide: nothing fires" "$_o" "FAIL ("
for _id in a b c d e f g h i j; do has "benign: ($_id) passes" "$_o" "PASS ($_id)"; done

echo "terms-text selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" = "0" ] && [ "$PASS" -gt 0 ] && exit 0
exit 1
