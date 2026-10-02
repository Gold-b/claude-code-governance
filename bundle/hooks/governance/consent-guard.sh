#!/usr/bin/env bash
# consent-guard.sh - a PreToolUse hook: it sees the commands a Claude Code session is about to run
# and denies the ones it recognises as a consent act done for the user - accepting the terms,
# turning push at session close on, stripping the AI-agent markers, writing the consent records
# (2026-09-30, 2.0.0) - and reading the release signing key or running ssh-keygen -Y sign (TG2,
# rule 5). A safeguard, not a guarantee (STATED LIMIT below).
# Legal conditions: S1 (PreToolUse deny), C3 (only a person accepts - the guard half), T4 (the
# redirect half: an agent writing the records around the scripts).
#
# WHY. install.sh, gov-update.sh --accept-terms and close-push.sh --enable refuse to record an
# acceptance when they detect an AI-agent session (consent-lib.sh gov_human_consent_ok). That
# refusal reads the markers Claude Code sets for the commands it runs (CLAUDECODE, AI_AGENT,
# CLAUDE_CODE_ENTRYPOINT) - and a session can remove them in the same command
# (`env -u CLAUDECODE bash install.sh --accept-terms`), or skip the scripts and write the one-line
# record itself (`printf 'enabled=1 ...' > ~/.claude/.governance-update/close-push`, or
# `python3 -c "open(...close-push,'w')..."`). An agent's "acceptance" is not the user's consent.
# This hook denies both routes, in the forms it can recognise, before the command runs.
#
# WHAT IS DENIED (exit 2, reason on stderr, Hebrew second line):
#   1. Bash/PowerShell: the command names install.sh, gov-update.sh or close-push.sh AND carries a
#      consent flag: --accept-terms, --enable-close-push, --enable (as a word), GOV_ACCEPT_TERMS=,
#      or one of the retired automatic-update opt-in flags (the enable flag and its waiver flag;
#      written below as an alternation, so P8's no-auto-update grep of bundle/ stays at 0 hits).
#      The string is scanned whole, so `ssh host '...'`,
#      `bash -c '...'` and `powershell -c '...'` wrappers are caught.
#   2. A command that strips or blanks a marker in one of these SHELL shapes (an interpreter that
#      drops it from its own copy of the environment is not seen - STATED LIMIT): env -u / --unset, unset, export -n,
#      declare/typeset +x, X= (inline or export), $env:X=, Remove-Item/Clear-Item/Set-Item Env:X,
#      [Environment]::SetEnvironmentVariable('X' - for X in CLAUDECODE, AI_AGENT,
#      CLAUDE_CODE_ENTRYPOINT; and `env -i` / `env -` together with one of the three scripts.
#      Marker stripping is never legitimate for a session.
#   3. Edit/Write/MultiEdit/NotebookEdit whose path, NORMALISED (backslashes and // folded; per
#      segment trailing dots and spaces stripped - Windows drops them; `.` removed; `seg/..`
#      resolved; a trailing / removed; case-insensitive), has as its LAST segment - or that segment
#      before an NTFS stream `:x` - terms-accepted, close-push or auto-update in a directory named
#      .governance-update, or .governance-consent-selftest (the test nonce), or .governance-source
#      in .claude (the source machine's marker - ADDED beyond the P7 list: writing it is the same
#      bypass). Windows short (8.3) names reach the same files (MEASURED 2026-09-30: 8dot3 on,
#      .governance-update = GOVERN~4, close-push = CLOSE-~1, a write through either replaced the
#      record), so a record name under an 8.3-shaped directory, and an 8.3-shaped last segment in
#      .governance-update (or in an 8.3-shaped directory of .claude), are denied too (round-1
#      review, finding 19 + this addition). A file of the staged tree that shares a record name
#      would be denied as well - an agent must not write there either; NONE exists (MEASURED:
#      `find bundle -iname close-push -o -iname terms-accepted ...` -> 0).
#   4. Bash/PowerShell: the command mentions one of those records (a record name next to
#      .governance-update, the nonce / source marker, or an 8.3 short form: `GOVERN~4/close-push`,
#      `.governance-update/CLOSE-~1`) AND one of:
#      a. an interpreter in command position - python*, py, node(js), deno, bun, perl, ruby, php,
#         pwsh, powershell, osascript, tclsh, lua, (g)awk, cmd, cscript, wscript, mshta - with any
#         argument, heredoc or stdin (round-1 findings 15, 18: `python3 -c "open(...close-push,'w')"`
#         wrote the record past the token list; round 3: `cmd //c copy NUL <marker>`). Its code is
#         out of the guard's sight, so it is denied on sight;
#      b. a write token: > >> tee cp mv rm ln dd touch truncate, sed -i, perl -i, Set-Content
#         Add-Content Clear-Content Out-File New-Item Copy-Item Move-Item Rename-Item Remove-Item
#         WriteAll*; and in command position install rsync tar unzip patch xargs find mapfile
#         readarray (`install -m 600 /dev/stdin <record>`, `find ... -delete`);
#      b'. (round 3, finding 1 - each of these created the maintainer marker in a private HOME with
#         rc 0 from the old guard) a WRITE FORM of a command that is not inert: sort -o / --output /
#         --compress-program; uniq with two operands (`uniq IN OUT`, also after `--`); a sed script
#         with a `w F` / `e cmd` command or the s///w and s///e flags; sed -i / --in-place; git
#         --output[=]F, --output-directory, -o, config -f / --file F, bundle create. A long option
#         is recognised under ANY unique prefix, because GNU getopt and git accept one (round 4,
#         MEASURED 2026-10-02: `sort --outp=F`, `sort --o F`, `git config --fil F`, `sed --in
#         s/a/b/ F` each wrote past the full spelling - the sed form rewrote a record to
#         enabled=1): --o, --co (sort), --i (sed), --ou... (git), --fil (git config), --log-
#         (less); an AMBIGUOUS prefix is denied too (the real tool refuses it). Also ssh-keygen -f;
#         gh ... download; in command position
#         curl wget aria2c scp sftp xxd openssl gpg iconv script cmake ed ex vi vim nvim nano emacs
#         busybox zip 7z cpio pax fsutil certutil bitsadmin xcopy robocopy; Tee-Object Export-*
#         Start-Transcript -OutFile and [IO.File]::Create* / AppendAll* / AppendText / Copy / Move /
#         Replace / Open / OpenWrite / WriteAll*; and for the PowerShell tool the aliases copy cpi ac
#         sc ni mi move ren rni del erase ri rd rmdir iwr irm (and Invoke-WebRequest /
#         Invoke-RestMethod / Start-BitsTransfer). THIS LIST IS NOT CLOSED (STATED LIMIT);
#      c. for .governance-source only: mkdir, md, New-Item, ni - the marker as a DIRECTORY (round-1
#         finding 17: `mkdir -p ~/.claude/.governance-source` passed).
#      Every name of rules 1, 2 and 4 is looked for twice: as written, and as the shell joins it -
#      quotes, backslashes and backticks removed (round 3: `.governance-sour""ce`,
#      `.governance-sou''rce`, `.governance-sou\rce`, `.gover"nance-sou"rce`, `tou""ch`,
#      `--accept-te""rms` and `env -u CLAUDE""CODE` passed the old guard). The prefilter does the
#      same on a miss (one builtin substitution, no fork).
#      rm/mv/cp/ln or a *-Item cmdlet on the .governance-update directory itself counts too (ADDED).
#      With NO record name in sight: a redirection whose target names .governance-update
#      (`> ~/.claude/.governance-update/$f`), or a `cd` into it plus a redirection to a relative
#      target, is denied as a redirection into the directory (D4); and an interpreter (the list in
#      4a) in a non-inert command that names .governance-update is denied too (D4, round-2
#      findings 6/16: `python -c "...'~/.claude/.governance-update'...'close'+'-push'"` builds the
#      record name at run time and wrote the record). The directory name has to be literal: a
#      command that builds THAT at run time too is out of reach (STATED LIMIT).
#      Redirections to /dev/null or $null and fd duplications (2>&1) are not writes. `echo` and `printf` are NOT
#      tokens (a DEVIATION from the P7 list): they write only through `>` or a pipe into tee /
#      Out-File / Set-Content, all tokens already, so they add no coverage - and as tokens they
#      denied `cat <record>; echo rc=$?`, an ordinary read. An INERT command (below) is scanned
#      for tokens without its quoted text, so a grep PATTERN that contains `touch` or `>` is a
#      read; anything that can run its arguments (bash -c, ssh, python) is scanned whole.
#   5. The release signing key (TG2, 2026-09-30; legal S3c, C7c defence in depth). Only the
#      person releasing signs, in their own terminal (gov-release.sh refuses when it detects a session; this is
#      the second line). Checked only when the payload names `ssh-keygen` or `.ssh` (a prefilter
#      glob; `.ssh` rather than the plan's `.ssh/`, so `cd ~/.ssh && cat <key>` and a JSON
#      `\\.ssh\\` path hit too). Only then is consent-lib.sh sourced, and the key path read with
#      gov_local_env_get GOV_RELEASE_KEY (process env, else ~/.claude/.governance-local.env).
#      a. Read whose file_path has the key's file name (case-insensitive), and any Bash/PowerShell
#         command that names it as a whole word - cat, cp, base64, Get-Content, ssh-keygen -y
#         -f <key> alike, INERT or not (cat is inert, and cat is the leak). The .pub does not
#         match: `.` after the name is part of the word.
#      b. Any `ssh-keygen ... -Y sign` (any key, any path, `-Ysign`, `-qY sign`, ssh-keygen.exe,
#         inside ssh / bash -c / env -u SSH_AUTH_SOCK), unless the command is INERT (a grep for
#         the phrase, a commit message naming it). `-Y` is matched case-sensitively: `-y` is
#         "print the public key", a different act.
#
# WHAT PASSES. A read of a record by a tool that does not execute or write (cat, head, grep, ls,
#   stat, sha256sum ..., the Read tool); gov-update.sh --status / --fetch / --apply; close-push.sh
#   -C <repo> (a close) and --disable; install.sh without a consent flag (the script itself
#   refuses when it detects a session); an interpreter in a command that names neither a record
#   nor .governance-update; every other tool.
#   NOT every read passes (round-2 finding 4): in a command that names a record, a read is denied
#   when it runs through an interpreter (`python3 -c "print(open(<record>).read())"`), or when the
#   same command also writes - a redirection to a file (`cat <record> > /tmp/copy`), a pipe into
#   tee (`sha256sum <record> | tee /tmp/h`), or any other write token or write form of rule 4b /
#   4b'. The guard does not tell which file such a write lands in, so it denies on the token:
#   `ls ~/.claude/.governance-source; sort -o /tmp/x y` is denied too. Read the record with a
#   plain `cat`/`head`/`ls`/`test -f`/the Read tool, and copy what you need from the output.
#   Rules 1 and 2 also pass an INERT command (ADDED beyond the P7 text): when every segment of the
#   command (split on ; & | and newlines; quoted text and QUOTED heredoc bodies are literal and
#   ignored for the split) starts with a tool that does not execute its arguments - grep/rg/cat/
#   head/tail/wc/diff/cmp/ls/stat/sha*sum/cut/nl/cd/pwd/echo/printf/test, Select-String/
#   Get-Content/Get-ChildItem/...; and, ONLY WITHOUT THEIR WRITE OPTION (round 3, finding 1: each
#   wrote a named file past this list), sort without -o / --output / --compress-program (or a
#   prefix of them: --o, --co), uniq with at most one operand (words after `--` count), less/more
#   without -o / --log-file (--log-), sed without -i / --in-place (--i) and without a w / e
#   script command, git without an inline -c, a `!` or a write form of rule 4b', gh pr|issue|release
#   without download. The options are read with each quoted string replaced by its own text and
#   empty quotes and backslashes dropped, so `sort "-o" F` and `sort --out""put=F` are seen -
#   and it holds no $( ) (other than "$(cat <<'EOF' ... EOF)"), backtick or process
#   substitution. Without this, `grep -n -- --accept-terms install.sh` (how this very repo is
#   maintained, and P8's own check) and a commit message that names the flag would be denied: a
#   control that fires on ordinary work gets switched off (CLAUDE.md, 2026-09-15 rule 3). An
#   assignment PREFIX (VAR=x cmd), bash, sh, ssh, env, eval, source, xargs, find, awk, python...
#   make a segment NOT inert; a bare `VAR=x` segment is inert unless VAR is GOV_ACCEPT_TERMS or a
#   marker.
#
# STATED LIMIT (GOTCHAS, P10; round-2 findings 4, 5, 6, 14). This guard is a set of regular
#   expressions over a command string - the second line of defence, never the first. Any process
#   that runs under the user's own account, an AI agent included, can do what the user can: forge
#   a record, unset a marker, allocate a pseudo-terminal. The scripts' refusal (they refuse when
#   they detect an AI-agent session), this guard, and the question asked on a real terminal are
#   three safeguards, none of them a guarantee; the records carry method= and the hashes of what
#   was shown, so the user can see what was accepted and by which method.
#   Out of the guard's reach, as measured or by construction:
#   - a NAME BUILT AT RUN TIME: a record name AND the directory name both assembled by the code
#     (`'.gover'+'nance-update/close'+'-push'`), a flag assembled the same way
#     (`'--accept-'+'terms'`), or a script name assembled the same way (`'inst'+'all.sh'`);
#   - MARKER REMOVAL INSIDE AN INTERPRETER: `python -c "e=dict(os.environ); e.pop('CLAUDECODE');
#     subprocess.run([...], env=e)"` (MEASURED round 2: allowed) - rule 2 knows only the shell
#     shapes (env -u, unset, X=, the PowerShell forms);
#   - a script file run by bash/sh that writes the record or strips the markers, an alias, a
#     function, a variable holding the path or the flag in a form other than the redirection above
#     (`cp x "$D/$f"`, `n=.governance-sour; touch ~/.claude/${n}ce`), brace expansion
#     (`.governance-sour{c,}e`), $'...' quoting with escapes, a glob that matches an existing
#     file, a hashed 8.3 name (`GO1A2B~1`, used after four collisions), a junction/symlink to the
#     directory;
#   - a program not on the lists of rule 4: the write-form list is NOT closed (round 3, finding 1:
#     the old list missed sort -o, uniq, sed w, git --output, curl -o and more); any program or
#     script not on it is out of reach - one that writes a file named on its command line (a
#     compiler's -o, an archiver, a converter, a package manager, a test runner) passes. Round 4
#     (MEASURED 2026-10-02): `shuf -o F`, `sdiff -o F`, `link A F`, a git chain that builds the file
#     in another work tree (`update-index --cacheinfo` + `checkout-index`), and the PowerShell .NET
#     forms `([IO.FileInfo]F).Create()` / `New-Object IO.StreamWriter F` passed;
#   - an edit of ~/.claude/settings.json "env" that sets GOV_CONSENT_GUARD=0 or GOVERNANCE_HOOKS=0:
#     the guard does not stop it; the kill switch is meant for the owner, not enforced as his.
#   Rule 5 knows the key by its FILE NAME, so: a key kept outside a `.ssh` directory is covered
#   only when the same payload also says `ssh-keygen` (keep the release key in ~/.ssh); a read
#   that never names the file (`cat ~/.ssh/*`, `grep -r . ~/.ssh`, `cat "$GOV_RELEASE_KEY"`) and
#   the Grep/Glob tools (not in the matcher) are out of its reach; an unrelated file that shares
#   the key's name is denied too. `git tag -s` / `git commit -S` with a configured ssh signing
#   key signs without naming ssh-keygen. With GOV_RELEASE_KEY unset, 5a is off and 5b still
#   runs. consent-lib.sh missing -> 5a fails OPEN with a logged warning.
#
# FAIL MODES. Internal errors fail OPEN with a logged warning (payload not a JSON object, no
#   tool_name): a guard that crashes must not freeze all work. The matched cases fail CLOSED.
#
# COST. Pure bash, no python/jq, no _common.sh (bootstrap-gate.sh's payload reader). The allow
#   path forks nothing except `cat` for payloads > 4 KB and has no $( ): one `case` glob
#   prefilter over the payload decides almost every call before any regex runs.
#   Bench, re-run after the round-1 rules (MEASURED 2026-09-30, the method of
#   tests/bench-bootstrap-gate.sh, 8 logical CPUs, 31 runs, median / p95 ms; "as found" = other
#   sessions were running, so the floor is ~2x the first bench's idle 46 ms):
#     as found: empty bash 94/373 · Bash 'git status' (prefilter miss) 94/328 · Edit README
#            94/340 · inert grep 93/356 · 'bash install.sh --accept-terms' (DENY) 154/405 ·
#            150 KB Write naming .governance-update 171/419 · NEW Write
#            .governance-update\x\..\close-push. (DENY) 155/435 · NEW python3 -c open(record)
#            (DENY) 155/590 · NEW mkdir -p .governance-source (DENY) 156/606 · NEW `> .../$f`
#            (DENY) 156/869 · NEW 'git diff HEAD~1' (8.3 prefilter hit, allow) 108/529 ·
#            bootstrap-gate.sh 'git status' 95/373
#     load (one CPU burner per logical CPU): empty bash 444/796 · 'git status' 438/1009 ·
#            Edit 454/1344 · inert 435/1064 · DENY 724/1256 · 150 KB Write 753/1576 · NEW
#            normalised Write DENY 695/2163 · NEW interpreter DENY 719/1518 · NEW mkdir DENY
#            645/1396 · NEW hidden redirection DENY 750/1363 · NEW HEAD~1 allow 467/1020 ·
#            bootstrap-gate.sh 'git status' 449/1028
#   The allow path sits at the process-spawn floor and beside bootstrap-gate.sh; the worst loaded
#   p95 (2.2 s, the normalised-Write deny) is ~4.6x inside the 10 s budget.
#   Round-1 replay (MEASURED 2026-09-30): 34,250 distinct Bash/PowerShell/Edit/Write/MultiEdit/
#   NotebookEdit calls in this machine's transcripts, 2,772 pass the prefilter; the NEW rules deny
#   45. 37 are sandbox probes of the consent machinery itself (node/python writing records into a
#   mktemp HOME - the act, by shape: run such probes from a script file); 1 is the act on the
#   real machine (`python -c "...os.remove(...close-push / terms-accepted)"`); 7 are ordinary
#   work: 1 python heredoc and 2 `sed -i` edits of this repo whose text names a record or a
#   `> .governance-update/...` line (a non-inert command is scanned whole), and 4 commands that
#   name .governance-source AND run node / python / `command -v python` for something else.
#   Rule 5 (TG2, MEASURED 2026-09-30, a busy machine, 21-31 runs, median / p95 ms): a Read that
#   misses the prefilter costs one glob; a hit sources consent-lib.sh and forks the
#   gov_local_env_get grep (~0.2 s idle, ~0.8 s loaded).
#     idle : empty bash 59/296 · Read README (miss) 115/366 · Read .ssh/<key>.pub (allow)
#            268/943 · Read <key> (DENY) 264/516 · 'ssh -i ~/.ssh/id box uptime' (allow)
#            256/1134 · 'ssh-keygen -Y sign' (DENY) 477/961
#     load (8 burners, 8 CPUs): empty bash 339/627 · Read miss 441/977 · .pub 1229/1742 ·
#            key DENY 1306/1596 · ssh allow 1073/1895 · -Y sign DENY 1529/2569
#   Worst loaded p95 2.6 s, ~4x inside the 10 s budget. False-positive replay (this machine's
#   transcripts): 4 distinct calls ran ssh-keygen -Y sign - one signed with the real release key
#   (the act itself), two signed throwaway keys while reviewing the design, one printed the usage;
#   2 more named the key file while setting it up. All 6 are denied from now on, by the spec.
#   False-positive replay (MEASURED 2026-09-30): the last 14,288 Bash/PowerShell/Edit/Write calls
#   in this machine's transcripts; 694 pass the prefilter, 6 are denied: 3 are the act itself (a
#   session running install.sh --force --accept-terms, plus two --dry-run runs with the flag),
#   2 are python heredocs editing install.sh / gov-release.sh (python runs its input, so it is
#   scanned whole), 1 is `env -u CLAUDECODE ... node <cli>` testing a CLI in another project -
#   the one legitimate use found; rule 2 denies it by the P7 spec ("in ANY command").
#   Rule a' (round 2, MEASURED 2026-10-01, other agents busy on the machine, 21 runs, median / p95
#   ms, old guard -> new): as found: git status 332/736 -> 156/523 · ls .governance-update
#   254/729 -> 234/719 · ls dir + python3 build.py 581/710 -> 633/838 (now DENY) · node -e
#   writing dir+'close'+'-push' 207/997 -> 646/1535 (now DENY); load (8 burners, 8 CPUs): git
#   status 2576/3447 -> 946/1999 · ls dir 2611/4813 -> 846/1729 · ls dir + python3 899/1968 ->
#   1172/2270 (now DENY) · node dir 553/1594 -> 878/2952 (now DENY). Noise dominates (the old
#   guard's allow rows were the slower ones); worst loaded p95 3.0 s, ~3.4x inside the 10 s budget.
#   Its cost when wrong (replay of the 42 distinct Bash/PowerShell transcript commands on this
#   machine that name .governance-update): 10 more are denied, all ordinary maintenance - python
#   heredocs and node -e edits of framework files whose text names the directory, and compound
#   commands that name it in one segment and run node / awk / powershell in another; none was the
#   act. On a client machine such commands are rare; run that kind of edit from a script file.
#   Round 3 (finding 1, MEASURED 2026-10-02, two other agents busy on the machine, 21 runs,
#   median / p95 ms, old guard -> new): as found: empty bash 188/864 · git status (miss) 170/641 ->
#   127/517 · 150 KB command naming nothing (miss: pays the one quote-stripping substitution)
#   257/756 -> 396/830 · ls <marker> (allow) 124/557 -> 144/624 · grep 'sort -o' <marker> (inert,
#   allow) 182/1060 -> 644/973 · sort -o <marker> 711/1193 (allowed) -> 936/1917 DENY ·
#   touch .governance-sour""ce 212/662 (allowed) -> 860/1950 DENY · touch <marker> 315/799 ->
#   534/994 DENY · PowerShell ac <record> 519/1213 (allowed) -> 1060/2461 DENY; load (8 burners,
#   8 CPUs): empty bash 1962/2819 · git status 1719/2534 -> 2396/3255 · 150 KB miss 1976/5435 ->
#   2701/4318 · ls <marker> 1543/2312 -> 1321/1941 · inert grep 1037/1915 -> 1394/2338 · sort -o
#   1343/2588 -> 3150/3808 · split touch 1418/2586 -> 2153/3651 · touch 2360/2925 -> 2175/4074 ·
#   ac 1642/2755 -> 2813/4466. Worst loaded p95 4.5 s, ~2.2x inside the 10 s budget; the spawn
#   floor itself was 2.8 s p95 in that run. Cost when wrong (replay, the same day): group A's 42
#   transcript commands naming .governance-update -> 18 denied before and after (no change); the
#   120 distinct Bash/PowerShell transcript commands that name the marker or the directory, as
#   written or with quotes removed -> 58 denied before, 61 after; the 3 new denials are all probes
#   of this guard (one reviewer's `sort -o` probe, two of this round's own test commands), none is
#   ordinary work. A false positive that remains by design: a command that names a record AND
#   writes anywhere (`ls <marker>; sort -o /tmp/x y`) is denied.
#
# Kill switches: GOVERNANCE_HOOKS=0 (all governance hooks; loud), GOV_CONSENT_GUARD=0 (this
#   guard only; owner-only). Both are read from THIS hook's environment, i.e. ~/.claude/settings.json
#   "env": an inline `GOV_CONSENT_GUARD=0 bash ...` in the command string never reaches a hook.
#
# Usage (registered in ~/.claude/settings.json, user level only):
#   PreToolUse matcher Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell|Read -> consent-guard.sh
#   (Read since TG2: a Read that misses the `.ssh` / `ssh-keygen` prefilter exits on one glob.)
# Tests: tests/test-consent-guard.sh (both directions); governance-selftest.sh case_consent_guard.
set +e

_cg_log() {
  local log="${GOVERNANCE_LOG:-$HOME/.claude/logs/governance.log}" ts msg="$1"
  case "$log" in "$HOME/.claude/"*) ;; *) log="$HOME/.claude/logs/governance.log" ;; esac
  [ -L "$log" ] && return 0
  msg="${msg//[$'\n\r']/ }"
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1 2>/dev/null
  # 2>/dev/null FIRST: redirections apply left to right, so a missing log dir would otherwise
  # print "No such file or directory" into the session.
  printf '[%s] [consent-guard] %s\n' "$ts" "$msg" 2>/dev/null >> "$log"
  return 0
}

# ── Kill switches (checked before stdin is read) ─────────────────────────────
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ]; then
  [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — governance hooks are DISABLED; bypassing consent-guard (a session can now accept terms or enable push for the user). (silence this notice with GOV_BYPASS_QUIET=1)" >&2
  exit 0
fi
[ "${GOV_CONSENT_GUARD:-1}" = "0" ] && exit 0

# ── Read the payload: first 4 KB with the builtin (no fork), the rest with one `cat` ──
_in=""
if [ ! -t 0 ]; then
  IFS= read -r -N 4096 _in
  [ "${#_in}" -ge 4096 ] && _in+="$(cat)"
fi

_head="${_in:0:64}"; _tail="$_in"; [ "${#_in}" -gt 64 ] && _tail="${_in: -64}"
if ! [[ $_head =~ ^[[:space:]]*\{ ]] || ! [[ $_tail =~ \}[[:space:]]*$ ]]; then
  _cg_log "WARNING: payload is not a JSON object (${#_in} chars) - failing OPEN"
  exit 0
fi

_tool=""; _re="\"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_.:-]*)\""
[[ $_in =~ $_re ]] && _tool="${BASH_REMATCH[1]}"
if [ -z "$_tool" ]; then
  _cg_log "WARNING: no tool_name in payload - failing OPEN"
  exit 0
fi

# Windows paths and PowerShell names are case-insensitive; over-matching a lowercase bash name
# costs nothing. Applies to every `case` and [[ ]] below.
shopt -s nocasematch

_re_str='"((\\.|[^"\\])*)"'
_jfield() {  # _jfield <key> -> _JF = the first "key":"value" (raw, JSON-escaped). No fork.
  local re="\"$1\"[[:space:]]*:[[:space:]]*$_re_str"
  _JF=""; [[ $_in =~ $re ]] && _JF="${BASH_REMATCH[1]}"
}

_WHO_CONSENT="This needs the user's own decision, typed in their own terminal: an acceptance or a yes made or
passed by an AI agent is not the user's consent, and this guard refuses the ones it recognises
(a safeguard, not a guarantee). Nothing was run. Tell the user the exact command to type themselves."
_HEB_CONSENT='[שומר הסכמה] נחסם: אישור התנאים והפעלת דחיפה בסגירת סשן הם החלטה שלך, בטרמינל שלך. לא הורץ דבר.'
_deny() {  # _deny <what> <why-line> [<human-line> <hebrew-line>]  (3+4 default to the consent text)
  _cg_log "BLOCK $1 (tool=$_tool)"
  local who="${3:-$_WHO_CONSENT}" heb="${4:-$_HEB_CONSENT}"
  cat >&2 <<EOF
[GOVERNANCE CONSENT GUARD] BLOCKED: $1.
$2
$who
$heb
Owner-only bypass: GOV_CONSENT_GUARD=0 in ~/.claude/settings.json "env" (an inline prefix in the command never reaches this hook).
EOF
  exit 2
}
_WHY_REC='The consent records in ~/.claude/.governance-update/ are written only by install.sh, gov-update.sh --accept-terms and close-push.sh when the user runs them. A session may read them with a plain read (cat, head, the Read tool); a command that also writes - with a write tool, a write option (sort -o, sed w, git --output, curl -o ...) or a redirection, or by an interpreter whose code the guard does not see into - is denied on sight.'
_WHY_SRC='~/.claude/.governance-source marks the maintainer'"'"'s machine: while it exists, push at session close is on with no question. The person who maintains the framework creates it in their own terminal (gov-release.sh also creates it after a release); a session does not create, copy or write it. A session may read or test for it with a plain read (ls, test -f, cat); a command that also writes - with a write tool, a write option (sort -o, sed w, git --output, curl -o ...) or a redirection, or by an interpreter whose code the guard does not see into - is denied on sight.'
_WHY_MARK='The markers CLAUDECODE, AI_AGENT and CLAUDE_CODE_ENTRYPOINT are how the scripts know a person is not the one typing. Removing or blanking them in a session is never legitimate.'
_WHY_CMD='Accepting the terms and turning push at session close on are the user'"'"'s own acts.'
_WHY_KEY='The release signing key is used only by the person releasing, in their own terminal (gov-release.sh signs there, with the passphrase or touch prompt on that terminal). A session may read the .pub and run ssh-keygen -Y verify; it never reads the private key and never signs.'
_WHO_KEY="Signing a release is the person's own act, in their own terminal: a session does not read the release
key or sign, and this guard refuses the forms it recognises (a safeguard, not a guarantee). Nothing was run. Tell the user the exact command to type themselves (bash ~/.claude/hooks/governance/gov-release.sh <version>)."
_HEB_KEY='[שומר הסכמה] נחסם: חתימה על גרסה היא פעולה שלך, בטרמינל שלך. סשן לא קורא את המפתח הפרטי ולא חותם. לא הורץ דבר.'

# ── 5. the release signing key: helpers (called only after the ssh-keygen / .ssh prefilter) ──
# _cg_key -> _KEYB = the file name of GOV_RELEASE_KEY, empty when it is unset or consent-lib.sh is
# missing (then 5a fails OPEN, logged). consent-lib.sh is pure: sourcing it only defines functions.
_cg_key() {
  _KEYB=""
  local lib k bs='\'
  case "${BASH_SOURCE[0]}" in */*) lib="${BASH_SOURCE[0]%/*}/consent-lib.sh" ;; *) lib="./consent-lib.sh" ;; esac
  if [ ! -f "$lib" ]; then _cg_log "WARNING: consent-lib.sh not found beside the guard - the release-key path rule is OFF (failing OPEN); ssh-keygen -Y sign is still denied"; return 0; fi
  . "$lib"
  k="$(gov_local_env_get GOV_RELEASE_KEY)"
  k="${k//$bs//}"; k="${k%/}"
  _KEYB="${k##*/}"
}
# _cg_names_key <text> -> 0 when <text> names the key file as a whole word (so <key>.pub does not).
_cg_names_key() {
  local b="$_KEYB" re
  [ -n "$b" ] || return 1
  case "$b" in *[!A-Za-z0-9_.+-]*) case "$1" in *"$b"*) return 0 ;; esac; return 1 ;; esac
  b="${b//./\\.}"; b="${b//+/\\+}"
  re="(^|[^A-Za-z0-9_.-])$b([^A-Za-z0-9_.-]|\$)"
  [[ $1 =~ $re ]]
}

# _cg_normpath <path with / separators> -> _NP: // folded, `.` removed, per segment trailing dots
# and spaces stripped (Windows drops them: `close-push.` and `close-push ` are close-push), `seg/..`
# resolved left to right (a leading `..` is kept), trailing / dropped. A segment that is only dots
# after `..` handling (`...`) strips to nothing and is dropped. No fork, no filesystem access.
_cg_normpath() {
  local p="$1" seg lead="" n IFS=/
  local -a parts st=()
  case "$p" in /*) lead=/ ;; esac
  set -f; parts=($p); set +f
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|.) continue ;;
      ..) n=${#st[@]}
          if [ "$n" -gt 0 ] && [ "${st[$((n-1))]}" != ".." ]; then unset "st[$((n-1))]"; st=("${st[@]}")
          else st+=(".."); fi
          continue ;;
    esac
    while :; do case "$seg" in *.|*' ') seg="${seg%?}" ;; *) break ;; esac; done
    [ -n "$seg" ] && st+=("$seg")
  done
  _NP="$lead${st[*]}"
}

case "$_tool" in
  # ════ 5a. Read of the release key ════════════════════════════════════════
  Read)
    case "$_in" in *ssh-keygen*|*.ssh*) ;; *) exit 0 ;; esac
    _jfield file_path; _fp="$_JF"
    [ -n "$_fp" ] || exit 0
    _cg_key
    [ -n "$_KEYB" ] || exit 0
    _fp="${_fp//\\\\//}"; _fp="${_fp//\\//}"; _fp="${_fp%/}"
    [[ "${_fp##*/}" == "$_KEYB" ]] && _deny "Read of the release signing key ($_KEYB)" "$_WHY_KEY" "$_WHO_KEY" "$_HEB_KEY"
    exit 0 ;;
  # ════ 3. file tools: the path decides ════════════════════════════════════
  Edit|Write|MultiEdit|NotebookEdit)
    case "$_in" in *governance-update*|*consent-selftest*|*governance-source*|*~[0-9]*) ;; *) exit 0 ;; esac
    _jfield file_path; _fp="$_JF"
    [ -n "$_fp" ] || { _jfield notebook_path; _fp="$_JF"; }
    [ -n "$_fp" ] || exit 0
    _fp="${_fp//\\\\//}"; _fp="${_fp//\\//}"
    _cg_normpath "$_fp"; _fp="$_NP"
    _last="${_fp##*/}"; _lb="${_last%%:*}"          # _lb: the name before an NTFS stream
    _par=""; _gp=""
    case "$_fp" in */*) _par="${_fp%/*}"; case "$_par" in */*) _gp="${_par%/*}"; _gp="${_gp##*/}" ;; esac; _par="${_par##*/}" ;; esac
    _re83='^[^~/]{1,6}~[0-9]+(\.[^.~/]{0,3})?$'
    case "$_lb" in
      terms-accepted|close-push|auto-update)
        if [[ $_par == .governance-update ]] || [[ $_par =~ $_re83 ]]; then _deny "$_tool of a consent record ($_last)" "$_WHY_REC"; fi ;;
      .governance-consent-selftest)
        _deny "$_tool of a consent record ($_last)" "$_WHY_REC" ;;
      .governance-source)
        if [ -z "$_par" ] || [[ $_par == .claude ]] || [[ $_par =~ $_re83 ]]; then _deny "$_tool of a consent record ($_last)" "$_WHY_REC"; fi ;;
    esac
    if [[ $_lb =~ $_re83 ]]; then
      if [[ $_par == .governance-update ]] || { [[ $_par =~ $_re83 ]] && { [[ $_gp == .claude ]] || [[ $_gp =~ $_re83 ]]; }; }; then
        _deny "$_tool of a consent record by a Windows short name ($_last)" "$_WHY_REC"
      fi
    fi
    exit 0 ;;
  Bash|PowerShell) ;;
  *) exit 0 ;;
esac

# ════ shell tools ════════════════════════════════════════════════════════════
# Prefilter: none of the names anywhere in the payload -> nothing to classify. A miss is checked
# once more with every quote, backslash and backtick removed (one builtin substitution, no fork):
# the shell joins `.governance-sour""ce`, `.governance-sou\rce` and `.gover"nance-sou"rce` into the
# real name (round-3 finding 1: each created the marker past the guard).
case "$_in" in
  *install.sh*|*gov-update.sh*|*close-push.sh*|*governance-update*|*CLAUDECODE*|*AI_AGENT*|*CLAUDE_CODE_ENTRYPOINT*|*consent-selftest*|*governance-source*|*ssh-keygen*|*.ssh*|*~[0-9]*) ;;
  *) _inn="${_in//[\"\'\\\`]/}"
     case "$_inn" in
       *install.sh*|*gov-update.sh*|*close-push.sh*|*governance-update*|*CLAUDECODE*|*AI_AGENT*|*CLAUDE_CODE_ENTRYPOINT*|*consent-selftest*|*governance-source*) ;;
       *) exit 0 ;;
     esac ;;
esac
_jfield command; _cmd="$_JF"
[ -n "$_cmd" ] || exit 0

# Normalise the JSON-escaped string: \\ -> / (Windows paths, PowerShell Env:\X), \" -> ",
# \n -> ; (a new line is a new command), \r \t -> blank.
_c="${_cmd//\\\\//}"; _c="${_c//\\\"/\"}"; _c="${_c//\\n/;}"; _c="${_c//\\r/ }"; _c="${_c//\\t/ }"
# _cx: the same command as the shell will see its NAMES - every quote, backslash and backtick
# removed (`.governance-sour""ce`, `.governance-sou\rce`, `tou""ch`). Used to find a record name,
# a script name, a flag or a marker, and as extra text for the write tokens of a command that is
# not inert. Never used alone to decide that a command is a read.
# A JSON-escaped backslash goes first (to \x1f), so `sou\rce` is not read as a JSON \r.
_u=$'\x1f'
_cx="${_cmd//\\\\/$_u}"; _cx="${_cx//\\n/;}"; _cx="${_cx//\\r/ }"; _cx="${_cx//\\t/ }"; _cx="${_cx//$_u/}"; _cx="${_cx//[\"\'\\\`]/}"

_B='(^|[^A-Za-z0-9_-])'     # word start
_E='([^A-Za-z0-9_-]|$)'     # word end
_BC="(^|[[:space:];&|(\`{\"'/=])"   # command position: `README.md` or `fix.patch` is not md / patch

# _cg_uniq_writes <segment> -> 0 when `uniq` has two operands (`uniq IN OUT` writes OUT). The word
# after -f / -s / -w is that option's number, not an operand; a lone `-` is an operand (stdin).
_cg_uniq_writes() {
  local IFS=$' \t' w n=0 skip=0 dd=0
  local -a ws
  set -f; ws=($1); set +f
  for w in "${ws[@]:1}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    # After `--` every word is an operand, even one that starts with `-` (round-4: `uniq -- -x F`).
    if [ "$dd" = 1 ]; then n=$((n+1)); continue; fi
    case "$w" in --) dd=1 ;; -f|-s|-w) skip=1 ;; -) n=$((n+1)) ;; -*) ;; *) n=$((n+1)) ;; esac
  done
  [ "$n" -ge 2 ]
}
# A sed script that writes a file (`w F`, `$w F`, `/re/w F`, `s/a/b/w F`, `s/a/b/gw F`) or runs a
# command (`e cmd`, `s///e`): the `w` / `e` stands alone - after a quote, a blank, an address or the
# s-flags - and a blank, a path start or the end follows. `-e` and `/where/` do not match.
_re_sedw_cmd='((^|[^A-Za-z0-9.~-]|/[gpime0-9]+)[we]([_[:space:]~/.$"'"'"']|$)|(^|[^A-Za-z0-9.~-])[0-9]+([,~][0-9]+)*[we])'
# (the second alternative: a NUMERIC address - `1w F`, `1,5w F`, `0~1w F`, `1wF`, `1e cmd` - round 4b)
# _cg_abbr <var> <name> <min> -> <var> = an ERE for `--` + any prefix of <name> that is at least <min>
# characters long: GNU getopt and git accept any UNIQUE prefix of a long option (round-4:
# `sort --outp=F`, `git config --fil F`, `sed --in s/a/b/ F` each wrote past the full spelling).
# An ambiguous prefix is matched too - the real tool refuses it, so denying it costs nothing.
# No fork: it runs on every call.
_cg_abbr() {
  local name="$2" min="$3" i out close=""
  out="--${name:0:$min}"
  for ((i = min; i < ${#name}; i++)); do out+="(${name:i:1}"; close+=")?"; done
  printf -v "$1" '%s' "$out$close"
}
_cg_abbr _ab_gitout output-directory 2   # --ou ... --output-directory (git diff/format-patch)
_cg_abbr _ab_gitfile file 3              # --fil, --file (git config); `--fi` / `--f` are ambiguous in git
# git forms that write a NAMED file: --output[=]F, --output-directory (and every unique prefix, see
# above), -o (archive, format-patch), config -f / --file F (and --fil), bundle create F.
_re_gitw_opt="[[:space:]](${_ab_gitout}|${_ab_gitfile})([=_[:space:]]|\$)|[[:space:]]-o|[[:space:]]config[_[:space:]]([^;&|]*[_[:space:]])?-f|[[:space:]]bundle[_[:space:]]+create"
# (-o and config -f with the value ATTACHED - `git archive -oF`, `git config -fF a.b c` - are written too: round 4b)

# _cg_pure_read -> _PURE=1 when every segment starts with a read-only tool (see header). The answer is
# computed once per call (every rule asks the same question about the same command).
_PR_DONE=0
_cg_pure_read() {
  [ "$_PR_DONE" = 1 ] && return 0
  _PR_DONE=1
  _PURE=0; _PS=""
  # \x1f stands for a backslash the shell sees: `/` in _PS (a Windows path, as before), dropped
  # in the option view below (`--out\put` is --output to the shell).
  local u=$'\x1f'
  local s="${_cmd//\\\\/$u}" seg sego lead d pre post n=0 po m q i
  s="${s//\\\"/\"}"
  # A QUOTED heredoc (<<'EOF' / <<"EOF") is literal text up to its delimiter line: the body of
  # `git commit -m "$(cat <<'EOF' ... EOF)"` names flags, it does not run them.
  local re_hd="<<-?[[:space:]]*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"
  while [[ $s =~ $re_hd ]] && [ "$n" -lt 8 ]; do
    n=$((n+1)); d="${BASH_REMATCH[1]}"
    pre="${s%%"${BASH_REMATCH[0]}"*}"; post="${s#*"${BASH_REMATCH[0]}"}"
    case "$post" in *"\\n$d"*) post="${post#*"\\n$d"}" ;; *) post="" ;; esac
    s="${pre}<<Q${post}"
  done
  local re_cat='\$\(cat[[:space:]]*<<Q(\\n|[[:space:]])*\)'
  while [[ $s =~ $re_cat ]]; do s="${s/"${BASH_REMATCH[0]}"/Q}"; done
  s="${s//\\n/;}"; s="${s//\\r/ }"; s="${s//\\t/ }"
  s="${s//\"\"/}"; s="${s//\'\'/}"   # empty quotes are no-ops to the shell: `so""rt` is sort
  # po: the OPTION view - the same command with each quoted string replaced by its own text, its
  # blanks and separators turned into `_` (so `sort "-o" F` shows -o, and `grep "a; b"` stays one
  # segment). Replaced in the same order as s, so both split into the same segments.
  po="$s"
  while [[ $s =~ \'[^\']*\' ]]; do                                          # '...' is literal text
    m="${BASH_REMATCH[0]}"; q="${m:1:${#m}-2}"; q="${q//[[:space:];&|<>()\`\"\$]/_}"
    s="${s/"$m"/Q}"; po="${po/"$m"/"$q"}"
  done
  case "$s" in *'$('*|*'`'*|*'<('*|*'>('*) return 0 ;; esac                 # something executes
  while [[ $s =~ \"[^\"]*\" ]]; do
    m="${BASH_REMATCH[0]}"; q="${m:1:${#m}-2}"; q="${q//[[:space:];&|<>()\`\'\$]/_}"
    s="${s/"$m"/Q}"; po="${po/"$m"/"$q"}"
  done
  s="${s//$u//}"; po="${po//$u/}"
  _PS="$s"   # the command with its literal text removed; rule 4 scans this when _PURE=1
  s="${s//2>&1/ }"; s="${s//1>&2/ }"; s="${s//>&2/ }"
  s="${s//&&/;}"; s="${s//||/;}"; s="${s//|/;}"; s="${s//&/;}"
  po="${po//2>&1/ }"; po="${po//1>&2/ }"; po="${po//>&2/ }"
  po="${po//&&/;}"; po="${po//||/;}"; po="${po//|/;}"; po="${po//&/;}"
  local IFS=';'
  local -a segs segos
  set -f; segs=($s); segos=($po); set +f
  [ "${#segs[@]}" = "${#segos[@]}" ] || return 0   # the two views disagree: not provably a read
  for ((i = 0; i < ${#segs[@]}; i++)); do
    seg="${segs[$i]}"; sego="${segos[$i]}"
    while :; do case "$seg" in [[:space:]]*|'('*|'{'*|'!'*) seg="${seg:1}" ;; *) break ;; esac; done
    while :; do case "$sego" in [[:space:]]*|'('*|'{'*|'!'*) sego="${sego:1}" ;; *) break ;; esac; done
    [ -n "$seg" ] || continue
    # A segment that is ONLY a shell variable assignment (`P="a b c"` before `git add -- $P`) runs
    # nothing - unless it sets the acceptance variable or a marker.
    if [[ $seg =~ ^([A-Za-z_][A-Za-z0-9_]*)=[^[:space:]]*[[:space:]]*$ ]]; then
      case "${BASH_REMATCH[1]}" in GOV_ACCEPT_TERMS|CLAUDECODE|AI_AGENT|CLAUDE_CODE_ENTRYPOINT) return 0 ;; esac
      continue
    fi
    lead="${seg%%[[:space:]]*}"; lead="${lead##*/}"; lead="${lead%.exe}"
    # A tool that CAN write a file it is given by name is inert only without that option (round-3
    # finding 1: `sort -o`, `uniq IN OUT`, `sed -n 'w F'`, `git config --file F` and
    # `git diff --output=F` each created the maintainer marker past this list). The options are
    # read in the option view (sego), so a quoted `"-o"` or a split `--out""put` is seen too.
    case "$lead" in
      grep|egrep|fgrep|rg|cat|head|tail|wc|diff|cmp|comm|ls|stat|file|sha256sum|sha1sum|md5sum|cut|nl|cd|pwd|true|false|test|'['|echo|printf|sleep|exit|Write-Output|Write-Host|Select-String|sls|Get-Content|gc|Get-ChildItem|gci|dir|Get-Item|Test-Path|Get-FileHash|Measure-Object|Select-Object|Out-String|Format-List|Format-Table) ;;
      # `--o` / `--co` / `--i` / `--log-` are the first letters that make a long option unique: every
      # longer spelling of --output, --compress-program, --in-place, --log-file contains them.
      sort) [[ $sego =~ [[:space:]](-[A-Za-z]*o|--o|--co) ]] && return 0 ;;
      uniq) _cg_uniq_writes "$sego" && return 0 ;;
      less|more) [[ $sego =~ [[:space:]](-[A-Za-z]*o|--log-) ]] && return 0 ;;
      sed) [[ $seg =~ [[:space:]](-[A-Za-z]*i|--i) ]] && return 0
           [[ $sego =~ [[:space:]](-[A-Za-z]*i|--i) ]] && return 0
           [[ ${sego#sed} =~ $_re_sedw_cmd ]] && return 0 ;;
      # git takes the rest as literal arguments (a commit message, a pathspec) - except an inline
      # `-c` (an alias.x='!sh' or a hooksPath) or a `!`, which make it run something, and the
      # forms that write a named file (_re_gitw_opt).
      git) shopt -u nocasematch   # `-C <dir>` is fine; only a lowercase `-c` is
           if [[ $seg =~ [[:space:]]-c[[:space:]=]|! ]] || [[ $sego =~ [[:space:]]-c([_[:space:]=]|$) ]]; then shopt -s nocasematch; return 0; fi
           shopt -s nocasematch
           [[ $sego =~ $_re_gitw_opt ]] && return 0 ;;
      gh)  [[ $seg =~ ^gh[[:space:]]+(pr|issue|release)[[:space:]] ]] || return 0
           [[ $sego =~ [[:space:]]download([_[:space:]]|$) ]] && return 0 ;;
      *) return 0 ;;
    esac
  done
  _PURE=1
}

# ── 5. the release signing key (shell) ──────────────────────────────────────
case "$_in" in
  *ssh-keygen*|*.ssh*)
    # 5a. the command names the private key file - scanned whole, inert or not (cat is the leak).
    _cg_key
    _cg_names_key "$_c" && _deny "a shell command on the release signing key ($_KEYB)" "$_WHY_KEY" "$_WHO_KEY" "$_HEB_KEY"
    # 5b. ssh-keygen -Y sign, any key. Case-sensitive for the flag (-y is a different act), so
    # the tool name is spelled as classes; `-qY sign` and `-Ysign` are the same getopt parse.
    shopt -u nocasematch
    _re_ysign="(^|[^A-Za-z0-9_.-])[Ss][Ss][Hh]-[Kk][Ee][Yy][Gg][Ee][Nn]([.][Ee][Xx][Ee])?[\"']?[[:space:]][^;&|]*-[A-Za-z]*Y[[:space:]]*[\"']?sign([^A-Za-z0-9_-]|\$)"
    if [[ $_c =~ $_re_ysign ]]; then
      shopt -s nocasematch
      _cg_pure_read
      [ "$_PURE" = 1 ] || _deny "ssh-keygen -Y sign (signing is the releaser's own act)" "$_WHY_KEY" "$_WHO_KEY" "$_HEB_KEY"
    fi
    shopt -s nocasematch ;;
esac

# ── 4. a write to a consent record ──────────────────────────────────────────
_rec=""
# Each name is looked for in the command as written (_c) and as the shell joins it (_cx: quotes,
# backslashes and backticks removed - round-3 finding 1, `.governance-sour""ce`).
_re_rn="\\.governance-update.*(^|[/[:space:]\"'=])(terms-accepted|close-push|auto-update)$_E"
_re_dir="${_B}(rm|mv|cp|ln|Remove-Item|Move-Item|Copy-Item|Rename-Item|ri|mi|cpi|rni|del|erase|rd|rmdir)[[:space:]][^;&|]*\\.governance-update/?([[:space:]\"';|&)]|\$)"
_re_nonce="\\.governance-(consent-selftest|source)$_E"
for _cs in "$_c" "$_cx"; do
  case "$_cs" in
    *governance-update*)
      _c2="${_cs//close-push.sh/}"
      [[ $_c2 =~ $_re_rn ]] && _rec="${BASH_REMATCH[2]}"
      if [ -z "$_rec" ] && [[ $_cs =~ $_re_dir ]]; then
        _rec=".governance-update (the directory)"; _deny "${BASH_REMATCH[2]} of $_rec" "$_WHY_REC"
      fi ;;
  esac
  [ -n "$_rec" ] && break
  [[ $_cs =~ $_re_nonce ]] && { _rec=".governance-${BASH_REMATCH[1]}"; break; }
done
# Windows short (8.3) names: `GOVERN~4/close-push` and `.governance-update/CLOSE-~1` reach the
# record (MEASURED 2026-09-30, header rule 3). `HEAD~1` never matches: a `/` must follow or precede.
if [ -z "$_rec" ]; then
  case "$_c" in
    *~[0-9]*)
      _c2="${_c//close-push.sh/}"
      _sn='[A-Za-z0-9_-]{1,6}~[0-9]+'
      _re_sn1="\\.governance-update/+($_sn)$_E"
      _re_sn2="(^|[/[:space:]\"'=])($_sn)/+(terms-accepted|close-push|auto-update)$_E"
      _re_sn3="\\.claude/+($_sn)/+($_sn)$_E"
      if   [[ $_c2 =~ $_re_sn1 ]]; then _rec="${BASH_REMATCH[1]} (a Windows short name)"
      elif [[ $_c2 =~ $_re_sn2 ]]; then _rec="${BASH_REMATCH[3]} (through the Windows short name ${BASH_REMATCH[2]})"
      elif [[ $_c2 =~ $_re_sn3 ]]; then _rec="${BASH_REMATCH[2]} (a Windows short name, in ${BASH_REMATCH[1]})"
      fi ;;
  esac
fi
# _cg_strip_null <var> -> the redirections to /dev/null / $null and the fd duplications removed.
_cg_strip_null() {
  local w="${!1}"
  while [[ $w =~ ([0-9&]?>>?[[:space:]]*(/dev/null|\$null)) ]]; do w="${w/"${BASH_REMATCH[1]}"/ }"; done
  w="${w//2>&1/ }"; w="${w//1>&2/ }"; w="${w//>&2/ }"
  printf -v "$1" '%s' "$w"
}
# a. an interpreter runs code the guard does not read: denied on sight (never in an inert command,
#    where every segment starts with a non-executing tool and `python` is only an argument).
_re_interp="${_BC}(python[0-9.]*|py|node|nodejs|deno|bun|perl|ruby|php|pwsh|powershell|osascript|tclsh|lua|awk|gawk|cmd|cscript|wscript|mshta)(\\.exe)?[\"']?([[:space:]]|\$)"
if [ -n "$_rec" ]; then
  _why="$_WHY_REC"; [ "$_rec" = ".governance-source" ] && _why="$_WHY_SRC"
  # An inert command (every segment a non-executing tool) is scanned WITHOUT its quoted text, so
  # `grep -n 'touch "$CH/.governance-source"' gov-release.sh` is a read. Anything that could run
  # its arguments (bash -c '...', ssh '...', python) is scanned whole, quotes included, and once
  # more as the shell joins it (_cx: `tou""ch` is touch).
  _cg_pure_read
  if [ "$_PURE" = 1 ]; then _w="$_PS"; else _w="$_c;$_cx"; fi
  _cg_strip_null _w
  if [ "$_PURE" != 1 ] && [[ $_w =~ $_re_interp ]]; then
    _deny "an interpreter (${BASH_REMATCH[2]}) in a command that names the consent record $_rec" "$_why"
  fi
  _tok=""
  case "$_w" in *'>'*) _tok='>' ;; esac
  if [ -z "$_tok" ]; then
    _re_wt="${_B}(tee|cp|mv|rm|ln|dd|touch|truncate)([[:space:]]|\$)"
    _re_sed="${_B}(sed|perl)[[:space:]]([^;&|]*[[:space:]])?(-[A-Za-z]*i|--i)"
    _re_wt2="${_BC}(install|rsync|tar|unzip|patch|xargs|find|mapfile|readarray)([[:space:]]|\$)"
    _re_mk="${_BC}(mkdir|md|New-Item|ni)([[:space:]]|\$)"
    _re_ps='(Set-Content|Add-Content|Clear-Content|Out-File|New-Item|Copy-Item|Move-Item|Rename-Item|Remove-Item|WriteAll)'
    if   [[ $_w =~ $_re_wt ]];  then _tok="${BASH_REMATCH[2]}"
    elif [[ $_w =~ $_re_sed ]]; then _tok="${BASH_REMATCH[2]} -i"
    elif [[ $_w =~ $_re_wt2 ]]; then _tok="${BASH_REMATCH[2]}"
    elif [ "$_rec" = ".governance-source" ] && [[ $_w =~ $_re_mk ]]; then _tok="${BASH_REMATCH[2]}"
    elif [[ $_w =~ $_re_ps ]];  then _tok="${BASH_REMATCH[1]}"
    fi
  fi
  # b'. the write FORMS of round 3 (finding 1). Only a command that is not inert can hold one: an
  #     inert command has none by construction (_cg_pure_read), so a grep PATTERN naming them is a
  #     read. The list is NOT closed (STATED LIMIT): a program not on it is out of reach.
  if [ -z "$_tok" ] && [ "$_PURE" != 1 ]; then
    _re_cw="${_BC}(curl|wget|aria2c|scp|sftp|xxd|openssl|gpg2?|iconv|script|cmake|ed|ex|vim?|nvim|nano|emacs|busybox|zip|7za?|cpio|pax|fsutil|certutil|bitsadmin|xcopy|robocopy)(\\.exe)?[\"']?([[:space:]]|\$)"
    _re_sorto="${_BC}sort(\\.exe)?[\"']?([[:space:]][^;&|]*)?[[:space:]](-[A-Za-z]*o|--o|--co)"
    _re_uniq2="${_BC}uniq(\\.exe)?[\"']?([[:space:]]+-[^;&|[:space:]]+)*[[:space:]]+[^-;&|[:space:]<>][^;&|[:space:]<>]*[[:space:]]+[^;&|[:space:]<>]"
    # `uniq - F` / `uniq -c - F`: a lone `-` (stdin) is an operand, not an option (round 4b).
    _re_uniq4="${_BC}uniq(\\.exe)?[\"']?([[:space:]]+-[^;&|[:space:]]+)*[[:space:]]+-[[:space:]]+[^;&|[:space:]<>]"
    # `uniq -- -x F`: after `--` the first operand may start with `-`.
    _re_uniq3="${_BC}uniq(\\.exe)?[\"']?([[:space:]][^;&|]*)?[[:space:]]--[[:space:]]+[^;&|[:space:]<>]+[[:space:]]+[^;&|[:space:]<>]"
    _re_sedw="${_BC}sed(\\.exe)?[\"']?[[:space:]][^|&]*$_re_sedw_cmd"
    _re_gitw="${_BC}git(\\.exe)?[\"']?([[:space:]][^;&|]*)?($_re_gitw_opt)"
    _re_keyf="${_BC}ssh-keygen(\\.exe)?[\"']?([[:space:]][^;&|]*)?[[:space:]]-[A-Za-z]*f"
    _re_ghd="${_BC}gh(\\.exe)?([[:space:]][^;&|]*)?[[:space:]]download([[:space:]]|\$)"
    _re_ps2='(Tee-Object|Export-[A-Za-z]+|Start-Transcript|-OutFile|::(Create[A-Za-z]*|AppendAll[A-Za-z]*|AppendText|Copy|Move|Replace|Open|OpenWrite|WriteAll[A-Za-z]*)[[:space:]]*\()'
    _re_psa="(^|[[:space:];&|({])(copy|cpi|ac|sc|ni|mi|move|ren|rni|del|erase|ri|rd|rmdir|iwr|irm|Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer)([[:space:]]|\$)"
    if   [[ $_w =~ $_re_sorto ]]; then _tok="sort ${BASH_REMATCH[4]}"
    elif [[ $_w =~ $_re_uniq2 ]]; then _tok="uniq IN OUT"
    elif [[ $_w =~ $_re_uniq3 ]]; then _tok="uniq -- IN OUT"
    elif [[ $_w =~ $_re_uniq4 ]]; then _tok="uniq - OUT"
    elif [[ $_w =~ $_re_sedw ]];  then _tok="sed w/e"
    elif [[ $_w =~ $_re_gitw ]];  then _tok="git, a write option"
    elif [[ $_w =~ $_re_keyf ]];  then _tok="ssh-keygen -f"
    elif [[ $_w =~ $_re_ghd ]];   then _tok="gh ... download"
    elif [[ $_w =~ $_re_cw ]];    then _tok="${BASH_REMATCH[2]}"
    elif [[ $_w =~ $_re_ps2 ]];   then _tok="${BASH_REMATCH[1]}"
    elif [ "$_tool" = PowerShell ] && [[ $_w =~ $_re_psa ]]; then _tok="${BASH_REMATCH[2]}"
    fi
  fi
  [ -n "$_tok" ] && _deny "a shell write ($_tok) to the consent record $_rec" "$_why"
fi
# a'. no record name in sight, but an interpreter runs in a command that names the directory (D4,
#     round-2 findings 6/16): `python -c "d=os.path.expanduser('~/.claude/.governance-update');
#     open(d+'/close'+'-push','w')"` builds the record name at run time (MEASURED: it wrote the
#     record past the rule above). The directory name is literal, so the act is in sight. An inert
#     command (`grep -n python ~/.claude/.governance-update/x`) is never scanned for this.
if [ -z "$_rec" ]; then
  case "$_c;$_cx" in
    *governance-update*)
      _cg_pure_read
      if [ "$_PURE" != 1 ]; then
        _w="$_c;$_cx"; _cg_strip_null _w
        if [[ $_w =~ $_re_interp ]]; then
          _deny "an interpreter (${BASH_REMATCH[2]}) in a command that names ~/.claude/.governance-update/ (a record name can be built at run time)" "$_WHY_REC"
        fi
      fi ;;
  esac
fi
# d. no record name in sight, but a redirection writes into the directory: the name is behind a
#    variable (`> ~/.claude/.governance-update/$f`) or the shell cd's there first (D4). Quote-aware
#    for an inert command: `grep -n '> .governance-update/' x.sh` is a read; `echo x > "$D/$f"` is not.
#    Round 3: a quoted target (`> '...'`) and a quote INSIDE a word (`.governance-upd"a"te`,
#    `.governance-upd""ate`) are joined as the shell joins them; a quoted string after a blank
#    (a grep pattern) is still literal text.
if [ -z "$_rec" ]; then
  case "$_c;$_cx" in
    *governance-update*'>'*|*'>'*governance-update*)
      _cg_pure_read
      _s="$_c"
      if [ "$_PURE" = 1 ]; then
        _s="${_s//\"\"/}"; _s="${_s//\'\'/}"
        while [[ $_s =~ (\>\>?[[:space:]]*|[^[:space:]\;\&\|\<\>\"\'])?\'([^\']*)\' ]]; do
          _m="${BASH_REMATCH[0]}"; _rp=Q
          case "${BASH_REMATCH[1]}" in '') ;; '>'*) _rp="> ${BASH_REMATCH[2]}" ;; *) _rp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}" ;; esac
          _s="${_s/"$_m"/"$_rp"}"
        done
        while [[ $_s =~ (\>\>?[[:space:]]*|[^[:space:]\;\&\|\<\>\"\'])?\"([^\"]*)\" ]]; do
          _m="${BASH_REMATCH[0]}"; _rp=Q
          case "${BASH_REMATCH[1]}" in '') ;; '>'*) _rp="> ${BASH_REMATCH[2]}" ;; *) _rp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}" ;; esac
          _s="${_s/"$_m"/"$_rp"}"
        done
      else
        _s="$_c;$_cx"; _s="${_s//\"/}"; _s="${_s//\'/}"
      fi
      _cg_strip_null _s
      _re_to='>>?[[:space:]]*[^;&|[:space:]<>]*governance-update'
      _re_cd="${_BC}(cd|pushd|chdir|Set-Location|sl|Push-Location)[[:space:]]+[^;&|]*governance-update"
      _re_rel='>>?[[:space:]]*([^/~[:space:];&|<>]|$)'
      _re_abs='>>?[[:space:]]*[A-Za-z]:/'
      if [[ $_s =~ $_re_to ]]; then
        _deny "a redirection into ~/.claude/.governance-update/ (the record name is hidden behind a variable)" "$_WHY_REC"
      elif [[ $_s =~ $_re_cd ]] && [[ $_s =~ $_re_rel ]] && ! [[ $_s =~ $_re_abs ]]; then
        _deny "a redirection into ~/.claude/.governance-update/ (the shell changes into it first; the record name is hidden behind a variable)" "$_WHY_REC"
      fi ;;
  esac
fi

# ── 1. a consent command ────────────────────────────────────────────────────
_re_script="${_B}(install|gov-update|close-push)\\.sh"
_re_flag="(--accept-terms|--enable-(close-push|auto-update)|--accept-auto-update-waiver|GOV_ACCEPT_TERMS[[:space:]]*=|(^|[[:space:]\"'])--enable$_E)"
for _cs in "$_c" "$_cx"; do   # as written, then as the shell joins it (`--accept-te""rms`)
  if [[ $_cs =~ $_re_script ]]; then
    _script="${BASH_REMATCH[2]}.sh"
    if [[ $_cs =~ $_re_flag ]]; then
      _flag="${BASH_REMATCH[1]}"; _flag="${_flag#[[:space:]\"\']}"
      _cg_pure_read
      [ "$_PURE" = 1 ] || _deny "$_script with $_flag" "$_WHY_CMD"
    fi
  fi
done

# ── 2. marker stripping ─────────────────────────────────────────────────────
case "$_c;$_cx" in
  *CLAUDECODE*|*AI_AGENT*|*CLAUDE_CODE_ENTRYPOINT*|*env*)
    _M='(CLAUDECODE|AI_AGENT|CLAUDE_CODE_ENTRYPOINT)'
    _hit=""
    _re_envu="${_B}env[[:space:]][^;&|]*(-u[[:space:]]*|--unset[=[:space:]]+)$_M([^A-Za-z0-9_]|\$)"
    _re_unset="${_B}(unset|export[[:space:]]+-n|declare[[:space:]]+\\+x|typeset[[:space:]]+\\+x)[[:space:]][^;&|]*$_M([^A-Za-z0-9_]|\$)"
    _re_asg="(^|[^A-Za-z0-9_\$:{.-])$_M="
    _re_psenv="\\\$env:$_M[[:space:]]*=([^=]|\$)"
    _re_psrm="${_B}(Remove-Item|Clear-Item|Set-Item|Remove-ItemProperty|ri|rm|del|erase|rd|rmdir|rp|cli|si)[[:space:]][^;&|]*env:/?$_M"
    _re_setenv="SetEnvironmentVariable\\([[:space:]]*['\"]$_M"
    _re_envi="${_B}env[[:space:]]+(-[A-Za-z]*i|--ignore-environment|-)([[:space:]]|\$)"
    for _cs in "$_c" "$_cx"; do   # as written, then as the shell joins it (`env -u CLAUDE""CODE`)
      if   [[ $_cs =~ $_re_envu ]];   then _hit="env -u ${BASH_REMATCH[3]}"
      elif [[ $_cs =~ $_re_unset ]];  then _hit="${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
      elif [[ $_cs =~ $_re_asg ]];    then _hit="${BASH_REMATCH[2]}= (blanked or overwritten)"
      elif [[ $_cs =~ $_re_psenv ]];  then _hit="\$env:${BASH_REMATCH[1]}="
      elif [[ $_cs =~ $_re_psrm ]];   then _hit="${BASH_REMATCH[2]} Env:${BASH_REMATCH[3]}"
      elif [[ $_cs =~ $_re_setenv ]]; then _hit="SetEnvironmentVariable ${BASH_REMATCH[1]}"
      elif [[ $_cs =~ $_re_envi ]] && [[ $_cs =~ $_re_script ]]; then _hit="env -i with ${BASH_REMATCH[2]}.sh"
      fi
      [ -n "$_hit" ] && break
    done
    if [ -n "$_hit" ]; then
      _cg_pure_read
      [ "$_PURE" = 1 ] || _deny "AI-agent marker stripping ($_hit)" "$_WHY_MARK"
    fi ;;
esac
exit 0
