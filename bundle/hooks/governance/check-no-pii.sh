#!/usr/bin/env bash
# check-no-pii.sh — Regression tripwire: no file that can reach the PUBLIC governance
# repository may contain a real value.
#
# WHAT THIS IS NOT: this is not the primary defense. The primary defense is that the real
# values are NOT IN THE TRACKED FILES AT ALL — a tracked file carries a placeholder or reads
# an env var, and the real value lives in a machine-local, gitignored config that is never
# synced (the ~/.claude/.governance-mirrors precedent, GOVERNANCE-AGENT-GUIDE §19). This
# script only catches the regression when someone puts one back.
#
# WHY SHAPE AND NOT A DENYLIST: a denylist always lags reality. The 2026-08-18 sweep found a
# third person's US phone number and a real WhatsApp message id that nobody had thought to
# put on a list. So the rules below match SHAPES (Israeli mobiles, WhatsApp LIDs and JIDs,
# public IPv4 literals, private checkout paths, emails, Slack ids). A supplementary denylist
# exists for machine-specific proper nouns, but it is read from a machine-local file and
# ships EMPTY — putting real project names in this script would re-create the very leak it
# is here to prevent.
#
# WHY A SECOND ROUND EXISTED (2026-09-01): round 1 scanned with the rules below and reported
# clean; an independent certifier then found seven more categories, headed by the operator's
# own FULL NAME, which this scanner scored as 0 because a name has no shape. That is the
# whole lesson restated: the categories a scanner does not model are invisible to it, and
# "the scan was clean" means only "clean of what I already modelled". So names are now
# covered THREE ways that fail independently — a structural attribution heuristic
# (NAME_ATTRIB), a contact-record heuristic (NAME_FIELD), and a machine-local proper-noun
# list (NAME_DENY) that is absent by default. A user with no list still gets the first two.
#
# WHY IT MUST NOT FIRE ON PLACEHOLDERS: a scanner that cries wolf gets disabled, and a
# disabled control is how controls die. Every documented placeholder from README.md:194 is
# exempt BY VALUE, not by luck, and --selftest proves it in both directions on every run.
#
# USAGE
#   check-no-pii.sh <path> [<path>...]     scan the named files (a directory is walked)
#   check-no-pii.sh --tree <dir>           scan every text file under <dir>
#   check-no-pii.sh --selftest             prove the rules in both directions, then exit
#   check-no-pii.sh --list-rules           print the rule table and the remedy for each
#
# EXIT CODES
#   0  clean (or selftest passed)
#   2  contamination found  <- usable directly as a blocking PreToolUse / pre-commit gate
#   1  usage error, or --selftest failed
#
# PER-LINE EXCEPTION
#   Put  pii-allow: <reason>  in a comment on the SAME line to accept one deliberate hit.
#   The run reports how many exceptions it honoured — a silent exception is how a scanner rots.
#
# MACHINE-LOCAL FILES (gitignored, hold real values on purpose, never scanned):
#   ~/.claude/.governance-local.env · .governance-mirrors · .governance-pii-denylist
#   ~/.claude/.pii-names · ~/.claude/.wa-bridge.json
#
# Kill switch: GOVERNANCE_HOOKS=0 suppresses it when wired as a hook (CLAUDE_HOOK set);
# a direct invocation always runs, so the gate cannot be silently turned off in CI.
set +e

VERSION="2.0.0"
DENYLIST_FILE="${GOV_PII_DENYLIST:-$HOME/.claude/.governance-pii-denylist}"
NAMES_FILE="${GOV_PII_NAMES:-$HOME/.claude/.pii-names}"

# ---------------------------------------------------------------------------
# Rule regexes (ERE, GNU grep).
# ---------------------------------------------------------------------------
RE_IL_PHONE='(\+?972[-. ]?5[0-9][-. ]?[0-9]{3}[-. ]?[0-9]{4})|(\b05[0-9][-. ]?[0-9]{3}[-. ]?[0-9]{4}\b)'
# Four NANP spellings. The last two are round 2 additions: the certifier's third-party number
# survived round 1 only because it happened to be written with a +1, and a bare 10-digit run
# matched nothing at all. The punctuated form is unambiguous and fires anywhere; the naked
# 10-digit run needs phone-ish context on the line (see is_exempt) or it would flag every
# 10-digit id in the tree, and a noisy gate is a disabled gate.
RE_NANP='(\+1[-. ]?\(?[2-9][0-9]{2}\)?[-. ]?[2-9][0-9]{2}[-. ]?[0-9]{4})|(\b1[2-9][0-9]{9}\b)|((\(|\b)[2-9][0-9]{2}\)?[-. ][2-9][0-9]{2}[-. ][0-9]{4}\b)|(\b[2-9][0-9]{2}[2-9][0-9]{6}\b)'
# WhatsApp identifiers are three DIFFERENT kinds of identity with three different remedies,
# so they are three rules. Round 1 folded every "@suffix" form into one WA_JID bucket, which
# reported a group id and a LID under a rule whose fix text talked about neither.
RE_WA_LID='(\b[0-9]{15,16}\b)|(\b[0-9]{5,20}@lid\b)'
RE_WA_GROUP='(\b1203[0-9]{14}\b)|(\b[0-9]{15,20}@g\.us\b)'
RE_WA_JID='\b[0-9]{5,20}@s\.whatsapp\.net\b'
RE_WA_MSGID='\b3EB0[0-9A-F]{14,22}\b'
RE_EMAIL='\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b'
RE_IPV4='\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b'
# The operator's home directory names the operator. It used to be reported as a generic
# "private checkout path", whose remedy text is about repositories and reads as a false
# alarm on C:\Users\<somebody>. Its own kind, its own fix line.
RE_HOME_PATH='((^|[^A-Za-z0-9_])[A-Za-z]:[\\/]+[Uu]sers[\\/]+[A-Za-z0-9._%<>{}$~-]+)|(/(mnt/)?[A-Za-z]/[Uu]sers/[A-Za-z0-9._%<>{}$~-]+)|(/home/[A-Za-z0-9._%<>{}$~-]+)'
RE_WIN_PATH='(^|[^A-Za-z0-9_])[A-Za-z]:[\\/]+[A-Za-z0-9._-]+([\\/]+[A-Za-z0-9._-]+)?'
RE_UNIX_PATH='/(mnt/c|c|opt|home|root|srv|Users|users)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?'
RE_SLUG='\bc--[A-Za-z0-9_-]+\b'
RE_SLACK_ID='(\b[CUTGDBW]0[A-Z0-9]{7,10}\b)|(\b[A-Za-z0-9][A-Za-z0-9-]{1,30}\.slack\.com\b)'
# A Drive/Docs/Sheets id is a durable pointer at a private document; anyone holding it can
# try it. Two spellings: host-anchored, and the bare 43-44 char Google file id.
RE_GOOGLE_ID='(((docs|drive|sheets|script)\.google\.com|googleusercontent\.com)[A-Za-z0-9/._-]*/d/[A-Za-z0-9_-]{20,})|(\b1[A-Za-z0-9_-]{42,43}\b)'
# A tunnel host is a live door into the operator's machine for as long as it is up.
RE_TUNNEL_HOST='\b[A-Za-z0-9][A-Za-z0-9-]{1,60}\.(ngrok(-free)?\.(io|app|dev)|trycloudflare\.com|loca\.lt|serveo\.net|tunnelto\.dev|lhr\.life|bore\.pub|pagekite\.me)\b'
# Credential shapes. A governance/skills bundle carries installers and CI snippets, and the
# 2026-08-30 assessment found a real (read-only) GitHub PAT committed in six files.
RE_SECRET='(gh[pousr]_[A-Za-z0-9]{28,})|(github_pat_[A-Za-z0-9_]{40,})|(xox[baprse]-[A-Za-z0-9-]{16,})|(sk-[A-Za-z0-9_-]{24,})|(AIza[0-9A-Za-z_-]{30,})|(-----BEGIN [A-Z ]{0,24}PRIVATE KEY-----)|(eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,})'
# NAME_ATTRIB — a person named where documents name people. Two strengths: a labelled
# attribution (Owner:/Author:/Operator:...) fires anywhere in the file; the weak forms
# ("by X Y", "— X Y") must START a line. Mid-line they are titles, not bylines:
# unanchored they scored 33 hits on the real tree and all 33 were markdown titles shaped
# "# FILE.md — Some Subtitle". Markdown bold is tolerated: **Owner:** X Y.
RE_NAME_ATTRIB='(\*{0,2}([Aa]uthor|AUTHOR|[Oo]wner|OWNER|[Oo]perator|OPERATOR|[Mm]aintainer|MAINTAINER|[Cc]ontact|CONTACT|[Cc]reated [Bb]y|[Ww]ritten [Bb]y|[Rr]eviewed [Bb]y|[Rr]eported [Bb]y)\*{0,2}:\*{0,2}[[:space:]]*\*{0,2}[[:space:]]*[A-Z][a-z]+([ -][A-Z][a-z]+)+)|(^[[:space:]]*[-*>#]{0,3}[[:space:]]*(—|--)[[:space:]]+[A-Z][a-z]+([ -][A-Z][a-z]+)+)|(^[[:space:]]*[-*>#]{0,3}[[:space:]]*[Bb]y[[:space:]]+[A-Z][a-z]+([ -][A-Z][a-z]+)+)'
# NAME_FIELD — a contact RECORD: a name key whose own line also carries a phone/lid/jid.
# This is what catches a bare first name in a test fixture, which no attribution heuristic
# can see. The same-line requirement keeps it quiet on { name: "Full Sync" }, and the group
# discriminator in is_exempt keeps it quiet on { type: 'group', name: 'Ops-Group' }: a GROUP
# has a label, a PERSON has an identity, and only the second one is PII.
RE_NAME_FIELD='([nN]ame["'"'"'`]?[[:space:]]*[:=][[:space:]]*["'"'"'`][A-Z][^"'"'"'`]{0,38}["'"'"'`][^;]{0,90}(phone|mobile|lid|jid|msisdn|whatsapp|number))|((phone|mobile|lid|jid|msisdn|whatsapp|number)["'"'"'`]?[[:space:]]*[:=][^;]{0,90}[nN]ame["'"'"'`]?[[:space:]]*[:=][[:space:]]*["'"'"'`][A-Z][^"'"'"'`]{0,38}["'"'"'`])'

RULES="IL_PHONE NANP WA_LID WA_GROUP WA_JID WA_MSGID EMAIL IPV4 HOME_PATH WIN_PATH UNIX_PATH SLUG SLACK_ID GOOGLE_ID TUNNEL_HOST SECRET NAME_ATTRIB NAME_FIELD"
# Rules whose pattern comes from a machine-local file rather than from this script. Both
# ship ABSENT and are skipped silently when missing — a proper noun has no shape, and
# listing real ones here would BE the leak this file exists to prevent.
FILE_RULES="NAME_DENY DENY"

rule_re() {
  case "$1" in
    IL_PHONE)    printf '%s' "$RE_IL_PHONE" ;;
    NANP)        printf '%s' "$RE_NANP" ;;
    WA_LID)      printf '%s' "$RE_WA_LID" ;;
    WA_GROUP)    printf '%s' "$RE_WA_GROUP" ;;
    WA_JID)      printf '%s' "$RE_WA_JID" ;;
    WA_MSGID)    printf '%s' "$RE_WA_MSGID" ;;
    EMAIL)       printf '%s' "$RE_EMAIL" ;;
    IPV4)        printf '%s' "$RE_IPV4" ;;
    HOME_PATH)   printf '%s' "$RE_HOME_PATH" ;;
    WIN_PATH)    printf '%s' "$RE_WIN_PATH" ;;
    UNIX_PATH)   printf '%s' "$RE_UNIX_PATH" ;;
    SLUG)        printf '%s' "$RE_SLUG" ;;
    SLACK_ID)    printf '%s' "$RE_SLACK_ID" ;;
    GOOGLE_ID)   printf '%s' "$RE_GOOGLE_ID" ;;
    TUNNEL_HOST) printf '%s' "$RE_TUNNEL_HOST" ;;
    SECRET)      printf '%s' "$RE_SECRET" ;;
    NAME_ATTRIB) printf '%s' "$RE_NAME_ATTRIB" ;;
    NAME_FIELD)  printf '%s' "$RE_NAME_FIELD" ;;
  esac
}

# The remedy printed next to every hit. A scanner that says "failed" without saying what to
# put there instead gets bypassed on the next deadline.
rule_fix() {
  case "$1" in
    IL_PHONE)    printf '%s' 'use the documented IL placeholder from README.md:194 (972 5 followed by zeros) — or, if runtime code truly needs the number, read an env var and refuse loudly when unset (agent/remind-teammate.js is the model)' ;;
    NANP)        printf '%s' 'use a reserved-for-fiction NANP number: +1 (555) 010-0000 / 15550100000' ;;
    WA_LID)      printf '%s' 'use the placeholder LID family (1 + twelve zeros + a 1-2 digit tail): ...001 for self, ...002 for a second party; keep the @lid suffix' ;;
    WA_GROUP)    printf '%s' 'use the placeholder group id 120363000000000000 (+ @g.us where a JID is meant); the real group id belongs in ~/.claude/.wa-bridge.json' ;;
    WA_JID)      printf '%s' 'placeholder digits + @s.whatsapp.net; a real JID belongs in ~/.claude/.wa-bridge.json, never in a fixture' ;;
    WA_MSGID)    printf '%s' 'use 3EB0EXAMPLE0000000000 — a parser only needs a token-shaped string' ;;
    EMAIL)       printf '%s' 'use you@example.com; a real commit identity belongs in ~/.claude/.governance-local.env (GOV_GIT_AUTHOR_EMAIL)' ;;
    IPV4)        printf '%s' 'use a <HOST> placeholder or an env var from ~/.claude/.governance-local.env; RFC5737 203.0.113.10 is the documentation range' ;;
    HOME_PATH)   printf '%s' 'a home directory names its owner: write C:\Users\<user>\... or /c/Users/<user>/..., or better %USERPROFILE% / $HOME / ~' ;;
    WIN_PATH)    printf '%s' 'use C:\dev\example-project or %USERPROFILE%\.claude\... — never a real private checkout' ;;
    UNIX_PATH)   printf '%s' 'use /opt/example-project or <SOURCE_REPO>; a real deployment path belongs in the machine-local config' ;;
    SLUG)        printf '%s' 'use the fixture slug c--dev-example-project' ;;
    SLACK_ID)    printf '%s' 'use C0EXAMPLE01 / U0EXAMPLE01 / T0EXAMPLE01 and example.slack.com' ;;
    GOOGLE_ID)   printf '%s' 'a Drive/Docs/Sheets id is a live pointer at a private document: use 1EXAMPLE_FILE_ID or read it from the machine-local config' ;;
    TUNNEL_HOST) printf '%s' 'a tunnel host is an open door while it is up: use example.ngrok.io or <TUNNEL_HOST>, and rotate the real one if it was published' ;;
    SECRET)      printf '%s' 'ROTATE IT FIRST, then replace with an EXAMPLE-marked stub and read the real one from the environment — removing it from the file is not enough' ;;
    NAME_ATTRIB) printf '%s' 'a public bundle should not name a private person: use "Operator One", "the operator", or a role ("the owner")' ;;
    NAME_FIELD)  printf '%s' 'a fixture contact record needs a shape, not an identity: use { name: "Operator One", phone: "+972500000000" }' ;;
    NAME_DENY)   printf '%s' 'a proper noun from your machine-local name list (~/.claude/.pii-names): replace with "Operator One" / "the operator"' ;;
    DENY)        printf '%s' 'a proper noun from your machine-local denylist: replace with "the operator" / "example-project" / <SOURCE_REPO>' ;;
  esac
}

# Case-insensitive `case` and digit-stripping WITHOUT forking. Every "$(_lower "$x")" was
# a subshell, and a subshell costs ~10ms on Windows; this file spent 17 of its 18 seconds
# per scanned file inside fork(), not inside grep. nocasematch + parameter expansion removes
# the forks and stays portable to bash 3.2, which is what macOS still ships.
shopt -s nocasematch 2>/dev/null

# Every helper below declares its scratch variables `local`. Learned the hard way during
# --selftest: `_ip_is_exempt` used a bare `r` for "rest of the dotted quad", which is the
# same name the scan loop uses for the CURRENT RULE. The exemption silently stopped working
# and hits were printed under a rule named "[0.0]". A scanner with a shadowed loop variable
# reports nonsense confidently, which is worse than not running at all.
# --- digit strings that are documented placeholders and must never fire ---------
# True when $1 is a run of zeros carrying at most a 3-digit tail, with at least $2 zeros.
# "Almost all zeros" is a shape no real phone, LID or group id has.
_mostly_zeros() {
  local d nz zeros
  d="$1"; nz="${d//0/}"; zeros=$(( ${#d} - ${#nz} ))
  [ ${#nz} -le 3 ] && [ "$zeros" -ge "${2:-6}" ]
}
_is_placeholder_digits() {
  local d t
  d="$1"
  # IL placeholder: 972 5 then a subscriber part written only with 0 and 9. That covers the
  # documented 972500000000 and the sibling fixtures this framework already uses for "a
  # second party" (…000999, …99999999). No real Israeli mobile is spelled in two digits.
  case "$d" in
    972*) t="${d#9725}"; [ ${#d} -eq 12 ] && [ -n "$t" ] && [ -z "${t//[09]/}" ] && return 0 ;;
    05*)  t="${d#05}";   [ ${#d} -eq 10 ] && [ -n "$t" ] && [ -z "${t//[09]/}" ] && return 0 ;;
    5*)   t="${d#5}";    [ ${#d} -eq 9 ]  && [ -n "$t" ] && [ -z "${t//[09]/}" ] && return 0 ;;
  esac
  # NANP reserved-for-fiction: 555-01xx
  case "$d" in 155501*|55501*) return 0 ;; esac
  # Placeholder families, generalised. A fixture whose point is that two ids differ needs
  # sibling placeholders (…0001 vs …0002), so the test is structural rather than literal:
  # mostly zeros, with at most a 3-digit tail to tell the siblings apart.
  # placeholder LID family: a leading digit + a long run of zeros + a short tail
  case "$d" in [1-9]0000000*)
    [ ${#d} -ge 12 ] && [ ${#d} -le 20 ] && _mostly_zeros "$d" 8 && return 0 ;;
  esac
  # placeholder group id: 120363 followed by nothing but zeros
  # placeholder group id: 120363 + a long run of zeros + an optional short tail
  case "$d" in 120363*) t="${d#120363}"; [ -n "$t" ] && _mostly_zeros "$t" 6 && return 0 ;; esac
  # A run of one repeated digit (111111111111111111) identifies nobody, and neither does a
  # run too short to be any real identity (999999@g.us, 222333@g.us). Both are fixture
  # spellings this framework's own tests already use.
  t="${d//${d:0:1}/}"; [ -n "$d" ] && [ -z "$t" ] && return 0
  [ ${#d} -lt 9 ] && return 0
  return 1
}

_ip_is_exempt() {
  local ip rest o1 o2 o3 o4 o
  ip="$1"
  o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"; rest="${rest#*.}"; o3="${rest%%.*}"; o4="${rest##*.}"
  case "$o1$o2$o3$o4" in *[!0-9]*) return 0 ;; esac
  # A leading-zero octet means this is not a canonical IPv4 literal. It is how a version
  # string sneaks in: "1.0.0" + "2.0.0" concatenated reads as 1.0.02.0 and fired here.
  case ".$ip" in *.0[0-9]*) return 0 ;; esac
  for o in "$o1" "$o2" "$o3" "$o4"; do [ "$o" -gt 255 ] 2>/dev/null && return 0; done
  [ "$o1" -eq 0 ] && return 0                                            # 0.0.0.0 and friends
  [ "$o1" -eq 127 ] && return 0                                          # loopback
  [ "$o1" -eq 10 ] && return 0                                           # RFC1918
  [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ] && return 0                     # RFC1918
  [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ] && return 0  # RFC1918
  [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ] && return 0                     # link-local
  [ "$o1" -eq 192 ] && [ "$o2" -eq 0 ] && [ "$o3" -eq 2 ] && return 0    # RFC5737 doc range
  [ "$o1" -eq 198 ] && [ "$o2" -eq 51 ] && [ "$o3" -eq 100 ] && return 0 # RFC5737 doc range
  [ "$o1" -eq 203 ] && [ "$o2" -eq 0 ] && [ "$o3" -eq 113 ] && return 0  # RFC5737 doc range
  [ "$o1" -eq 198 ] && [ "$o2" -ge 18 ] && [ "$o2" -le 19 ] && return 0  # benchmark range
  [ "$o1" -ge 224 ] && return 0                                          # multicast/reserved
  return 1
}

# Windows roots that are not anybody's private checkout.
_win_root_ok() {
  case "$1" in
    windows|winnt|programdata|program|tmp|temp|inetpub|perflogs|recovery) return 0 ;;
  esac
  return 1
}
# A path segment that names nobody. Two families:
#   - the documented placeholders (example-project, U, %USERPROFILE%, <SOMETHING>)
#   - metasyntactic names that saturate this framework's own test fixtures (repo, foo, a, x)
# Without this second family the scanner produced 30+ hits on strings like C:\repo\docs and
# /c/foo. Every one of those is a false alarm, and false alarms are how a gate gets turned off.
_seg_is_placeholder() {
  local s
  s="${1%%.}"; s="${s%.}"
  case "$s" in
    example|example-project|dev|u) return 0 ;;
    repo|repos|*-repo|project|projects|proj|proj-*|*-proj|testproj|dir|path|file|files) return 0 ;;
    foo|bar|baz|qux|new|old|src|test|tests|tmp|temp|work|sample|placeholder|somewhere|node) return 0 ;;
    # Generic ROLE words used as stand-in path names in prose: "C:\Stale is retired; use
    # C:\Canonical", "C:\the source repo\". They name a role, never a person or a checkout.
    # Deliberately excludes "user" — that one IS the leaking Windows account name.
    the|this|that|your|my|a|an|source|client|target|current|canonical|stale|retired|other|another|some) return 0 ;;
    ?) return 0 ;;                       # single-letter stand-ins: C:\a\b, /c/x, t:\n
    '...'|'..'|'.') return 0 ;;
  esac
  case "$1" in
    '<'*|'%'*|'$'*|'~'*|'{'*|'*'*) return 0 ;;
  esac
  return 1
}

# A home-directory segment that names nobody: the placeholders above, plus the service and
# CI accounts a public bundle legitimately mentions. "user" is NOT here — a literal
  # A literal home path under the operator's own account name IS the leak this
  # rule exists to catch, so that segment must never be exempted here.
_home_seg_ok() {
  case "$1" in
    node|root|runner|ubuntu|vagrant|docker|jenkins|www-data|public|default|all|shared) return 0 ;;
  esac
  _seg_is_placeholder "$1" && return 0
  return 1
}

# Tokens that stand in for a person instead of naming one. Used by NAME_ATTRIB / NAME_FIELD,
# where a match is exempt only when EVERY token is generic. That asymmetry matters: the
# operator's own first name is an ordinary English word, and an ANY-token rule would have
# exempted the exact value round 2 exists to catch.
_name_token_generic() {
  case "$1" in
    operator|one|two|three|example|placeholder|sample|someone|anyone|nobody|somebody) return 0 ;;
    claude|code|fable|anthropic|openai|codex|agent|bot|assistant|system|team|group) return 0 ;;
    user|users|test|tests|demo|dummy|fixture|the|this|your|our|their|my|its) return 0 ;;
    name|names|first|last|firstname|lastname|full|real|unknown|none|tbd|na|redacted) return 0 ;;
    owner|author|maintainer|contact|admin|administrator|client|customer|person|people) return 0 ;;
    project|source|target|default|main|self|other|another|new|old) return 0 ;;
  esac
  return 1
}
_name_all_generic() {
  local s w
  s="${1//-/ }"
  for w in $s; do
    _name_token_generic "$w" || return 1
  done
  return 0
}
# Pull the quoted value out of a NAME_FIELD match. Quote characters are normalised to " via
# octal escapes so this line does not itself become a quoting puzzle.
_name_field_value() {
  printf '%s' "$1" | tr '\047\140' '\042\042' \
    | sed -nE 's/.*[nN]ame"?[[:space:]]*[:=][[:space:]]*"([^"]*)".*/\1/p'
}

# $1 rule, $2 match, $3 line number, $4 "1" if the line carries phone-ish context (NANP only)
is_exempt() {
  local rule m lno hasctx d dd dom p s1 s2 u0 u1 u2 _rest cand sub
  rule="$1"; m="$2"; lno="${3:-0}"; hasctx="${4:-1}"
  case "$rule" in
    IL_PHONE|WA_GROUP)
      dd="${m%%@*}"; _is_placeholder_digits "${dd//[!0-9]/}" && return 0 ;;
    WA_LID)
      dd="${m%%@*}"; _is_placeholder_digits "${dd//[!0-9]/}" && return 0 ;;
    NANP)
      d="${m//[!0-9]/}"
      _is_placeholder_digits "$d" && return 0
      # 13-digit epoch-milliseconds are timestamps, not phone numbers
      [ ${#d} -eq 13 ] && case "$d" in 1[5-9]*) return 0 ;; esac
      # A naked 10-digit run is the ambiguous spelling: it is also every order number and
      # every id in the tree. Require phone-ish context ON THE LINE. Documented as a
      # deliberate blind spot rather than a silent one: an unpunctuated 10-digit number on a
      # line that says nothing about phones does not get flagged.
      case "$d" in 21474836[0-9][0-9]|429496729[0-9]) return 0 ;; esac   # int32/uint32 limits
      [ "$m" = "$d" ] && [ ${#d} -eq 10 ] && [ "$hasctx" != "1" ] && return 0 ;;
    WA_JID)
      _is_placeholder_digits "${m%%@*}" && return 0 ;;
    WA_MSGID)
      case "$m" in *EXAMPLE*) return 0 ;; esac ;;
    EMAIL)
      dom="${m##*@}"
      case "$dom" in
        example.com|example.org|example.net|*.example.com|localhost|*.local) return 0 ;;
        s.whatsapp.net|g.us) return 0 ;;
      esac
      # A vendor no-reply box identifies nobody. This exempts the LOCAL PART only, so a
      # GitHub-style "<id>+<username>@users.noreply.github.com" commit identity still fires:
      # there the person is named to the LEFT of the @ and "noreply" is merely the domain.
      # (Written as a shape on purpose. A comment that quotes the value it is sanitising
      #  re-creates the leak — this scanner caught exactly that in its own first draft.)
      dd="${m%@*}"
      case "$dd" in noreply|no-reply|donotreply) return 0 ;; esac ;;
    IPV4)
      _ip_is_exempt "$m" && return 0 ;;
    HOME_PATH)
      p="${m//\\//}"
      cand="${p##*/}"
      _home_seg_ok "$cand" && return 0 ;;
    WIN_PATH)
      # "https://github.com/..." reads as drive "s" + path "//github.com/...". A URL is not
      # a private checkout; without this the scanner flags every https:// link it sees.
      case "$m" in *://*) return 0 ;; esac
      p="${m//\\//}"; p="${p#*:}"
      while :; do case "$p" in /*) p="${p#/}" ;; *) break ;; esac; done
      s1="${p%%/*}"; s2=""
      case "$p" in */*) s2="${p#*/}"; s2="${s2%%/*}" ;; esac
      _win_root_ok "$s1" && return 0
      case "$s1" in
        users) return 0 ;;   # HOME_PATH owns this shape and prints the right remedy
        dev) { [ -z "$s2" ] || _seg_is_placeholder "$s2"; } && return 0 ;;
        *) _seg_is_placeholder "$s1" && return 0 ;;
      esac ;;
    UNIX_PATH)
      case "$m" in *://*) return 0 ;; esac
      p="${m#/}"
      case "$p" in mnt/c/*) p="c/${p#mnt/c/}" ;; esac
      IFS='/' read -r u0 u1 u2 _rest <<EOF
$p
EOF
      # The interesting segment is the one that names a person or a checkout: the component
      # under the root, except beneath a Users/ directory, where it is the username.
      case "$u0" in
        # "dev" is a container root, not a name -- the same treatment WIN_PATH already
        # gives it. Without this, /c/dev/<anything> reported the word "dev".
        c|users) case "$u1" in users|dev) cand="$u2" ;; *) cand="$u1" ;; esac ;;
        *)       cand="$u1" ;;
      esac
      # Home shapes are HOME_PATH's kind. Handing them over keeps one value to one rule with
      # one remedy, instead of two hits that disagree about what the problem is.
      case "$u0" in
        home) [ -n "$u1" ] && return 0 ;;
        c|users) case "$u1" in users) [ -n "$u2" ] && return 0 ;; esac ;;
      esac
      [ -z "$cand" ] && return 0                    # "/c/Users" on its own names nobody
      case "$cand" in app|node|src|bin|lib|share|log|logs|usr|etc|www|opt) return 0 ;; esac
      _seg_is_placeholder "$cand" && return 0 ;;
    SLUG)
      cand="${m#c--}"; cand="${cand//-/ }"; sub=1
      for u0 in $cand; do _seg_is_placeholder "$u0" || { sub=0; break; }; done
      [ "$sub" = 1 ] && return 0 ;;
    SLACK_ID|GOOGLE_ID|TUNNEL_HOST)
      case "$m" in *example*|*placeholder*|*your*|*sample*|*redacted*) return 0 ;; esac
      # a run of one repeated character identifies nothing
      sub="${m//[.-]/}"
      [ -n "$sub" ] && [ -z "${sub//${sub:0:1}/}" ] && return 0 ;;
    SECRET)
      case "$m" in
        *example*|*placeholder*|*your*|*sample*|*redacted*|*dummy*|*fake*|*xxxx*|*000000*) return 0 ;;
      esac ;;
    NAME_ATTRIB)
      # Weak forms are prose outside a document header, where they generate noise.
      case "$m" in
        —*|--*|[Bb]y[[:space:]]*) [ "$lno" -gt 20 ] 2>/dev/null && return 0 ;;
      esac
      cand="$(printf '%s' "$m" | sed -E 's/^.*[:—]//; s/^--//; s/^[[:space:]]*//; s/^\*+//; s/^[[:space:]]*//; s/^[Bb]y[[:space:]]+//; s/\*+$//; s/[[:space:]]*$//')"
      _name_all_generic "$cand" && return 0 ;;
    NAME_FIELD)
      # A group's display name is not a person. Measured on the real tree: this single test
      # cut NAME_FIELD from 16 hits to the 2 that were real.
      case "$m" in *@g.us*|*group*|*1203[0-9][0-9][0-9][0-9]*) return 0 ;; esac
      cand="$(_name_field_value "$m")"
      # ONLY a single character is a label. The first cut of this used < 3 and silently
      # exempted a real two-letter first name that is still in the tree -- the exact value
      # this round exists to catch. A length threshold is a denylist with a number on it:
      # set it as tight as the shortest real name, not as loose as the noisiest fixture.
      [ ${#cand} -lt 2 ] && return 0
      _name_all_generic "$cand" && return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# File-driven rules — machine-local, ship ABSENT on purpose.
# One literal per line, '#' comments and blank lines ignored. Matched case-insensitively.
# They exist because proper nouns (a person's name, a private project's name) have no shape;
# they live outside this file because listing them here would BE the leak.
# ---------------------------------------------------------------------------
DENY_RE=""; NAMES_RE=""; NAMES_N=0
_compile_list() {   # $1 = file -> alternation on stdout, or nothing
  [ -f "$1" ] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1" 2>/dev/null \
    | sed -e 's/[][\.^$*+?(){}|\\]/\\&/g' | paste -sd'|' - 2>/dev/null
}
load_denylist() { DENY_RE="$(_compile_list "$DENYLIST_FILE")"; }
load_names() {
  local body
  body="$(_compile_list "$NAMES_FILE")"
  [ -n "$body" ] || return 0
  NAMES_N="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$NAMES_FILE" 2>/dev/null | wc -l | tr -d ' ')"
  NAMES_RE="\\b(${body})\\b"
}

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------
HITS=0; ALLOWED=0; ALLOWED_LINES=0; FILES_SCANNED=0; FILES_DIRTY=0

skip_file() {
  b="$(basename "$1")"
  case "$b" in
    .governance-local.env|.governance-mirrors|.governance-pii-denylist|.pii-names|.wa-bridge.json) return 0 ;;
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.gz|*.exe|*.dll|*.dat|*.bin|*.woff|*.woff2|*.ttf) return 0 ;;
  esac
  case "$1" in */.git/*|*/node_modules/*|*/.venv/*) return 0 ;; esac
  [ -f "$1" ] || return 0
  grep -Iq . "$1" 2>/dev/null || return 0   # binary
  return 1
}

report_hit() {
  HITS=$((HITS+1)); file_dirty=1
  printf '%s:%s: [%s] %s\n' "$1" "$2" "$3" "$4"
  printf '    -> %s\n' "$(rule_fix "$3")"
}

# One grep per rule per FILE, not per line. The first version spawned ~13 greps for every
# candidate LINE and took minutes on ~/.claude/hooks alone. A gate that slow gets skipped
# "just this once", which is the same way a noisy gate dies — so speed is a correctness
# property here, not a nicety.
# Phone-ish context lines, as " 12 40 " for substring testing. Computed at most ONCE per
# file, and only if a naked 10-digit run actually turned up: one grep, never one sed per hit.
# The first cut of this rule shelled out per hit and pushed a 97-file tree past two minutes,
# which is how a gate ends up commented out.
PHONE_LINES=""; PHONE_DONE=0
_phone_ctx_lines() {
  [ "$PHONE_DONE" -eq 1 ] && return 0
  PHONE_LINES=" $(grep -niE 'phone|mobile|tel|cell|whats|sms|msisdn|number|contact|call|dial|operator' -- "$1" 2>/dev/null | cut -d: -f1 | paste -sd' ' -) "
  PHONE_DONE=1
}

scan_file() {
  local f allow_lines re raw ln m ctx d10
  f="$1"
  skip_file "$f" && return 0
  FILES_SCANNED=$((FILES_SCANNED+1))
  file_dirty=0
  PHONE_LINES=""; PHONE_DONE=0

  # Line numbers carrying a deliberate exception marker, as " 12 40 " for substring testing.
  allow_lines=" $(grep -n 'pii-allow:' -- "$f" 2>/dev/null | cut -d: -f1 | paste -sd' ' -) "
  [ "$allow_lines" != "  " ] && ALLOWED_LINES=$((ALLOWED_LINES + $(printf '%s' "$allow_lines" | wc -w)))

  for r in $RULES $FILE_RULES; do
    case "$r" in
      DENY)      [ -n "$DENY_RE" ]  || continue; raw="$(grep -noiE "$DENY_RE" -- "$f" 2>/dev/null | sort -u)" ;;
      NAME_DENY) [ -n "$NAMES_RE" ] || continue; raw="$(grep -noiE "$NAMES_RE" -- "$f" 2>/dev/null | sort -u)" ;;
      *) re="$(rule_re "$r")"; raw="$(grep -noE "$re" -- "$f" 2>/dev/null | sort -u)" ;;
    esac
    [ -n "$raw" ] || continue
    while IFS= read -r nl; do
      [ -n "$nl" ] || continue
      ln="${nl%%:*}"; m="${nl#*:}"
      case "$r" in
        DENY|NAME_DENY) : ;;
        NANP)
          # Only the naked 10-digit spelling is ambiguous enough to need the line around it.
          ctx=1
          d10="${m//[!0-9]/}"
          if [ "$m" = "$d10" ] && [ ${#d10} -eq 10 ]; then
            _phone_ctx_lines "$f"
            case "$PHONE_LINES" in *" $ln "*) ctx=1 ;; *) ctx=0 ;; esac
          fi
          is_exempt "$r" "$m" "$ln" "$ctx" && continue ;;
        *) is_exempt "$r" "$m" "$ln" && continue ;;
      esac
      case "$allow_lines" in *" $ln "*) ALLOWED=$((ALLOWED+1)); continue ;; esac
      report_hit "$f" "$ln" "$r" "$m"
    done <<EOF
$raw
EOF
  done
  [ "$file_dirty" -eq 1 ] && FILES_DIRTY=$((FILES_DIRTY+1))
  return 0
}

summary_and_exit() {
  rm -f "$TMPMATCH" 2>/dev/null
  echo
  # The state of the machine-local name list is reported on every run. It is allowed to be
  # absent, but it is never allowed to be absent QUIETLY: "the scan was clean" has to be
  # readable as "clean, with the name list off".
  if [ -n "$NAMES_RE" ]; then
    echo "check-no-pii: name list: $NAMES_N entr(ies) from $NAMES_FILE (+ structural name rules)"
  else
    echo "check-no-pii: name list: none at $NAMES_FILE — structural name rules only (NAME_ATTRIB, NAME_FIELD)"
  fi
  echo "check-no-pii: scanned $FILES_SCANNED file(s) — $HITS hit(s) in $FILES_DIRTY file(s), honoured $ALLOWED allowlisted exception(s) on $ALLOWED_LINES line(s)"
  if [ "$HITS" -gt 0 ]; then
    echo "check-no-pii: FAIL — a file that can reach the public repo carries a real value."
    echo "check-no-pii: fix the DATA, not this scanner: put the real value in ~/.claude/.governance-local.env"
    echo "check-no-pii: (see .governance-local.env.example) and leave a placeholder or an env lookup behind."
    exit 2
  fi
  echo "check-no-pii: PASS"
  exit 0
}

# ---------------------------------------------------------------------------
# --selftest — must go RED on real-shaped values and GREEN on every placeholder.
# The dirty values are SYNTHETIC and are assembled from fragments at runtime, so no
# complete matching shape exists as a literal in this file: a scanner whose own fixtures
# trip it is a scanner nobody can run over its own tree.
# ---------------------------------------------------------------------------
selftest() {
  # Re-invoking "$0" breaks when the script was started by a bare relative name
  # (`bash check-no-pii.sh`), which is exactly how a hook usually runs. Resolve self first.
  SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  [ -f "$SELF" ] || SELF="$0"
  TD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/pii-selftest.$$")"; mkdir -p "$TD" || return 1
  SOME='Someone'; PRIV='private-thing'; PRIV_UP='PRIVATE'
  ILT='521234567'; LIDT='98765'; GTAIL='987654321098'; NTAIL='2671'; HEXTAIL='A1B2C3D4E5F60718'
  IPH='8.8'; WROOT='my-private-checkout'; SLUGT='my-private-project'
  HUSER='j'; HUSER="${HUSER}doe-priv"                 # a home dir that names a person
  B10='4155'; B10="${B10}551234"                       # naked 10-digit NANP
  B10P='415-'; B10P="${B10P}555-1234"                   # the punctuated spelling
  FN='Rav'; FN="${FN}enna"; LN='Black'; LN="${LN}wood" # attributed person
  DFN='Thadd'; DFN="${DFN}eus"; DLN='V'; DLN="${DLN}ex"   # person known only to the local list
  GID='1Ab'; GID="${GID}Cd3fGh5jKl7mNp9qRs1tUv3wXy5zAb7cDe9fGh1"  # 44-char Drive id
  TUN='mybox-42'; SEC='gh'; SEC="${SEC}p_"; SECT='Ab3Cd5Ef7Gh9Jk1Lm3Np5Qr7St9Uv1Wx'

  {
    echo "owner: ${FN} ${LN}"
    echo "-- ${FN} ${LN}"
    echo "il  +972${ILT}"
    echo "nanp phone +1 (415) 555-${NTAIL} and ${B10P} and ${B10}"
    echo "lid 9876543210${LIDT} and 9876543210${LIDT}@lid"
    echo "group 120363${GTAIL} and 120363${GTAIL}@g.us"
    echo "jid 972${ILT}@s.whatsapp.net"
    echo "msgid 3EB0${HEXTAIL}"
    echo "mail ${SOME}@internal-corp.io"
    echo "ip ${IPH}.${IPH}"
    echo "home C:\\Users\\${HUSER}\\checkout"
    echo "winroot D:\\${WROOT}"
    echo "unixpath /opt/${PRIV}"
    echo "slug c--${SLUGT}"
    echo "slack C0${PRIV_UP}01"
    echo "drive https://docs.google.com/spreadsheets/d/${GID}/edit"
    echo "tunnel ${TUN}.ngrok.io"
    echo "secret ${SEC}${SECT}"
    echo "record { name: '${FN}', phone: '+972${ILT}' }"
    echo "shortname { \"type\": \"dm\", \"name\": \"${FN:0:2}\", \"phone\": \"+972${ILT}\" }"
    echo "deny-name mentioned inline: ${DFN} ${DLN} was here"
    echo "deny AcmeSecretProject"
  } > "$TD/dirty.txt"

  {
    echo "il 972500000000 and +972 50 000 0000 and 050-000-0000"
    echo "nanp +1 (555) 010-0000 and 15550100000 and 555-010-0000"
    echo "lid 100000000000001 and 100000000000002 and 100000000000001@lid and 200000000000002"
    echo "group 120363000000000000 and 120363000000000000@g.us and 120363000000000001@g.us"
    echo "jid 972500000000@s.whatsapp.net 999999@g.us 111111111111111111@g.us"
    echo "msgid 3EB0EXAMPLE0000000000"
    echo "mail you@example.com noreply@anthropic.com"
    echo "il-siblings +972500000999 +972599999999"
    echo "ip 127.0.0.1 0.0.0.0 192.168.1.10 10.0.0.5 172.17.0.1 203.0.113.10"
    echo "paths C:\\dev\\example-project  C:\\Users\\U\\.claude  %USERPROFILE%\\.claude  ~/.claude"
    echo "homes C:\\Users\\<user>\\.claude  /c/Users/<user>/.claude  /mnt/c/Users/U/x  /home/node/.openclaw"
    echo "winsys C:\\Program Files\\nodejs\\node.exe  C:\\Windows\\System32"
    echo "unix /opt/example-project  /home/runner/work  /c/dev  /c/dev/proj  /c/dev/testproj"
    echo 'metaproj c:/dev/proj-other  c:/dev/Proj-A  c:/dev/other-repo'
    echo "repo <SOURCE_REPO> and the client repo"
    echo "slug c--dev-example-project and c--dev-foo"
    echo "slack C0EXAMPLE01 U0EXAMPLE01 T0EXAMPLE01 example.slack.com"
    echo "drive https://docs.google.com/spreadsheets/d/1EXAMPLE_SHEET_ID_00000000000000000000000/edit"
    echo "tunnel example.ngrok.io  placeholder.trycloudflare.com"
    echo "secret ghp_EXAMPLE0000000000000000000000000000"
    echo "# GUIDE.md -- Agent Operational Guide"   # a title, not a byline
    echo "attrib **Owner:** Operator One / **Author:** Claude Code / by Operator One"
    echo "record { name: 'Operator One', phone: '+972500000000', lid: '100000000000001' }"
    echo "group  { jid: '120363000000000000@g.us', type: 'group', name: 'Ops-Group' }"
    echo "grouplbl { jid: '111111111111111111', name: 'G' }"   # one char is a label
    echo "epoch 1755000000000"
    echo "sentinel pid: 2147483646, // a valid Number, not a phone number"
    # Regression guards for real false positives this scanner produced on its first live run
    # over ~/.claude/hooks. Each was noise, and noise is what gets a gate switched off.
    echo "url https://github.com/example/repo.git"
    echo "version 1.0.02.0.0"
    echo 'metasyntactic C:\repo\docs  C:\a\b  C:\foo\bar  /c/repo  /c/foo  /c/Users'
    echo 'rolewords C:\Stale is retired, use C:\Canonical; C:\the source repo\'
    echo "bare-10 id ${B10} sits in prose here and must stay green"
    # A weak attribution far below the header region is prose, not a byline.
    i=0; while [ $i -lt 24 ]; do echo "filler line $i"; i=$((i+1)); done
    echo "prose: the queue is drained by Docker Compose in the deploy step"
  } > "$TD/clean.txt"

  echo "il  +972${ILT}   # pii-allow: selftest deliberate exception" > "$TD/allowed.txt"
  printf 'AcmeSecretProject\n' > "$TD/deny.txt"
  printf '%s %s\n' "$DFN" "$DLN" > "$TD/names.txt"
  printf 'owner: %s %s\nlid 9876543210%s\n' "$FN" "$LN" "$LIDT" > "$TD/nolist.txt"

  RC=0
  echo "--- selftest A: dirty fixture MUST go red -------------------------------"
  out_d="$(GOV_PII_DENYLIST="$TD/deny.txt" GOV_PII_NAMES="$TD/names.txt" "$SELF" "$TD/dirty.txt" 2>&1)"; rc_d=$?
  n_hits="$(printf '%s\n' "$out_d" | grep -cE '^.+:[0-9]+: \[')"
  n_rules="$(printf '%s\n' "$out_d" | grep -oE ': \[[A-Z0-9_]+]' | sort -u | wc -l | tr -d ' ')"
  # Expected = every rule in $RULES, plus every file-driven rule. Deliberately exact: if a
  # rule is added without a fixture that exercises it, this goes red rather than quietly
  # under-covering — which is precisely how round 1 shipped a scanner blind to names.
  n_expect=$(( $(printf '%s\n' $RULES | wc -l | tr -d ' ') + $(printf '%s\n' $FILE_RULES | wc -l | tr -d ' ') ))
  if [ "$rc_d" -eq 2 ] && [ "$n_rules" -eq "$n_expect" ]; then
    echo "  PASS: exit 2, $n_hits hit(s) covering all $n_rules rules"
    printf '%s\n' "$out_d" | grep -oE ': \[[A-Z0-9_]+]' | sort -u | tr -d ' :[]' | paste -sd' ' -
  else
    echo "  FAIL: exit $rc_d, $n_hits hit(s), $n_rules of $n_expect rules fired (expected exit 2, all rules)"
    printf '%s\n' "$out_d"; RC=1
  fi

  echo "--- selftest B: every documented placeholder MUST stay green -------------"
  out_c="$(GOV_PII_DENYLIST="$TD/deny.txt" GOV_PII_NAMES="$TD/names.txt" "$SELF" "$TD/clean.txt" 2>&1)"; rc_c=$?
  if [ "$rc_c" -eq 0 ]; then
    echo "  PASS: exit 0 on the placeholder fixture"
    printf '%s\n' "$out_c" | grep 'scanned'
  else
    echo "  FAIL: exit $rc_c — a placeholder fired. This is the failure mode that gets a scanner"
    echo "        disabled, so it is a hard failure here:"
    printf '%s\n' "$out_c"; RC=1
  fi

  echo "--- selftest C: pii-allow marker is honoured AND counted -----------------"
  out_a="$(GOV_PII_DENYLIST="$TD/deny.txt" GOV_PII_NAMES="$TD/names.txt" "$SELF" "$TD/allowed.txt" 2>&1)"; rc_a=$?
  if [ "$rc_a" -eq 0 ] && printf '%s' "$out_a" | grep -q 'honoured 1 allowlisted exception'; then
    echo "  PASS: exit 0 and the exception is reported, not silent"
    printf '%s\n' "$out_a" | grep 'scanned'
  else
    echo "  FAIL: exit $rc_a"; printf '%s\n' "$out_a"; RC=1
  fi

  echo "--- selftest D: this script scans clean against itself -------------------"
  out_s="$(GOV_PII_DENYLIST="$TD/none" GOV_PII_NAMES="$TD/none" "$SELF" "$SELF" 2>&1)"; rc_s=$?
  if [ "$rc_s" -eq 0 ]; then
    echo "  PASS: check-no-pii.sh is clean against its own rules"
  else
    echo "  FAIL: the scanner itself carries a real value:"; printf '%s\n' "$out_s"; RC=1
  fi

  echo "--- selftest E: with NO name list, the structural half still fires --------"
  # The point of splitting names into a local list AND a shape heuristic: a user who never
  # creates ~/.claude/.pii-names must still be protected against the attributed-name case.
  out_n="$(GOV_PII_DENYLIST="$TD/none" GOV_PII_NAMES="$TD/absent-on-purpose" "$SELF" "$TD/nolist.txt" 2>&1)"; rc_n=$?
  if [ "$rc_n" -eq 2 ] \
     && printf '%s\n' "$out_n" | grep -q '\[NAME_ATTRIB\]' \
     && ! printf '%s\n' "$out_n" | grep -q '\[NAME_DENY\]' \
     && printf '%s\n' "$out_n" | grep -q 'name list: none'; then
    echo "  PASS: NAME_ATTRIB fired, NAME_DENY skipped, and the skip is REPORTED not silent"
    printf '%s\n' "$out_n" | grep 'name list:'
  else
    echo "  FAIL: exit $rc_n"; printf '%s\n' "$out_n"; RC=1
  fi

  rm -rf "$TD" 2>/dev/null
  echo
  if [ "$RC" -eq 0 ]; then
    echo "check-no-pii --selftest: ALL PASS (v$VERSION) — $n_expect rules ($(printf '%s\n' $RULES | wc -l | tr -d ' ') shape + $(printf '%s\n' $FILE_RULES | wc -l | tr -d ' ') file-driven)"
    exit 0
  fi
  echo "check-no-pii --selftest: FAILED"
  exit 1
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
if [ "${GOVERNANCE_HOOKS:-1}" = "0" ] && [ -n "${CLAUDE_HOOK:-}" ]; then [ "${GOV_BYPASS_QUIET:-0}" = "1" ] || echo "[governance] GOVERNANCE_HOOKS=0 — bypassing check-no-pii (hook mode; scanner still runs when invoked directly). (GOV_BYPASS_QUIET=1 to mute)" >&2; exit 0; fi

case "${1:-}" in
  ""|-h|--help)
    sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
  --list-rules)
    for r in $RULES; do printf '%-12s %s\n             -> %s\n' "$r" "$(rule_re "$r")" "$(rule_fix "$r")"; done
    printf '%-12s (machine-local file: %s)\n             -> %s\n' "NAME_DENY" "$NAMES_FILE" "$(rule_fix NAME_DENY)"
    printf '%-12s (machine-local file: %s)\n             -> %s\n' "DENY" "$DENYLIST_FILE" "$(rule_fix DENY)"
    exit 0 ;;
  --selftest) selftest ;;
esac

TMPMATCH="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/pii-match.$$")"
trap 'rm -f "$TMPMATCH" 2>/dev/null' EXIT

load_denylist
load_names

walk() {
  while IFS= read -r g; do [ -n "$g" ] && scan_file "$g"; done \
    < <(find "$1" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
}

if [ "$1" = "--tree" ]; then
  [ -n "${2:-}" ] || { echo "check-no-pii: --tree needs a directory" >&2; exit 1; }
  [ -d "$2" ] || { echo "check-no-pii: not a directory: $2" >&2; exit 1; }
  walk "$2"
else
  for f in "$@"; do
    if [ -d "$f" ]; then walk "$f"; else scan_file "$f"; fi
  done
fi

summary_and_exit
