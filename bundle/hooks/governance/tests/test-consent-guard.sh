#!/usr/bin/env bash
# test-consent-guard.sh - consent-guard.sh denies a session the consent acts, in both directions.
#
# WHY (2026-09-30, legal conditions S1 / C3 / T4). The scripts refuse an acceptance inside an
# AI-agent session by reading the markers Claude Code sets; a session could strip them in the same
# command, or write the one-line record itself. consent-guard.sh is the PreToolUse deny for both.
# Must-block and must-allow are asserted on the PRINTED text (stderr, the log), not only on rc: a
# guard that also blocked reads would be switched off, and one that let the acts through is absent.
#
# Sandboxed HOME. Usage: bash tests/test-consent-guard.sh   (HOOKS=<dir> for another copy)
HOOKS="${HOOKS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GUARD="$HOOKS/consent-guard.sh"
exec </dev/null
SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
H="$SBX/home"; mkdir -p "$H/.claude/logs"
LOG="$H/.claude/logs/governance.log"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s  -- %s\n' "$1" "$2"; }
[ -f "$GUARD" ] || { bad "guard exists" "$GUARD"; echo "consent-guard selftest: pass=$PASS fail=$FAIL"; exit 1; }

jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
NL=$'\n'
payload() {  # payload <tool> <tool_input-json>
  printf '{"session_id":"sid-cg","transcript_path":"","cwd":"/c/repo","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2"
}
cmdin()  { printf '{"command":"%s","description":"test"}' "$(jesc "$1")"; }
filein() { printf '{"file_path":"%s","content":"x"}' "$(jesc "$1")"; }
ERR="$SBX/stderr"
RUN_ENV=()
run() { env -u GOVERNANCE_HOOKS -u GOV_CONSENT_GUARD -u GOV_BYPASS_QUIET -u GOVERNANCE_LOG -u GOV_RELEASE_KEY \
          HOME="$H" GOVERNANCE_LOG="$LOG" ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$GUARD" 2>"$ERR"; }
# block <name> <payload> <text the reason must contain>
block() {
  printf '%s' "$2" | run; local rc=$?
  if [ "$rc" = 2 ] && grep -qF '[GOVERNANCE CONSENT GUARD] BLOCKED:' "$ERR" && grep -qF -- "$3" "$ERR" \
     && grep -qF 'שומר הסכמה' "$ERR" && grep -qF 'GOV_CONSENT_GUARD=0' "$ERR"; then
    ok "BLOCK $1"
  else bad "BLOCK $1" "rc=$rc want 2, want [$3]; stderr: $(head -c 300 "$ERR" | tr '\n' '|')"; fi
}
# allow <name> <payload>
allow() {
  printf '%s' "$2" | run; local rc=$?
  if [ "$rc" = 0 ] && ! grep -q 'BLOCKED' "$ERR"; then ok "allow $1"
  else bad "allow $1" "rc=$rc want 0; stderr: $(head -c 300 "$ERR" | tr '\n' '|')"; fi
}
B() { block "Bash: $1" "$(payload Bash "$(cmdin "$1")")" "$2"; }
P() { block "PowerShell: $1" "$(payload PowerShell "$(cmdin "$1")")" "$2"; }
AB() { allow "Bash: $1" "$(payload Bash "$(cmdin "$1")")"; }
AP() { allow "PowerShell: $1" "$(payload PowerShell "$(cmdin "$1")")"; }

echo "== 1. consent commands are denied (scanned whole: ssh / bash -c / powershell -c)"
B "bash install.sh --accept-terms"                                     "install.sh with --accept-terms"
grep -qF "is not the user's consent" "$ERR" && grep -qF "a safeguard, not a guarantee" "$ERR" \
  && grep -qF "Tell the user the exact command" "$ERR" && grep -qF "typed in their own terminal" "$ERR" \
  && ok "the block is addressed to the human, in the honest safeguard form (D1, round-2 finding 14)" || bad "block wording" "$(head -c 400 "$ERR")"
grep -qiE "cannot (accept|turn|enable)|agent cannot" "$ERR" \
  && bad "the block still says an agent CANNOT act (round-2 finding 14)" "$(head -c 400 "$ERR" | tr '\n' '|')" \
  || ok "the block makes no 'an AI agent cannot' claim (round-2 finding 14)"
grep -qF "החלטה שלך, בטרמינל שלך" "$ERR" && ! grep -qF "רק אתה יכול" "$ERR" \
  && ok "the Hebrew line states the user's decision, not a 'only you can' claim" || bad "Hebrew consent line" "$(sed -n 4p "$ERR")"
B "GOV_ACCEPT_TERMS=1 bash ~/.claude/governance-installer/install.sh --force" "install.sh with GOV_ACCEPT_TERMS"
B "bash close-push.sh --enable"                                        "close-push.sh with --enable"
B "ssh box 'bash install.sh --accept-terms'"                           "install.sh with --accept-terms"
B "bash -c \"cd ~/.claude/hooks/governance && bash gov-update.sh --accept-terms\"" "gov-update.sh with --accept-terms"
P "powershell -c \"bash install.sh --enable-close-push\""              "install.sh with --enable-close-push"
B "bash install.sh --enable-auto-update"                               "--enable-auto-update"
B "bash install.sh --accept-auto-update-waiver --force"                "--accept-auto-update-waiver"
B "bash ~/.claude/hooks/governance/close-push.sh --enable </dev/null"  "close-push.sh with --enable"
B "grep -n x install.sh; bash install.sh --accept-terms"               "install.sh with --accept-terms"
B "echo \$(bash install.sh --accept-terms)"                            "install.sh with --accept-terms"
P "& 'C:\\Program Files\\Git\\bin\\bash.exe' install.sh --accept-terms" "install.sh with --accept-terms"
B "git commit -m \"\$(cat <<EOF${NL}\$(bash install.sh --accept-terms)${NL}EOF${NL})\"" "install.sh with --accept-terms"
B "git -c alias.x='!bash install.sh --accept-terms' x"                "install.sh with --accept-terms"
B "git commit -m \"\$(cat <<'EOF'${NL}msg${NL}EOF${NL})\"; bash install.sh --accept-terms" "install.sh with --accept-terms"
B "bash install.sh <<'EOF'${NL}x${NL}EOF${NL} --accept-terms"          "install.sh with --accept-terms"
B "GOV_ACCEPT_TERMS=1; export GOV_ACCEPT_TERMS; bash install.sh --force" "install.sh with GOV_ACCEPT_TERMS"
B "X=1 && bash install.sh --accept-terms"                              "install.sh with --accept-terms"
grep -qF "BLOCK install.sh with --accept-terms (tool=PowerShell)" "$LOG" && ok "the block is logged" || bad "block logged" "$(tail -2 "$LOG")"

echo "== 2. marker stripping is denied in any command"
B "env -u CLAUDECODE bash x"                                           "marker stripping (env -u CLAUDECODE)"
B "unset AI_AGENT; bash x.sh"                                          "marker stripping (unset AI_AGENT)"
P "Remove-Item Env:CLAUDECODE"                                         "marker stripping (Remove-Item Env:CLAUDECODE)"
P "Remove-Item -Path Env:\\CLAUDE_CODE_ENTRYPOINT; bash x.sh"          "Env:CLAUDE_CODE_ENTRYPOINT"
P "\$env:CLAUDECODE=''; bash install.sh"                               "\$env:CLAUDECODE="
P "[Environment]::SetEnvironmentVariable('AI_AGENT', \$null)"          "SetEnvironmentVariable AI_AGENT"
B "CLAUDECODE= AI_AGENT= bash install.sh --force"                      "CLAUDECODE= (blanked"
B "export CLAUDE_CODE_ENTRYPOINT=; bash x"                             "CLAUDE_CODE_ENTRYPOINT="
B "export -n AI_AGENT && bash x"                                       "AI_AGENT"
B "env --unset=CLAUDECODE bash x"                                      "env -u CLAUDECODE"
B "env -i PATH=/usr/bin bash install.sh --force"                       "env -i with install.sh"
B "ssh box 'unset CLAUDECODE; bash install.sh'"                        "unset CLAUDECODE"

echo "== 3. file tools on a consent record are denied (path decides; case- and slash-insensitive)"
block "Write C:\\Users\\x\\.claude\\.governance-update\\close-push" \
  "$(payload Write "$(filein 'C:\Users\x\.claude\.governance-update\close-push')")" "Write of a consent record (close-push)"
block "Edit ~/.claude/.governance-update/terms-accepted" \
  "$(payload Edit '{"file_path":"/home/u/.claude/.governance-update/terms-accepted","old_string":"a","new_string":"b"}')" "Edit of a consent record (terms-accepted)"
block "MultiEdit auto-update record" \
  "$(payload MultiEdit '{"file_path":"/home/u/.claude/.governance-update/auto-update","edits":[]}')" "(auto-update)"
block "Write mixed-case C:\\...\\.Governance-Update\\Terms-Accepted" \
  "$(payload Write "$(filein 'C:\Users\x\.claude\.Governance-Update\Terms-Accepted')")" "consent record"
block "Write the selftest nonce ~/.governance-consent-selftest" \
  "$(payload Write "$(filein '/home/u/.governance-consent-selftest')")" "(.governance-consent-selftest)"
block "Write the source-machine marker ~/.claude/.governance-source" \
  "$(payload Write "$(filein '/home/u/.claude/.governance-source')")" "(.governance-source)"
block "NotebookEdit notebook_path on a record" \
  "$(payload NotebookEdit '{"notebook_path":"/home/u/.claude/.governance-update/close-push","new_source":"x"}')" "consent record"

echo "== 4. shell writes to a consent record are denied; reads pass"
B "printf 'enabled=1' > ~/.claude/.governance-update/close-push"       "shell write (>) to the consent record close-push"
P "Set-Content C:\\Users\\x\\.claude\\.governance-update\\terms-accepted 'terms_version=1'" "(Set-Content) to the consent record terms-accepted"
B "cd ~/.claude/.governance-update && echo enabled=1 > close-push"     "consent record close-push"
B "cp /tmp/planted ~/.claude/.governance-update/terms-accepted"        "(cp) to the consent record terms-accepted"
B "mv ~/.claude/.governance-update/close-push.tmp.1 ~/.claude/.governance-update/close-push" "consent record close-push"
B "sed -i 's/enabled=0/enabled=1/' ~/.claude/.governance-update/close-push" "(sed -i)"
B "rm -f ~/.claude/.governance-update/terms-accepted"                  "(rm)"
B "rm -rf ~/.claude/.governance-update"                                "rm of .governance-update (the directory)"
B "echo n > ~/.governance-consent-selftest"                            ".governance-consent-selftest"
B "touch ~/.claude/.governance-source"                                 "(touch) to the consent record .governance-source"
B "cat ~/.claude/.governance-update/close-push | tee ~/.claude/.governance-update/terms-accepted" "consent record"
P "echo 'enabled=1' | Out-File -FilePath \$HOME\\.claude\\.governance-update\\close-push" "(Out-File) to the consent record close-push"
B "echo enabled=1 >> ~/.claude/.governance-update/close-push"          "(>) to the consent record close-push"
B "echo 'enabled=1' > \"\$HOME/.claude/.governance-update/close-push\"" "(>) to the consent record close-push"
B "bash -c 'echo enabled=1 > ~/.claude/.governance-update/close-push'" "(>) to the consent record close-push"
B "ssh box \"touch ~/.claude/.governance-source\""                     "(touch) to the consent record .governance-source"

echo "== 5. must allow: ordinary work, closes, reads, the documented off switches"
AB "bash install.sh --force"
AB "bash ~/.claude/governance-installer/install.sh --force --no-claude-md"
AB "bash close-push.sh -C /repo"
AB "bash ~/.claude/hooks/governance/close-push.sh --disable"
AB "bash ~/.claude/hooks/governance/close-push.sh --selftest </dev/null > /tmp/cp.log 2>&1"
AB "cat ~/.claude/.governance-update/close-push"
AB "cat ~/.claude/.governance-update/terms-accepted 2>/dev/null"
AB "cat ~/.claude/.governance-update/close-push; echo rc=\$?"
AB "G=~/.claude/hooks/governance/gov-release.sh; grep -n 'touch \"\$CH/.governance-source\"\\|x > y' \$G"
AB "grep -c 'enabled=1 > ' ~/.claude/.governance-update/close-push"
AB "grep -rn -- '--enable-close-push' install.sh; echo rc=\$?"
AB "sha256sum ~/.claude/.governance-update/terms-accepted; ls -la ~/.claude/.governance-update"
AB "ls ~/.claude/.governance-update; bash close-push.sh --selftest > log.txt"
AB "bash ~/.claude/hooks/governance/gov-update.sh --status"
AB "bash ~/.claude/hooks/governance/gov-update.sh --fetch"
AB "git push"
AB "git push origin HEAD && git status"
AB "grep -rn -- '--accept-terms' install.sh"
AB "grep -rn 'GOV_AUTO_UPDATE\\|--enable-auto-update\\|apply-at-session-end' bundle/ install.sh verify.sh README.md"
AB "cd /c/repo && git grep -n -- --enable-close-push -- install.sh | head -5"
AB "sed -n '1,40p' install.sh | grep -n GOV_ACCEPT_TERMS="
AB "grep -n 'env -u CLAUDECODE' tests/*.sh"
AB "git add install.sh close-push.sh && git commit -m \"\$(cat <<'EOF'${NL}install.sh --accept-terms and close-push.sh --enable refuse in a session; env -u CLAUDECODE is denied${NL}EOF${NL})\" && git show --stat HEAD"
AB "gh pr create --title x --body \"close-push.sh --enable is the user's own act\""
AB "P=\"install.sh verify.sh\" && git add -- \$P && git commit -q -F - <<'EOF'${NL}2.0.0: install.sh --accept-terms refuses in a session${NL}EOF"
AB "git -C /c/repo log --grep=--accept-terms -- install.sh"
AB "echo \$CLAUDECODE; [ -n \"\$AI_AGENT\" ] && echo agent"
AB "env -u CLAUDE_PROJECT_DIR -u GOV_SESSION_ID bash tests/test-x.sh"
AB "bash tests/test-consent-guard.sh"
AB "ls -la"
AP "Get-Content \$env:USERPROFILE\\.claude\\.governance-update\\close-push"
AP "Select-String -Pattern '--accept-terms' -Path install.sh"
allow "Edit docs/context/HANDOFF.md" "$(payload Edit '{"file_path":"C:\\dev\\example-project\\docs\\context\\HANDOFF.md","old_string":"a","new_string":"b"}')"
allow "Write ~/.claude/.governance-update/REPORT (not a consent record)" "$(payload Write "$(filein '/home/u/.claude/.governance-update/REPORT')")"
allow "Read of a record" "$(payload Read '{"file_path":"/home/u/.claude/.governance-update/close-push"}')"
content=$(head -c 150000 /dev/zero | tr '\0' 'a')
allow "150 KB Write to a normal file naming the record in its content" \
  "$(payload Write "{\"file_path\":\"/x/notes.md\",\"content\":\"see ~/.claude/.governance-update/close-push $content\"}")"

echo "== 6. kill switches and fail-open"
p_bad="$(payload Bash "$(cmdin "bash install.sh --accept-terms")")"
RUN_ENV=(GOVERNANCE_HOOKS=0)
printf '%s' "$p_bad" | run; rc=$?
[ "$rc" = 0 ] && grep -qF "GOVERNANCE_HOOKS=0" "$ERR" && grep -qF "bypassing consent-guard" "$ERR" \
  && ok "GOVERNANCE_HOOKS=0 -> allow with the loud notice" || bad "GOVERNANCE_HOOKS=0" "rc=$rc; $(head -c 200 "$ERR")"
RUN_ENV=(GOV_CONSENT_GUARD=0)
printf '%s' "$p_bad" | run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$ERR" ] && ok "GOV_CONSENT_GUARD=0 -> allow silently" || bad "GOV_CONSENT_GUARD=0" "rc=$rc; $(head -c 200 "$ERR")"
RUN_ENV=(GOV_CONSENT_GUARD=1)
printf '%s' "$p_bad" | run; rc=$?
[ "$rc" = 2 ] && ok "GOV_CONSENT_GUARD=1 -> the guard is on (control)" || bad "GOV_CONSENT_GUARD=1" "rc=$rc"
RUN_ENV=()
: > "$LOG"
printf 'not json bash install.sh --accept-terms' | run; rc=$?
[ "$rc" = 0 ] && ! grep -q BLOCKED "$ERR" && grep -qF "payload is not a JSON object" "$LOG" && grep -qF "failing OPEN" "$LOG" \
  && ok "non-JSON payload -> fail OPEN with a logged warning" || bad "non-JSON fail-open" "rc=$rc; log: $(cat "$LOG")"
printf '{"tool_input":{"command":"bash install.sh --accept-terms"}}' | run; rc=$?
[ "$rc" = 0 ] && grep -qF "no tool_name" "$LOG" && ok "no tool_name -> fail OPEN with a logged warning" || bad "no tool_name" "rc=$rc; $(cat "$LOG")"
# A HOME with no logs dir: the block must still print only its own text (no shell error line).
H2="$SBX/home2"; mkdir -p "$H2/.claude"
printf '%s' "$p_bad" | env -u GOVERNANCE_HOOKS -u GOV_CONSENT_GUARD HOME="$H2" GOVERNANCE_LOG="$H2/.claude/logs/governance.log" bash "$GUARD" 2>"$ERR"; rc=$?
[ "$rc" = 2 ] && ! grep -q "No such file" "$ERR" && head -1 "$ERR" | grep -qF '[GOVERNANCE CONSENT GUARD] BLOCKED:' \
  && ok "missing log dir: block still clean on stderr" || bad "missing log dir" "rc=$rc; $(head -c 200 "$ERR")"

echo "== 7. the release signing key (TG2, legal S3c / C7c): read of the key and any ssh-keygen -Y sign"
# The key path comes from ~/.claude/.governance-local.env (gov_local_env_get, comment stripped) or
# the process env. The file does not have to exist: the guard decides on the name, never reads it.
KB="gov-release-test_ed25519"
printf '# local only\nGOV_RELEASE_KEY=~/.ssh/%s   # the release key\n' "$KB" > "$H/.claude/.governance-local.env"
readin() { printf '{"file_path":"%s"}' "$(jesc "$1")"; }
RK() { block "Read $1" "$(payload Read "$(readin "$1")")" "Read of the release signing key ($KB)"; }
AR() { allow "Read $1" "$(payload Read "$(readin "$1")")"; }
KEYMSG="a shell command on the release signing key ($KB)"
SIGNMSG="ssh-keygen -Y sign (signing is the releaser's own act)"
# must BLOCK - the private key
RK "$H/.ssh/$KB"
grep -qF "a session does not read the release" "$ERR" && grep -qF "never reads the private key" "$ERR" \
  && grep -qF "חתימה על גרסה היא פעולה שלך" "$ERR" && ! grep -qF "is not the user's consent" "$ERR" \
  && ok "the key block carries its own human + Hebrew lines (not the consent text)" || bad "key block wording" "$(head -c 400 "$ERR" | tr '\n' '|')"
grep -qiE "agent cannot|cannot read the release key" "$ERR" \
  && bad "the key block still says an agent CANNOT read the key (round-2 finding 14)" "$(head -c 400 "$ERR" | tr '\n' '|')" \
  || ok "the key block makes no 'an AI agent cannot' claim; it says safeguard, not guarantee"
grep -qF "BLOCK Read of the release signing key ($KB) (tool=Read)" "$LOG" && ok "the key block is logged" || bad "key block logged" "$(tail -2 "$LOG")"
RK "C:\\Users\\x\\.ssh\\$KB"
RK "C:\\Users\\x\\.SSH\\GOV-RELEASE-TEST_ED25519"
B  "cat ~/.ssh/$KB"                                                      "$KEYMSG"
B  "cp ~/.ssh/$KB /tmp/k"                                                "$KEYMSG"
B  "cd ~/.ssh && base64 $KB"                                             "$KEYMSG"
B  "ssh-keygen -y -f ~/.ssh/$KB"                                         "$KEYMSG"
P  "Get-Content \$env:USERPROFILE\\.ssh\\$KB"                            "$KEYMSG"
P  "Copy-Item C:\\Users\\x\\.ssh\\$KB C:\\tmp\\k"                        "$KEYMSG"
B  "ssh-keygen -Y sign -f ~/.ssh/$KB -n claude-code-governance-release m" "release signing key"
# must BLOCK - signing with any key, however it is wrapped
B  "ssh-keygen -Y sign -f /tmp/t/throwaway -n ns m"                      "$SIGNMSG"
B  "ssh-keygen -q -Ysign -f relkey -n ns MANIFEST </dev/null"            "$SIGNMSG"
B  "ssh-keygen -qY sign -f relkey -n ns MANIFEST"                        "$SIGNMSG"
B  "env -u SSH_AUTH_SOCK ssh-keygen -Y sign -f \"\$KEY\" -n ns RELEASE-MANIFEST" "$SIGNMSG"
B  "echo m | ssh-keygen -Y sign -f k -n ns"                              "$SIGNMSG"
B  "ssh box 'ssh-keygen -Y sign -f k -n ns m'"                           "$SIGNMSG"
B  "ssh-keygen -Y sign 2>&1 | head -2"                                   "$SIGNMSG"
B  "d=\$(mktemp -d); cd \$d; ssh-keygen -Y \"sign\" -f relkey -n ns m"   "$SIGNMSG"
P  "& 'C:\\Windows\\System32\\OpenSSH\\ssh-keygen.exe' -Y sign -f k -n ns m" "$SIGNMSG"
P  "SSH-KEYGEN.EXE -Y sign -f k -n ns m"                                  "$SIGNMSG"
# must BLOCK - the key named in the process env (no local env file needed)
RUN_ENV=(GOV_RELEASE_KEY=/opt/example-project/.ssh/relkey_ed25519)
block "Bash: cat of a process-env key" "$(payload Bash "$(cmdin "cat /opt/example-project/.ssh/relkey_ed25519")")" "release signing key (relkey_ed25519)"
RUN_ENV=()
# must ALLOW - the .pub, verification, other ssh-keygen acts, other .ssh files, inert mentions
AR "$H/.ssh/$KB.pub"
AR "C:\\Users\\x\\.ssh\\$KB.pub"
AR "$H/.ssh/known_hosts"
AR "/x/docs/notes.md"
AB "cat ~/.ssh/$KB.pub"
AB "ssh-keygen -lf ~/.ssh/$KB.pub"
AB "ssh-keygen -Y verify -f allowed_signers -I gov -n ns -s m.sig < m"
AB "ssh-keygen -Y check-novalidate -n ns -s m.sig < m"
AB "ssh-keygen -y -f /tmp/other_key"
AB "ssh-keygen -q -t ed25519 -N '' -f /tmp/t/throwaway -C sign"
AB "ls -la ~/.ssh"
AB "ssh -i ~/.ssh/id_deploy box uptime"
AB "grep -n 'ssh-keygen -Y sign' gov-release.sh"
AB "git commit -m \"ssh-keygen -Y sign runs only in the signer's terminal\""
AP "Get-ChildItem \$env:USERPROFILE\\.ssh"
# must ALLOW - no key configured: the key rule is off, the sign rule is not
H3="$SBX/home3"; mkdir -p "$H3/.claude/logs"
printf '%s' "$(payload Read "$(readin "$H3/.ssh/$KB")")" | env -u GOV_RELEASE_KEY -u GOV_CONSENT_GUARD -u GOVERNANCE_HOOKS HOME="$H3" GOVERNANCE_LOG="$H3/.claude/logs/governance.log" bash "$GUARD" 2>"$ERR"; rc=$?
[ "$rc" = 0 ] && ! grep -q BLOCKED "$ERR" && ok "GOV_RELEASE_KEY unset -> a Read of that name is allowed" || bad "unset key allow" "rc=$rc; $(head -c 200 "$ERR")"
printf '%s' "$(payload Bash "$(cmdin "ssh-keygen -Y sign -f k m")")" | env -u GOV_RELEASE_KEY -u GOV_CONSENT_GUARD -u GOVERNANCE_HOOKS HOME="$H3" GOVERNANCE_LOG="$H3/.claude/logs/governance.log" bash "$GUARD" 2>"$ERR"; rc=$?
[ "$rc" = 2 ] && grep -qF "$SIGNMSG" "$ERR" && ok "GOV_RELEASE_KEY unset -> -Y sign still BLOCKED" || bad "unset key sign" "rc=$rc; $(head -c 200 "$ERR")"
# consent-lib.sh missing beside the guard: 5a fails OPEN (logged), 5b still denies
LONE="$SBX/lone"; mkdir -p "$LONE"; cp "$GUARD" "$LONE/consent-guard.sh"
: > "$LOG"
printf '%s' "$(payload Read "$(readin "$H/.ssh/$KB")")" | env -u GOV_RELEASE_KEY -u GOV_CONSENT_GUARD -u GOVERNANCE_HOOKS HOME="$H" GOVERNANCE_LOG="$LOG" bash "$LONE/consent-guard.sh" 2>"$ERR"; rc=$?
[ "$rc" = 0 ] && ! grep -q BLOCKED "$ERR" && grep -qF "consent-lib.sh not found" "$LOG" && grep -qF "failing OPEN" "$LOG" \
  && ok "no consent-lib.sh -> key Read fails OPEN with a logged warning" || bad "no-lib fail-open" "rc=$rc; log: $(cat "$LOG")"
printf '%s' "$(payload Bash "$(cmdin "ssh-keygen -Y sign -f k m")")" | env -u GOV_RELEASE_KEY -u GOV_CONSENT_GUARD -u GOVERNANCE_HOOKS HOME="$H" GOVERNANCE_LOG="$LOG" bash "$LONE/consent-guard.sh" 2>"$ERR"; rc=$?
[ "$rc" = 2 ] && grep -qF "$SIGNMSG" "$ERR" && ok "no consent-lib.sh -> -Y sign still BLOCKED" || bad "no-lib sign" "rc=$rc; $(head -c 200 "$ERR")"
# the kill switch reaches the new rules too
RUN_ENV=(GOV_CONSENT_GUARD=0)
printf '%s' "$(payload Read "$(readin "$H/.ssh/$KB")")" | run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$ERR" ] && ok "GOV_CONSENT_GUARD=0 -> key Read allowed silently" || bad "kill switch key" "rc=$rc; $(head -c 200 "$ERR")"
RUN_ENV=()

echo "== 8. round-1 review (findings 15/17/18/19, D4): normalised paths, interpreters, mkdir, hidden names"
W() { block "Write $1" "$(payload Write "$(filein "$1")")" "$2"; }
AW() { allow "Write $1" "$(payload Write "$(filein "$1")")"; }
REC_CP="Write of a consent record (close-push)"
# 8a. file tools: the path is normalised before it is compared (finding 19)
W 'C:\Users\x\.claude\.governance-update\.\close-push'                 "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\x\..\close-push'              "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\close-push.'                  "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\close-push...'                "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\close-push '                  "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\close-push. . '               "$REC_CP"
W '/home/u/.claude/.governance-update/./terms-accepted'                "Write of a consent record (terms-accepted)"
W '/home/u/.claude/.governance-update/a/b/../../close-push'            "$REC_CP"
W '/home/u/.claude/.governance-update/a/../../.governance-update/close-push' "$REC_CP"
W '/home/u/.claude/.governance-update//close-push/'                    "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\CLOSE-PUSH'                   "Write of a consent record (CLOSE-PUSH)"
W 'C:\Users\x\.claude\.governance-update\close-push:evil'              "Write of a consent record (close-push:evil)"
W '/home/u/.claude/./x/../.governance-source'                          "Write of a consent record (.governance-source)"
# Windows short (8.3) names reach the same file (MEASURED 2026-09-30 on this machine: 8dot3 is on,
# .governance-update = GOVERN~4, close-push = CLOSE-~1; a write through either replaced the record).
W 'C:\Users\x\.claude\GOVERN~4\close-push'                             "$REC_CP"
W 'C:\Users\x\.claude\.governance-update\CLOSE-~1'                     "Write of a consent record by a Windows short name (CLOSE-~1)"
W 'C:\Users\x\.claude\GOVERN~4\TERMS-~1'                               "Write of a consent record by a Windows short name (TERMS-~1)"
# 8a. must allow
AW '/home/u/.claude/.governance-update/close-pushx'
AW '/home/u/.claude/.governance-update/close-push.sh'
AW '/home/u/.claude/.governance-update/../close-push'
AW '/x/docs/close-push'
AW 'C:\Users\x\.claude\GOVERN~1\README.md'
AW 'C:\Users\x\PROGRA~1\notes\CLOSE-~1'
allow "Read of .governance-update/./close-push" "$(payload Read '{"file_path":"/home/u/.claude/.governance-update/./close-push"}')"
# 8b. interpreters that name a record: the guard cannot see what they write (findings 15, 18)
B "python3 -c \"import os;open(os.path.expanduser('~/.claude/.governance-update/close-push'),'w').write('enabled=1 terms_version=1')\"" \
  "an interpreter (python3) in a command that names the consent record close-push"
grep -qF "or by an interpreter whose code the guard does not see into - is denied on sight" "$ERR" \
  && ok "the interpreter block explains itself (_WHY_REC)" || bad "interpreter why-line" "$(head -c 400 "$ERR" | tr '\n' '|')"
B "node -e \"require('fs').writeFileSync(require('os').homedir()+'/.claude/.governance-update/terms-accepted','terms_version=1')\"" \
  "an interpreter (node) in a command that names the consent record terms-accepted"
B "perl -e 'open(F,\">\$ENV{HOME}/.claude/.governance-update/close-push\")'" "an interpreter (perl) in a command that names the consent record close-push"
B "python3 - <<'EOF'${NL}open('/home/u/.claude/.governance-update/close-push','w').write('enabled=1')${NL}EOF" \
  "an interpreter (python3) in a command that names the consent record close-push"
B "python3 write.py ~/.claude/.governance-update/close-push"            "an interpreter (python3) in a command that names the consent record close-push"
B "ruby -e 'File.write(Dir.home+\"/.claude/.governance-update/close-push\",\"enabled=1\")'" "an interpreter (ruby)"
B "echo enabled=1 | python -c \"import sys;open('/h/.claude/.governance-update/close-push','w').write(sys.stdin.read())\"" "an interpreter (python)"
P "& 'C:\\dev\\example-project\\venv\\python.exe' -c \"open(r'C:\\Users\\x\\.claude\\.governance-update\\close-push','w')\"" "an interpreter (python)"
P "pwsh -c \"Set-Content \$HOME/.claude/.governance-update/close-push enabled=1\"" "consent record close-push"
P "[IO.File]::WriteAllText(\"\$HOME\\.claude\\.governance-update\\close-push\",'enabled=1')" "(WriteAll) to the consent record close-push"
# 8c. more write tokens (finding 18)
B "install -m 600 /dev/stdin ~/.claude/.governance-update/close-push <<< 'enabled=1'" "shell write (install) to the consent record close-push"
B "find ~/.claude/.governance-update -name close-push -delete"          "shell write (find) to the consent record close-push"
B "tar -xf /tmp/r.tar -C ~/.claude/.governance-update close-push"       "shell write (tar) to the consent record close-push"
B "rsync /tmp/r ~/.claude/.governance-update/terms-accepted"            "shell write (rsync) to the consent record terms-accepted"
# 8d. the source marker as a directory (finding 17)
B "mkdir -p ~/.claude/.governance-source"                               "shell write (mkdir) to the consent record .governance-source"
B "mkdir ~/.claude/.governance-source"                                  "shell write (mkdir) to the consent record .governance-source"
B "ssh box 'mkdir -p ~/.claude/.governance-source'"                     "shell write (mkdir) to the consent record .governance-source"
P "mkdir \$HOME\\.claude\\.governance-source"                           "shell write (mkdir) to the consent record .governance-source"
P "md \$HOME\\.claude\\.governance-source"                              "shell write (md) to the consent record .governance-source"
P "New-Item -ItemType Directory \$HOME\\.claude\\.governance-source"    "(New-Item) to the consent record .governance-source"
# 8e. a redirection into the directory with the record name hidden (D4)
B "f=close-push; echo enabled=1 > ~/.claude/.governance-update/\$f"     "a redirection into ~/.claude/.governance-update/ (the record name is hidden behind a variable)"
B "echo enabled=1 >> \"\$HOME/.claude/.governance-update/\${F}\""       "a redirection into ~/.claude/.governance-update/"
B "cd ~/.claude/.governance-update && f=close-push && echo enabled=1 > \$f" "shell write (>) to the consent record close-push"
B "cd ~/.claude/.governance-update && echo enabled=1 > \"\$F\""          "a redirection into ~/.claude/.governance-update/ (the shell changes into it first"
AB "cd ~/.claude/.governance-update && ls > /tmp/list.txt"
AB "grep -n '> ~/.claude/.governance-update/\$f' tests/*.sh"
# 8f. Windows short names in a shell command (MEASURED: bash's `>` through GOVERN~1 replaced the record)
B "echo enabled=1 > ~/.claude/GOVERN~4/close-push"                      "consent record close-push (through the Windows short name GOVERN~4)"
B "echo enabled=1 > ~/.claude/.governance-update/CLOSE-~1"              "consent record CLOSE-~1 (a Windows short name)"
P "Set-Content C:\\Users\\x\\.claude\\GOVERN~4\\TERMS-~1 x"            "a Windows short name"
# 8g. must allow: interpreters without a record, reads, other directories
AB "python3 -c \"print(1)\""
AB "node -e \"console.log(process.env.HOME)\""
AB "grep -n \"open('~/.claude/.governance-update/close-push','w')\" tests/*.py"
AB "grep -c node ~/.claude/.governance-update/close-push"
AB "echo 'python3 -c x'; cat ~/.claude/.governance-update/terms-accepted"
AB "python3 build.py"
AB "ls ~/.claude/.governance-update; bash build.sh"
AB "grep -rn python ~/.claude/.governance-update"
AB "ls ~/.claude/.governance-update > /tmp/list.txt"
AB "ls ~/.claude/.governance-update/."
AB "mkdir -p ~/.claude/logs"
AB "mkdir -p /tmp/x && cat ~/.claude/.governance-update/close-push"
AB "git diff HEAD~1 -- install.sh"
AB "git log --oneline HEAD~3..HEAD -- hooks/governance/close-push.sh"
AB "bash close-push.sh --selftest > ~/.claude/logs/cp.log 2>&1"
AP "New-Item -ItemType Directory \$HOME\\.claude\\logs"
AP "Get-ChildItem \$HOME\\.claude\\GOVERN~1"
# 8h. the header is honest (D1) and carries the re-bench (the 2026-09-15 rule)
n=$(grep -c 'MEASURED 2026-09-30' "$GUARD"); [ "${n:-0}" -ge 1 ] && ok "header carries MEASURED 2026-09-30 bench lines ($n)" || bad "bench tripwire" "n=$n"
hdr=$(sed -n '1,/^set +e$/p' "$GUARD" | tr -s ' \n#' ' ')   # the whole header, line breaks folded
case "$hdr" in *"a session cannot accept"*|*"session cannot accept the terms"*) bad "header still says a session cannot accept" "" ;; *) ok "header no longer claims a session cannot accept" ;; esac
case "$hdr" in *"an AI agent included, can do what the user can"*) ok "header states L1: a process under the user's account, an agent included, can do what the user can" ;; *) bad "header STATED LIMIT L1 (D1)" "" ;; esac
case "$hdr" in *"forge a record, unset a marker, allocate a pseudo-terminal"*) ok "header names the L1 examples" ;; *) bad "header L1 examples" "" ;; esac
case "$hdr" in *"a set of regular expressions over a command string"*) ok "header states L2: a set of regexes over the command string" ;; *) bad "header STATED LIMIT L2" "" ;; esac
case "$hdr" in *"none of them a guarantee"*) ok "header: three safeguards, none a guarantee" ;; *) bad "header safeguards line (D1)" "" ;; esac

echo "== 9. round-2 review (findings 4, 5, 6/16, 14): the directory rule, and the header says what passes and what is out of reach"
# 9a. must BLOCK - an interpreter in a command that names the directory, the record name built at
# run time (findings 6/16, MEASURED allowed before this rule)
DIRMSG="in a command that names ~/.claude/.governance-update/ (a record name can be built at run time)"
B "python -c \"import os; d=os.path.expanduser('~/.claude/.governance-update'); open(os.path.join(d,'close'+'-push'),'w').write('enabled=1 terms_version=1')\"" \
  "an interpreter (python) $DIRMSG"
B "node -e \"require('fs').writeFileSync(process.env.HOME+'/.claude/.governance-update/'+'close'+'-push','enabled=1')\"" \
  "an interpreter (node) $DIRMSG"
P "pwsh -Command \"Set-Content -Path \$HOME/.claude/.governance-update/\$('close'+'-push') -Value enabled=1\"" \
  "an interpreter (pwsh) $DIRMSG"
B "python3 - <<'EOF'${NL}import os${NL}open(os.path.expanduser('~/.claude/.governance-update/')+'terms'+'-accepted','w')${NL}EOF" \
  "an interpreter (python3) $DIRMSG"
B "ls ~/.claude/.governance-update; python3 build.py"                    "an interpreter (python3) $DIRMSG"
# 9b. must BLOCK - the reads the docs now say are denied (finding 4: "never blocked" was false)
B "python3 -c \"print(open('/c/Users/x/.claude/.governance-update/close-push').read())\"" \
  "an interpreter (python3) in a command that names the consent record close-push"
B "cat ~/.claude/.governance-update/close-push > /tmp/cp-copy.txt"      "a shell write (>) to the consent record close-push"
B "sha256sum ~/.claude/.governance-update/terms-accepted | tee /tmp/h"  "a shell write (tee) to the consent record terms-accepted"
# 9c. must ALLOW - plain reads and inert searches of the directory (the control side of 9a)
AB "cat ~/.claude/.governance-update/REPORT"
AB "ls -la ~/.claude/.governance-update"
AB "grep -n 'node -e' ~/.claude/.governance-update/REPORT"
AB "git grep -n 'python3 -c' -- '*.sh' && ls ~/.claude/.governance-update"
AP "Get-ChildItem \$HOME\\.claude\\.governance-update"
# 9d. STATED LIMITS, pinned: these pass today and the README / header say so. If one starts to be
# denied, update the docs' out-of-reach list with it (a test that fails here is a docs task).
AB "python -c \"import os,subprocess; e=dict(os.environ); e.pop('CLAUDECODE'); e.pop('AI_AGENT'); subprocess.run(['bash','inst'+'all.sh','--accept-'+'terms'],env=e)\""
AB "python -c \"import os; open(os.path.expanduser('~/.claude/.gover'+'nance-update/close'+'-push'),'w')\""
# 9e. the header says what really passes, and names what is out of reach (findings 4, 5, 14)
case "$hdr" in *"WHAT PASSES. Every read"*) bad "header still says every read passes (finding 4)" "" ;; *) ok "header no longer says every read passes" ;; esac
case "$hdr" in *"NOT every read passes"*) ok "header states which reads are denied (finding 4)" ;; *) bad "header: which reads are denied" "" ;; esac
case "$hdr" in *"NAME BUILT AT RUN TIME"*) ok "header lists names built at run time as out of reach" ;; *) bad "header: names built at run time" "" ;; esac
case "$hdr" in *"MARKER REMOVAL INSIDE AN INTERPRETER"*) ok "header lists marker removal inside an interpreter as out of reach (finding 5)" ;; *) bad "header: marker removal inside an interpreter" "" ;; esac
case "$hdr" in *"typed phrase"*) bad "header still names the typed phrase (owner decision 2026-10-01)" "" ;; *) ok "header names no typed phrase (owner decision 2026-10-01)" ;; esac
n=$(grep -ciE "agent cannot|cannot accept|cannot read the release key" "$GUARD"); [ "${n:-0}" = 0 ] \
  && ok "no 'an AI agent cannot ...' sentence anywhere in the guard (D1, finding 14)" || bad "guard 'cannot' sentences" "n=$n: $(grep -niE 'agent cannot|cannot accept|cannot read the release key' "$GUARD" | head -3)"

echo "== 10. round-3 finding 1: plain commands that write a NAMED file, and names split by quotes or backslashes"
# MEASURED before this section's rules (old guard, private HOME): each form below returned rc 0, and
# the ones run for real created ~/.claude/.governance-source as a regular file, after which
# gov_close_push_on said "on (maintainer machine ...)" with no question.
SRCMSG="to the consent record .governance-source"
M='~/.claude/.governance-source'; R='~/.claude/.governance-update/close-push'
# 10a. must BLOCK - the maintainer marker
B "sort -o $M /dev/null"                                                  "shell write (sort -o) $SRCMSG"
B "sort --output=\$HOME/.claude/.governance-source /dev/null"             "shell write (sort --o) $SRCMSG"
B "sort -o \"\$HOME/.claude/.governance-source\" /dev/null"               "(sort -o) $SRCMSG"
B "sort \"-o\" $M /dev/null"                                              "(sort -o) $SRCMSG"
B "sort --out\"\"put=\$HOME/.claude/.governance-source /dev/null"         "(sort --o) $SRCMSG"
B "uniq /dev/null $M"                                                     "shell write (uniq IN OUT) $SRCMSG"
B "sed -n \"w \$HOME/.claude/.governance-source\" /dev/null"              "shell write (sed w/e) $SRCMSG"
B "sed 's/a/b/w /home/u/.claude/.governance-source' /dev/null"           "(sed w/e) $SRCMSG"
B "sed -n '\$w /home/u/.claude/.governance-source' /dev/null"             "(sed w/e) $SRCMSG"
B "sed 's/a/b/gw /home/u/.claude/.governance-source' /dev/null"          "(sed w/e) $SRCMSG"
B "git config --file $M a.b c"                                            "shell write (git, a write option) $SRCMSG"
B "git config -f $M a.b c"                                                "(git, a write option) $SRCMSG"
B "git diff --no-index --output=\$HOME/.claude/.governance-source /dev/null /dev/null" "(git, a write option) $SRCMSG"
B "curl -o $M file:///dev/null"                                           "shell write (curl) $SRCMSG"
B "cd ~/.claude && curl -O https://example.com/.governance-source"        "(curl) $SRCMSG"
B "curl --output $M https://example.com"                                  "(curl) $SRCMSG"
B "wget -O $M https://example.com"                                        "(wget) $SRCMSG"
B "wget --output-document=\$HOME/.claude/.governance-source https://example.com" "(wget) $SRCMSG"
B "scp /dev/null $M"                                                      "(scp) $SRCMSG"
B "rsync /dev/null $M"                                                    "(rsync) $SRCMSG"
B "ssh-keygen -q -N '' -f $M"                                             "(ssh-keygen -f) $SRCMSG"
B "cmd //c copy NUL %USERPROFILE%\\.claude\\.governance-source"           "an interpreter (cmd) in a command that names the consent record .governance-source"
B "xxd -r /dev/null $M"                                                   "(xxd) $SRCMSG"
B "openssl rand -out $M 1"                                                "(openssl) $SRCMSG"
B "cd ~/.claude && sort -o .governance-source /dev/null"                  "(sort -o) $SRCMSG"
B "cd ~/.claude && git config --file .governance-source a.b c"            "(git, a write option) $SRCMSG"
B "bash -c 'sort -o ~/.claude/.governance-source /dev/null'"              "(sort -o) $SRCMSG"
P "copy C:\\x \$HOME\\.claude\\.governance-source"                        "shell write (copy) $SRCMSG"
P "ac \$HOME\\.claude\\.governance-source x"                              "shell write (ac) $SRCMSG"
P "'x' | Tee-Object -FilePath \$HOME\\.claude\\.governance-source"        "shell write (Tee-Object) $SRCMSG"
P "[IO.File]::Create(\"\$HOME\\.claude\\.governance-source\").Close()"    "$SRCMSG"
P "iwr https://example.com -OutFile \$HOME\\.claude\\.governance-source"  "(-OutFile) $SRCMSG"
# 10b. must BLOCK - the name (or the tool) split by quotes or a backslash: the shell joins them
B "touch ~/.claude/.governance-sour\"\"ce"                                "shell write (touch) $SRCMSG"
B "touch ~/.claude/.governance-sou''rce"                                  "(touch) $SRCMSG"
B "touch ~/.claude/.governance-sou\\rce"                                  "(touch) $SRCMSG"
B "touch ~/.claude/.gover\"nance-sou\"rce"                                "(touch) $SRCMSG"
B ": > ~/.claude/.governance-sour\"\"ce"                                  "shell write (>) $SRCMSG"
B "tou\"\"ch $M"                                                          "(touch) $SRCMSG"
B "printf 'enabled=1' > ~/.claude/.governance-update/close-pu\"\"sh"      "consent record close-push"
B "cp /tmp/x ~/.claude/.governance-upd''ate/close-push"                   "shell write (cp) to the consent record close-push"
B "rm -rf ~/.claude/.governance-upd\"\"ate"                               "rm of .governance-update (the directory)"
B "echo enabled=1 > ~/.claude/.governance-upd\"a\"te/\$f"                 "a redirection into ~/.claude/.governance-update/"
B "bash install.sh --accept-te\"\"rms"                                    "install.sh with --accept-terms"
B "env -u CLAUDE\"\"CODE bash x"                                          "marker stripping (env -u CLAUDECODE)"
# 10c. must BLOCK - the same forms on a consent record
B "sort -o $R /dev/null"                                                  "(sort -o) to the consent record close-push"
B "uniq /dev/null ~/.claude/.governance-update/terms-accepted"            "(uniq IN OUT) to the consent record terms-accepted"
B "sed -n 'w /home/u/.claude/.governance-update/close-push' /dev/null"    "(sed w/e) to the consent record close-push"
B "git config -f $R a.b c"                                                "(git, a write option) to the consent record close-push"
B "curl -o $R https://example.com"                                        "(curl) to the consent record close-push"
P "ac \$HOME\\.claude\\.governance-update\\close-push enabled=1"          "(ac) to the consent record close-push"
# 10d. the marker block explains the marker, not the records (deny-string update)
printf '%s' "$(payload Bash "$(cmdin "sort -o $M /dev/null")")" | run
grep -qF "marks the maintainer's machine: while it exists, push at session close is on with no question" "$ERR" \
  && grep -qF "a write option (sort -o, sed w, git --output, curl -o ...)" "$ERR" && ! grep -qF "The consent records in ~/.claude/.governance-update/ are written only" "$ERR" \
  && ok "the marker block says what the marker does and names the write options" || bad "marker why-line" "$(head -c 500 "$ERR" | tr '\n' '|')"
grep -qiE "cannot" "$ERR" && bad "the marker block says 'cannot'" "$(head -c 500 "$ERR" | tr '\n' '|')" || ok "the marker block has no 'cannot'"
# 10e. must ALLOW - the benign twins: the same tools without their write option, and plain reads
AB "sort $R"
AB "sort -u $M"
AB "uniq $R"
AB "uniq -c $R"
AB "uniq -f 1 $R"
AB "sed -n '1p' $R"
AB "sed -n '/where/p' $R"
AB "sed -e 's/x/y/' $R"
AB "sed -n '/^terms_version=/p' ~/.claude/.governance-update/terms-accepted"
AB "git config --get user.name; ls $M"
AB "git diff --stat; test -f $M && echo maint"
AB "git log --oneline -- hooks/governance/consent-lib.sh; cat $R"
AB "git diff --no-index $R /tmp/x"
AB "ls -la $M"
AB "test -f $M"
AB "[ -f $M ] && echo yes"
AB "cat ~/.claude/.governance-sour\"\"ce"
AB "stat $M"
AB "sha256sum $M"
AB "diff $R /tmp/x"
AB "grep -n 'sort -o' $M"
AB "grep -n \"curl -o ~/.claude/.governance-source\" docs/x.md"
AB "grep -n 'sed -n \"w F\"' $R"
AB "git commit -m \"sort -o .governance-source and curl -o are denied\""
AB "git commit -m \"\$(cat <<'EOF'${NL}curl -o ~/.claude/.governance-source x; sort -o ~/.claude/.governance-update/close-push y${NL}EOF${NL})\""
AB "grep -rn governance-source hooks/ | sort | uniq -c"
AB "grep -n 'touch \"\$CH/.governance-source\"' gov-release.sh"
AP "Get-Content \$HOME\\.claude\\.governance-source"
AP "Test-Path \$HOME\\.claude\\.governance-source"
# 10f. negative controls: the write forms WITHOUT a protected name pass (the rule is about the names)
AB "sort -o /tmp/out /tmp/in"
AB "uniq /tmp/in /tmp/out"
AB "sed -n 'w /tmp/out' /tmp/in"
AB "git diff --output=/tmp/x.patch"
AB "git config --file /tmp/cfg a.b c"
AB "curl -o /tmp/x https://example.com"
AB "touch /tmp/sour\"\"ce"
AP "ac C:\\tmp\\x.txt hello"
AP "'x' | Tee-Object -FilePath C:\\tmp\\x.txt"
# 10g. the header states the round-3 limits (the write-form list is not closed)
hdr=$(sed -n '1,/^set +e$/p' "$GUARD" | tr -s ' \n#' ' ')
case "$hdr" in *"the write-form list is NOT closed"*) ok "header: the write-form list is not closed" ;; *) bad "header: write-form list not closed" "" ;; esac
case "$hdr" in *"any program or script not on it is out of reach"*) ok "header: a program not on the list is out of reach" ;; *) bad "header: program not on the list out of reach" "" ;; esac
case "$hdr" in *"brace expansion"*) ok "header names brace expansion as out of reach" ;; *) bad "header: brace expansion" "" ;; esac
case "$hdr" in *"MEASURED 2026-10-02"*) ok "header carries the round-3 measurement" ;; *) bad "header: round-3 measurement" "" ;; esac
# 10h. STATED LIMITS, pinned (round 3): these pass today and the header says so.
AB "touch ~/.claude/.governance-sour{c,}e"
AB "n=.governance-sour; touch ~/.claude/\${n}ce"

echo "== 11. round-4: a long option under any UNIQUE PREFIX, and operands after \`--\`"
# MEASURED 2026-10-02 (two refuters, private HOME): GNU getopt and git accept a unique prefix of a long
# option and the guard knew only the full spelling - `sort --outp=F`, `sort --o F`, `git config --fil F`
# and `sed --in s/ORIG/enabled=1/ F` returned rc 0 and created the marker / rewrote a record; `uniq -- -x F`
# was seen as one operand because every word starting with `-` was ignored.
SRCMSG="to the consent record .governance-source"; RECMSG="to the consent record close-push"
# 11a. must BLOCK - the maintainer marker
B "sort --out $M /dev/null"                                               "shell write (sort --o) $SRCMSG"
B "sort --o $M /dev/null"                                                 "shell write (sort --o) $SRCMSG"
B "sort --outpu $M /dev/null"                                             "(sort --o) $SRCMSG"
B "sort --outp=\$HOME/.claude/.governance-source /dev/null"               "(sort --o) $SRCMSG"
B "sort --o=\$HOME/.claude/.governance-source /dev/null"                  "(sort --o) $SRCMSG"
B "sort --compress-prog=x $M"                                             "(sort --co) $SRCMSG"
B "sort \"--out\" $M /dev/null"                                           "(sort --o) $SRCMSG"
B "cd ~/.claude && sort --outp .governance-source /dev/null"              "(sort --o) $SRCMSG"
B "git config --fil $M a.b c"                                             "shell write (git, a write option) $SRCMSG"
B "git config --fil=\$HOME/.claude/.governance-source a.b c"              "(git, a write option) $SRCMSG"
B "git -C . config --fil $M a.b c"                                        "(git, a write option) $SRCMSG"
B "git format-patch --output-dir $M -1"                                   "(git, a write option) $SRCMSG"
B "git format-patch --outp $M -1"                                         "(git, a write option) $SRCMSG"
B "uniq -- -x $M"                                                         "shell write (uniq -- IN OUT) $SRCMSG"
B "uniq -- /dev/null $M"                                                  "shell write (uniq IN OUT) $SRCMSG"
# 11b. must BLOCK - a consent record (the sed forms REWROTE a record to enabled=1)
B "sort --outp=\$HOME/.claude/.governance-update/close-push /dev/null"    "(sort --o) $RECMSG"
B "sort --out $R /dev/null"                                               "(sort --o) $RECMSG"
B "git config --fil $R a.b c"                                             "(git, a write option) $RECMSG"
B "sed --in s/ORIG/enabled=1/ $R"                                         "(sed -i) $RECMSG"
B "sed --i s/ORIG/enabled=1/ $R"                                          "(sed -i) $RECMSG"
B "sed --in-p s/ORIG/enabled=1/ $R"                                       "(sed -i) $RECMSG"
B "sed --in=.bak s/ORIG/enabled=1/ $R"                                    "(sed -i) $RECMSG"
# 11b2. round 4b (VERIFY r5, MEASURED 2026-10-02: each returned rc 0 and wrote the file / ran the command):
#       a NUMERIC sed address, a git short option with the value ATTACHED, and `uniq - F` (stdin dash operand)
B "sed -n \"1w \$HOME/.claude/.governance-source\" /dev/null"             "shell write (sed w/e) $SRCMSG"
B "sed -n \"1,5w \$HOME/.claude/.governance-source\" /dev/null"           "(sed w/e) $SRCMSG"
B "sed -n \"0~1w \$HOME/.claude/.governance-source\" /dev/null"           "(sed w/e) $SRCMSG"
B "sed -n \"1w \$HOME/.claude/.governance-update/close-push\" /dev/null"  "(sed w/e) $RECMSG"
B "sed \"1e touch \$HOME/.claude/.governance-source\" /dev/null"          "$SRCMSG"
B "echo x | sed \"1e bash install.sh --accept-terms\""                    "install.sh with --accept-terms"
B "git archive -o\$HOME/.claude/.governance-source HEAD"                  "shell write (git, a write option) $SRCMSG"
B "git config -f\$HOME/.claude/.governance-source a.b c"                  "(git, a write option) $SRCMSG"
B "git format-patch -o\$HOME/.claude/.governance-update/close-push -1"    "(git, a write option) $RECMSG"
B "uniq - $M"                                                             "shell write (uniq - OUT) $SRCMSG"
B "uniq -c - $M"                                                          "(uniq - OUT) $SRCMSG"
B "echo x | uniq - \$HOME/.claude/.governance-source"                     "(uniq - OUT) $SRCMSG"
AB "sed -n 2p $R"
AB "sed -n '/pa2e x/p' $R"
AB "git archive -o/tmp/x.tar HEAD"
AB "uniq - /tmp/out"
AB "sed 1w /tmp/out /tmp/in"
# 11c. must ALLOW - read-only twins that name the same files (a guard that fires on these is switched off)
AB "git log --oneline -- .governance-source"
AB "git log --filter=blob:none -- $M"
AB "git diff --stat -- .governance-source"
AB "sort $R"
AB "sort -u $R"
AB "uniq -c $R"
AB "sed -n 1,5p -- $R"
AB "sed -n 1,5p $R"
# 11d. negative controls: the same forms WITHOUT a protected name pass
AB "sort --outp=/tmp/out /tmp/in"
AB "git config --fil /tmp/cfg a.b c"
AB "sed --in s/a/b/ /tmp/x"
AB "uniq -- /tmp/a /tmp/b"
AB "git format-patch --output-dir /tmp/patches -1"
# 11e. each of these tests can FAIL: a guard that keeps only the full spellings lets the payload through
_mutant_allows() {  # _mutant_allows <name> <sed expression> <command>
  local mut="$SBX/consent-guard.mut.sh" rc g="$GUARD"
  sed -e "$2" "$g" > "$mut"
  GUARD="$mut"; payload Bash "$(cmdin "$3")" | run; rc=$?; GUARD="$g"
  if cmp -s "$mut" "$g"; then bad "mutant [$1] changed nothing" "the sed expression matched no line"
  elif [ "$rc" = 0 ]; then ok "mutant [$1] lets the payload through (rc 0): the test can fail"
  else bad "mutant [$1]" "rc=$rc want 0 - the payload does not depend on the prefix rule"; fi
}
_mutant_allows "sort full spelling only" 's/--o|--co)/--output|--compress-program)/g' "sort --outp=\$HOME/.claude/.governance-source /dev/null"
_mutant_allows "sed --in-place only"     's/(-\[A-Za-z\]\*i|--i)/(-[A-Za-z]*i|--in-place)/g' "sed --in s/ORIG/enabled=1/ $R"
_mutant_allows "git --file only"         's/^_cg_abbr _ab_gitfile file 3/_cg_abbr _ab_gitfile file 4/' "git config --fil $M a.b c"
_mutant_allows "uniq: skip every -word"  's/if \[ "\$dd" = 1 \]; then n=\$((n+1)); continue; fi/:/;s/^    _re_uniq3=.*/    _re_uniq3="NOMATCH-uniq3"/' "uniq -- -x $M"
_mutant_allows "sed numeric address off"  's/^_re_sedw_cmd=.*/_re_sedw_cmd="NOMATCH-sedw"/' "sed -n \"1w \$HOME/.claude/.governance-source\" /dev/null"
_mutant_allows "git attached option off"  's/^_re_gitw_opt=.*/_re_gitw_opt="NOMATCH-gitw"/' "git archive -o\$HOME/.claude/.governance-source HEAD"
_mutant_allows "uniq - OUT off"           's/^    _re_uniq4=.*/    _re_uniq4="NOMATCH-uniq4"/' "uniq - $M"
# 11f. the header states the round-4 rule and its limits
hdr=$(sed -n '1,/^set +e$/p' "$GUARD" | tr -s ' \n#' ' ')
case "$hdr" in *"ANY unique prefix"*) ok "header: a long option is recognised under any unique prefix" ;; *) bad "header: unique prefix" "" ;; esac
case "$hdr" in *"AMBIGUOUS prefix is denied too"*) ok "header: an ambiguous prefix is denied too" ;; *) bad "header: ambiguous prefix" "" ;; esac
case "$hdr" in *'shuf -o F'*) ok "header names the programs measured out of reach in round 4 (shuf, sdiff, link, .NET)" ;; *) bad "header: round-4 out-of-reach list" "" ;; esac

echo
echo "consent-guard selftest: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
