#!/usr/bin/env bash
# consent-lib.sh - the consent records: ONE parser, ONE predicate per choice, ONE atomic writer,
# and the AI-agent detection that decides whether a person is the one accepting.
# Created: 2026-09-30 (2.0.0, legal conditions T2, T3, S2, S4, C3, C5).
#
# WHY A SEPARATE FILE (not inside _common.sh)
# install.sh must write nothing before the terms are accepted, and _common.sh creates
# ~/.claude/logs at source time and primes stdin. So this file is PURE: sourcing it defines
# functions and nothing else - no file is created, nothing is read, stdin is untouched.
# _common.sh sources it (so every hook has gov_close_push_on / gov_auto_update_on by name);
# install.sh, close-push.sh and gov-update.sh source it directly.
#
# Contract: `set -u` safe, bash 3.2 safe, never `source`s a data file, never prints unless the
# function's job is to print. Return codes: 0 = yes/ok, 1 = no/refused.
#
# The records live in ~/.claude/.governance-update/ and are ONE line of space-separated k=v:
#   terms-accepted   terms_version=<n> accepted_at=<utc> framework_version=<v> method=<m> ...
#   close-push       enabled=0|1 terms_version=<n> decided_at=<utc> framework_version=<v> method=<m> ...
# There is no auto-update record in this version. A planted one is ignored (gov_auto_update_on).
#
# Hashes (C5): gov_sha256_lf* strip every CR before hashing, so a CRLF checkout of
# NOTICE-AUTO-UPDATE.md hashes the same as the LF file in the tagged repository. To verify a
# recorded notice_sha256 against a release:
#   git show v<ver>:NOTICE-AUTO-UPDATE.md | tr -d '\r' | sha256sum
# shown_sha256 (the push-at-session-close question) is the SHA-256 of EXACTLY the bytes printed
# (round-2 finding 13, 2026-10-01): gov_close_push_ask prints the block once and hashes that same
# string, so the hash covers the y/N prompt line and the "Full text:" path as the person saw it.
# The record still carries no path (a hash is not a path, S4). To verify a record, rebuild the
# block with the path that was shown (install.sh: the clone's NOTICE; close-push.sh --enable: the
# installed copy, $HOME/.claude/hooks/governance-terms/NOTICE-AUTO-UPDATE.md - gov_terms_copy_dir):
#   gov_close_push_question '<the path shown>' | gov_sha256_lf_stdin
#
# PUSH AT SESSION CLOSE - WHO DECIDES (owner decision 2026-10-01, Plans/PLAN.md):
#   * the MAINTAINER's machine - the regular file ~/.claude/.governance-source exists (made by the
#     owner in his own terminal, or by gov-release.sh in every run that reaches the signed-tag push -
#     even when the client check after it fails; it is made again if deleted) - push at session close is ALWAYS
#     ON: no record, no question. Only GOV_CLOSE_PUSH=0 pauses it, and every hold in close-push.sh
#     (public repo, CI/deploy list, close_push: off, the framework's own clone, ...) still applies.
#     A DIRECTORY of that name is not the marker. In this library the marker is read ONLY by
#     gov_maintainer_machine (gov_close_push_on, close-push.sh, install.sh and verify.sh call it), and
#     it exempts no consent act. Outside this library it is read for release-tool operations only:
#     gov-update.sh upd_is_source (deliberately broader - ANY entry of that name, a directory too,
#     stops the updater; refusing an update fails safe) and gov-release.sh, which creates it.
#   * every other machine (C4): OFF unless the user answered y to the y/N question (default No) at
#     install or in close-push.sh --enable, on a real terminal, under the installed terms.
#
# WHAT THE AGENT CHECK IS (D1). gov_agent_session reads environment markers. A process running
# under the user's own account can remove them - or create the maintainer marker, or write a
# record - so no check here can GUARANTEE that an AI agent does not act as the user (stated limit
# L1). Consent acts therefore REFUSE when they detect an agent session AND require a real terminal
# - a safeguard, not a guarantee.

# gov_consent_dir -> the directory that holds the consent records.
gov_consent_dir() { printf '%s' "$HOME/.claude/.governance-update"; }

# gov_local_env_get KEY -> the process environment first, else the LAST assignment of KEY in
# ~/.claude/.governance-local.env, read with grep (comments and one pair of quotes stripped).
# That file can carry a real token; sourcing it would execute whatever it contains.
# GOV_ACCEPT_TERMS is process-env ONLY (S4): accepting the terms is an act, not a setting.
gov_local_env_get() {
  local k="${1:-}" v="" f="$HOME/.claude/.governance-local.env"
  case "$k" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 1 ;; esac
  eval "v=\${$k:-}"
  if [ -z "$v" ] && [ "$k" != "GOV_ACCEPT_TERMS" ] && [ -f "$f" ]; then
    v=$(grep -E "^[[:space:]]*(export[[:space:]]+)?$k=" "$f" 2>/dev/null | tail -1 \
        | sed -e 's/^[^=]*=//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's/^["'\'']//' -e 's/["'\'']$//') || v=""
  fi
  printf '%s' "$v"
}

# gov_record_field FILE KEY -> the value of KEY= on the FIRST line of FILE; empty output (and
# still 0, so `x=$(...)` is safe under `set -e`) when the file, the line or the key is absent.
# The ONLY parser of a consent record. Tokens are split on blanks; CR is ignored; no globbing.
gov_record_field() {
  local f="${1:-}" k="${2:-}" line="" v
  case "$k" in ''|*[!A-Za-z0-9_]*) return 0 ;; esac
  [ -f "$f" ] && [ -r "$f" ] || return 0
  IFS= read -r line < "$f" || [ -n "$line" ] || return 0
  line="${line//$'\r'/}"; line=" ${line//$'\t'/ } "
  case "$line" in
    *" $k="*) v="${line#*" $k="}"; printf '%s' "${v%% *}" ;;
  esac
  return 0
}

# gov_terms_copy_dir -> the directory that holds the INSTALLED copy of the terms: TERMS-VERSION and
# NOTICE-AUTO-UPDATE.md. install.sh puts both there through its install map (gov_install_map), so
# every install has them - from a clone in ANY directory, from the maintainer's staging folder, and
# gov-update.sh --apply (which installs that same map) rewrites them together with installed.manifest.
# --uninstall removes them with the rest of ~/.claude/hooks/. Not hooks/governance/: that directory
# is mirrored into the publishable bundle, and a second TERMS-VERSION there would drift from the one
# gov-release.sh raises. Verify round 4 #2 (2026-10-02): the old second source,
# ~/.claude/governance-installer/bundle/TERMS-VERSION, exists only when the clone sits at exactly that
# path, so a client who installed from a clone elsewhere answered y and stayed OFF for ever.
gov_terms_copy_dir() { printf '%s' "$HOME/.claude/hooks/governance-terms"; }

# _gov_terms_sources -> "<manifest> <file>": the two places that state the installed terms version,
# each an integer or "-" when absent or not an integer:
#   <manifest> terms_version= in the header (above [files]) of ~/.claude/.governance-update/installed.manifest
#   <file>     $(gov_terms_copy_dir)/TERMS-VERSION (the installed copy of bundle/TERMS-VERSION)
_gov_terms_sources() {
  local m tvf mv="" fv=""
  m="$(gov_consent_dir)/installed.manifest"; tvf="$(gov_terms_copy_dir)/TERMS-VERSION"
  if [ -f "$m" ]; then
    mv=$(awk '/^\[files\]$/ { exit } index($0, "terms_version=") == 1 { print substr($0, 15); exit }' \
          "$m" 2>/dev/null | tr -d '[:space:]') || mv=""
  fi
  [ -f "$tvf" ] && { fv=$(tr -d '[:space:]' 2>/dev/null < "$tvf") || fv=""; }
  case "$mv" in ''|*[!0-9]*) mv="-" ;; esac
  case "$fv" in ''|*[!0-9]*) fv="-" ;; esac
  printf '%s %s' "$mv" "$fv"
}

# gov_installed_terms_version -> the terms version of what is installed: the HIGHEST of the two
# sources (_gov_terms_sources), else 1. Round-2 finding 11 (2026-10-01): installed.manifest is not a
# consent record and a session can edit it, and the old reader took its value first - lowering
# terms_version= there made a stale enabled=1 record count again. Taking the highest means lowering
# ONE source can never lower the result; gov_close_push_on also refuses when the two disagree.
# Editing BOTH files is still possible for anything running as the user (stated limit L1).
gov_installed_terms_version() {
  local s mv fv v=1
  s=$(_gov_terms_sources); mv="${s%% *}"; fv="${s##* }"
  [ "$mv" != "-" ] && [ "$mv" -gt "$v" ] 2>/dev/null && v="$mv"
  [ "$fv" != "-" ] && [ "$fv" -gt "$v" ] 2>/dev/null && v="$fv"
  printf '%s' "$v"
}

# gov_maintainer_machine -> 0 only when ~/.claude/.governance-source is a regular file (not a
# directory, not a symlink): the maintainer's machine (owner decision 2026-10-01). The ONE reader of
# the marker in this library; it never takes part in gov_human_consent_ok.
gov_maintainer_machine() {
  local m="$HOME/.claude/.governance-source"
  [ -f "$m" ] && [ ! -L "$m" ]
}

# gov_close_push_off_kind METHOD -> how an enabled=0 record came about, from its method= (round 3,
# OPEN-PROBLEMS #39 item 11; verify round 4 minor, 2026-10-02: ONE list for every reader - this
# library, install.sh's kept-record line and gov-update.sh --status - so they cannot word it apart):
#   choice    declined | close-push-disable | --no-close-push   (an answer or an act of the person)
#   default   default-*            (install.sh with no terminal, or inside an AI-agent session)
#   terms     terms-changed        (install.sh turned an older-terms record off)
#   recorded  any other method, or none
gov_close_push_off_kind() {
  case "${1:-}" in
    declined|close-push-disable|--no-close-push) printf 'choice' ;;
    default-*)     printf 'default' ;;
    terms-changed) printf 'terms' ;;
    *)             printf 'recorded' ;;
  esac
}

# gov_reason_text REASON -> the reason without its "off (" ... ")" wrapper, for a caller that prints
# its own "OFF (...)" (install.sh's summary line; round 4 minor: it printed "OFF (off (...))").
# Any other reason ("paused by GOV_CLOSE_PUSH=0", "on (...)") is printed unchanged.
gov_reason_text() {
  local r="${1:-}"
  case "$r" in "off ("*")") r="${r#off (}"; r="${r%)}" ;; esac
  printf '%s' "$r"
}

# gov_close_push_on -> 0 when push at session close is on for this machine. Otherwise 1.
#   The maintainer's machine (gov_maintainer_machine): 0 with "on (maintainer machine:
#     ~/.claude/.governance-source)" - no record and no accepted terms are read - unless paused.
#   Every other machine: 0 only when the user turned it ON under the installed terms, has accepted
#     those terms, and has not paused it; then GOV_CONSENT_REASON is "on (your choice)".
# The reasons for 1:
#   no choice recorded (off) | off (record unreadable)
#   an OFF record, worded by its method= (round-3, OPEN-PROBLEMS #39 item 11 - only an answer the
#     person gave is "your choice"):
#       off (your choice)                          method declined | close-push-disable | --no-close-push
#       off (the default: you were not asked)      method default-* (install.sh with no terminal or
#                                                  inside an AI-agent session)
#       off (turned off when the terms changed)    method terms-changed
#       off (recorded off)                         any other or no method
#   off (terms changed to v<n>; accept them, then turn it on again in your own terminal: bash
#     ~/.claude/hooks/governance/close-push.sh --enable)   [one line; see below]
#   off (installed terms version unclear: installed.manifest says <m>, TERMS-VERSION says <f>;
#     re-run install.sh)   [one line; <m>/<f> is v<n>, or "nothing usable" when that source is
#     absent or not an integer. Finding 11: two sources that disagree fail closed; round 3: so does
#     a source that is absent or unreadable - one source alone is not a clear terms version]
#   paused by GOV_CLOSE_PUSH=0
# The stale reason covers two cases with ONE string (D5): the close-push record was made under older
# terms (only close-push.sh --enable rewrites it - gov-update.sh --accept-terms never does), or the
# installed terms are not accepted yet (--enable refuses until they are, and says so).
gov_close_push_on() {
  local d rec acc inst en tv atv s mv fv
  if gov_maintainer_machine; then
    if [ "$(gov_local_env_get GOV_CLOSE_PUSH)" = "0" ]; then
      GOV_CONSENT_REASON="paused by GOV_CLOSE_PUSH=0"; return 1
    fi
    GOV_CONSENT_REASON="on (maintainer machine: ~/.claude/.governance-source)"
    return 0
  fi
  d=$(gov_consent_dir); rec="$d/close-push"; acc="$d/terms-accepted"
  inst=$(gov_installed_terms_version)
  if [ ! -e "$rec" ]; then GOV_CONSENT_REASON="no choice recorded (off)"; return 1; fi
  en=$(gov_record_field "$rec" enabled)
  tv=$(gov_record_field "$rec" terms_version)
  case "$en" in 0|1) ;; *) GOV_CONSENT_REASON="off (record unreadable)"; return 1 ;; esac
  case "$tv" in ''|*[!0-9]*) GOV_CONSENT_REASON="off (record unreadable)"; return 1 ;; esac
  if [ "$en" != "1" ]; then
    case "$(gov_close_push_off_kind "$(gov_record_field "$rec" method)")" in
      choice)  GOV_CONSENT_REASON="off (your choice)" ;;
      default) GOV_CONSENT_REASON="off (the default: you were not asked)" ;;
      terms)   GOV_CONSENT_REASON="off (turned off when the terms changed)" ;;
      *)       GOV_CONSENT_REASON="off (recorded off)" ;;
    esac
    return 1
  fi
  # Both terms sources must state the SAME integer. A source that is absent or not an integer fails
  # closed too (round 3): with one source missing, lowering the other one was undetected.
  s=$(_gov_terms_sources); mv="${s%% *}"; fv="${s##* }"
  if [ "$mv" = "-" ] || [ "$fv" = "-" ] || ! [ "$mv" -eq "$fv" ] 2>/dev/null; then
    case "$mv" in -) mv="nothing usable" ;; *) mv="v$mv" ;; esac
    case "$fv" in -) fv="nothing usable" ;; *) fv="v$fv" ;; esac
    GOV_CONSENT_REASON="off (installed terms version unclear: installed.manifest says $mv, TERMS-VERSION says $fv; re-run install.sh)"
    return 1
  fi
  atv=$(gov_record_field "$acc" terms_version)
  case "$atv" in ''|*[!0-9]*) atv=0 ;; esac
  if [ "$tv" -lt "$inst" ] || [ "$atv" -lt "$inst" ]; then
    GOV_CONSENT_REASON="off (terms changed to v$inst; accept them, then turn it on again in your own terminal: bash ~/.claude/hooks/governance/close-push.sh --enable)"
    return 1
  fi
  if [ "$(gov_local_env_get GOV_CLOSE_PUSH)" = "0" ]; then
    GOV_CONSENT_REASON="paused by GOV_CLOSE_PUSH=0"; return 1
  fi
  GOV_CONSENT_REASON="on (your choice)"
  return 0
}

# gov_auto_update_on -> always 1 in this version: there is no automatic update and no setting,
# variable or record that turns one on (owner decision 2026-09-29/30). GOV_AUTO_UPDATE and an
# auto-update record are NOT read.
gov_auto_update_on() {
  GOV_CONSENT_REASON="automatic updates are not available in this version"
  return 1
}

# gov_sha256_lf FILE / gov_sha256_lf_stdin -> the lowercase hex SHA-256 of the bytes with every
# CR removed. Empty output + 1 when no hashing tool or no file.
gov_sha256_lf_stdin() {
  local d
  if command -v sha256sum >/dev/null 2>&1; then d=$(tr -d '\r' | sha256sum 2>/dev/null)
  elif command -v shasum >/dev/null 2>&1; then d=$(tr -d '\r' | shasum -a 256 2>/dev/null)
  else return 1; fi
  d="${d%% *}"
  case "$d" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s' "$d"
}
gov_sha256_lf() {
  [ -f "${1:-}" ] && [ -r "$1" ] || return 1
  gov_sha256_lf_stdin < "$1"
}

# gov_terms_summary NOTICE -> the lines between <!-- terms-summary:begin --> and
# <!-- terms-summary:end -->, marker lines dropped. The one extraction (install.sh, gov-update.sh).
gov_terms_summary() {
  [ -f "${1:-}" ] || return 1
  sed -n '/<!-- terms-summary:begin -->/,/<!-- terms-summary:end -->/{/<!--/d;p;}' "$1"
}

# gov_close_push_answer_yes ANSWER -> 0 only for y or yes (any letter case, blanks and CR around it
# ignored): the answer to the y/N question that turns push at session close ON on a client machine
# (owner decision 2026-10-01: a plain y/N, default No). Anything else, the empty
# answer (Enter) included, is No. The one rule: install.sh and close-push.sh --enable both call it.
gov_close_push_answer_yes() {
  local a="${1:-}"
  a="${a//$'\r'/}"; a="${a//$'\t'/ }"
  a="${a#"${a%%[! ]*}"}"; a="${a%"${a##*[! ]}"}"
  a=$(printf '%s' "$a" | tr 'A-Z' 'a-z')
  case "$a" in y|yes) return 0 ;; esac
  return 1
}

# gov_interactive_terminal -> 0 only when BOTH stdin and stdout are a terminal (D2). A pipe, a
# redirect or </dev/null on either side is not a person at a terminal. One definition, every caller.
gov_interactive_terminal() { [ -t 0 ] && [ -t 1 ]; }

# gov_close_push_question NOTICE_PATH -> the push-at-session-close question, DRAFTS A.6 verbatim
# (the y/N form, restored by the owner decision of 2026-10-01),
# ending with the [y/N] prompt and NO newline, so the caller reads the answer on the same line. The
# one literal (install.sh and close-push.sh --enable, both through gov_close_push_ask).
gov_close_push_question() {
  local notice="${1:-NOTICE-AUTO-UPDATE.md}"
  printf '%s\n' \
    '' \
    'Push at session close - OFF unless you turn it on' \
    '  When on, and a Claude Code session in a governed project closes, the session pushes the' \
    '  current branch to its existing upstream - fast-forward only, never forced - without asking' \
    '  you each time. (Whether or not this is on, a close commits the files that session wrote.)' \
    '  It holds, and says why, for public repositories, repositories whose visibility it cannot' \
    '  read, organisation-wide ones, and commits that contain CI or deployment configuration.' \
    '  Main risks: a push cannot be taken back once someone has fetched it; everyone with access to' \
    '  the remote, including collaborators on a private repository, sees what was pushed; the' \
    '  secret scan recognises common token formats only - not passwords, personal data or other' \
    '  confidential content; and a host connected through its own dashboard may deploy on a push.' \
    '  If you say no, nothing is pushed; you push by hand.' \
    '  Change it at any time:' \
    '    bash ~/.claude/hooks/governance/close-push.sh --enable' \
    '    bash ~/.claude/hooks/governance/close-push.sh --disable' \
    '  One project only: close_push: off in its docs/context/CONTEXT-MANIFEST.md' \
    "  Full text: $notice, sections 2a and 10.3"
  printf '%s' 'Turn push at session close ON now? [y/N]: '
}

# gov_close_push_ask NOTICE_PATH -> prints the question ONCE and sets GOV_SHOWN_SHA256 to the
# SHA-256 (CR stripped) of exactly the bytes it printed, path and [y/N] prompt included (C5; round-2
# finding 13: the old writers printed the real path but hashed a copy with the bare file name, so
# the recorded hash matched nothing the person saw). Run it in the caller's shell, not in $(...),
# or the variable is lost. GOV_SHOWN_SHA256 is empty when no hashing tool exists.
gov_close_push_ask() {
  local q
  q=$(gov_close_push_question "${1:-NOTICE-AUTO-UPDATE.md}"; printf '.'); q="${q%.}"
  printf '%s' "$q"
  GOV_SHOWN_SHA256=$(printf '%s' "$q" | gov_sha256_lf_stdin) || GOV_SHOWN_SHA256=""
}

# gov_consent_write FILE 'k=v k=v ...' -> writes the record atomically: umask 077, FILE.tmp.<pid>,
# chmod 600, mv -f. Refuses (1, nothing written) a line that is not one line of k=v tokens, or that
# carries a path, the user name or the host name (S4: a record holds no identity). Callers never
# call it under --dry-run.
gov_consent_write() {
  local f="${1:-}" line="${2:-}" tmp tok val lc id rest
  [ -n "$f" ] && [ -n "$line" ] || return 1
  # One line, no path, no glob character (the token loop below must not expand against the cwd).
  case "$line" in *$'\n'*|*$'\r'*|*$'\t'*|*/*|*\\*|*'*'*|*'?'*|*'['*) return 1 ;; esac
  rest="$line"
  while [ -n "$rest" ]; do
    rest="${rest#"${rest%%[! ]*}"}"; [ -n "$rest" ] || break
    tok="${rest%% *}"; rest="${rest#"$tok"}"
    case "$tok" in [a-z_]*=*) ;; *) return 1 ;; esac
    case "${tok%%=*}" in *[!a-z0-9_]*) return 1 ;; esac
    val="${tok#*=}"; lc=$(printf '%s' "$val" | tr 'A-Z' 'a-z')
    for id in "${USER:-}" "${USERNAME:-}" "${LOGNAME:-}" "${HOSTNAME:-}" "${COMPUTERNAME:-}"; do
      [ -n "$id" ] || continue
      [ "$lc" != "$(printf '%s' "$id" | tr 'A-Z' 'a-z')" ] || return 1
    done
  done
  tmp="$f.tmp.$$"
  case "$f" in */*) ;; *) f="./$f"; tmp="$f.tmp.$$" ;; esac
  if ! ( umask 077 && mkdir -p "${f%/*}" && printf '%s\n' "$line" > "$tmp" ) 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# gov_agent_session -> 0 when this process runs inside an AI-agent session (any of the markers
# CLAUDECODE, AI_AGENT, CLAUDE_CODE_ENTRYPOINT is non-empty).
gov_agent_session() {
  [ -n "${CLAUDECODE:-}" ] || [ -n "${AI_AGENT:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]
}

# _gov_is_real_home DIR -> 0 when DIR is the account's real home by ANY source that resolves:
# USERPROFILE, the passwd entry (getent), the ~<user> expansion. Compared by inode (-ef) and
# case-insensitively, so a differently spelt path on Windows is still the real home. 2 when no
# source resolves at all (the caller treats that as "cannot tell" and refuses).
_gov_is_real_home() {
  local dir="$1" p="" u="" lc_dir cand seen=0 pw="" tl=""
  lc_dir=$(printf '%s' "$dir" | tr 'A-Z' 'a-z')
  u=$(id -un 2>/dev/null) || u=""
  if [ -n "$u" ] && command -v getent >/dev/null 2>&1; then
    pw=$(getent passwd "$u" 2>/dev/null | cut -d: -f6) || pw=""
  fi
  case "$u" in ''|*[!A-Za-z0-9._-]*) ;; *) eval "tl=~$u" ;; esac
  for cand in "${USERPROFILE:-}" "$pw" "$tl"; do
    [ -n "$cand" ] || continue
    case "$cand" in "~"*) continue ;; esac
    p=$(cd "$cand" 2>/dev/null && pwd -P) || continue
    [ -n "$p" ] || continue
    seen=1
    if [ "$dir" -ef "$p" ]; then return 0; fi
    if [ "$lc_dir" = "$(printf '%s' "$p" | tr 'A-Z' 'a-z')" ]; then return 0; fi
  done
  [ "$seen" = 1 ] && return 1
  return 2
}

# gov_consent_override_ok -> 0 only for the test suites' sandbox: $GOV_CONSENT_SELFTEST is
# non-empty AND equals the content of $HOME/.governance-consent-selftest AND $HOME is not the real
# home (S2). A nonce in the real home is ignored.
gov_consent_override_ok() {
  local nonce="${GOV_CONSENT_SELFTEST:-}" f="$HOME/.governance-consent-selftest" have="" h r=0
  [ -n "$nonce" ] || return 1
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  IFS= read -r have < "$f" || [ -n "$have" ] || return 1
  have="${have%$'\r'}"
  [ "$have" = "$nonce" ] || return 1
  h=$(cd "$HOME" 2>/dev/null && pwd -P) || return 1
  [ -n "$h" ] || return 1
  _gov_is_real_home "$h" || r=$?
  [ "$r" = 1 ]   # 0 = it IS the real home, 2 = cannot tell: both refuse
}

# gov_human_consent_ok -> 0 when no AI-agent session is detected, or under the test suites' sandbox
# override. Nothing else exempts a consent act (D3, 2026-09-30): the release source-machine marker
# ~/.claude/.governance-source exempts NOTHING here - as a file or as a directory (a plain `mkdir`
# made one, review finding 17) - and GOV_REPO_PATH is not an exemption either. The marker is read
# only for release-tool operations (gov-update.sh upd_is_source, gov-release.sh) and, since the
# owner decision of 2026-10-01, by gov_maintainer_machine for push at session close - never here.
# This is detection, not proof (see the header): callers also require a real terminal.
gov_human_consent_ok() {
  ! gov_agent_session || gov_consent_override_ok
}

# gov_consent_refusal_line -> DRAFTS A.2 as adapted by D1 / L1 (2026-10-01), printed when
# gov_human_consent_ok refused because an AI-agent session was DETECTED. The DRAFTS text said an
# agent "cannot accept"; that claims a guarantee the check does not give (anything running under the
# user's account can remove the markers), so the line says what happened: refused on detection.
gov_consent_refusal_line() {
  printf '%s\n' \
    '[GOVERNANCE] Refused: this needs your own decision, typed in your own terminal, and an AI-agent' \
    'session was detected (a safeguard, not a guarantee). Nothing was recorded or changed.'
}
