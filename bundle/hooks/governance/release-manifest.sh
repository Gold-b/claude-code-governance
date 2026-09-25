#!/usr/bin/env bash
# release-manifest.sh — library: ONE definition of a signed release's file set, sourced by both
# gov-release.sh (the writer, source machine only) and gov-update.sh (the reader, every client).
#
# library: sourced by gov-release.sh, gov-update.sh and tests/test-gov-update.sh; never run alone.
#
# WHY ONE FILE. A writer and a reader that each carry their own idea of "which files" and "what
# format" drift apart silently, and the first sign would be every client halting a good release
# (or, worse, accepting a tree the writer never hashed). The build, the parser and the verifier
# live here together so they cannot disagree.
#
# FORMAT (plain text, LF, paths LC_ALL=C sorted):
#   # claude-code-governance release manifest v1
#   version=2.0.0
#   tag=v2.0.0
#   terms_version=1
#   created=2026-10-01T10:00:00Z
#   signers_sha256=<sha256 of bundle/release/allowed_signers>
#   files=93
#   [files]
#   <sha256>  <path>              every file of the tagged tree except RELEASE-MANIFEST*
#   [install-map]
#   <src> -> <dest>  <tag>        emitted by install.sh --print-install-map; tag = core|extended|agents
#
# HASHES COME FROM ARCHIVE CONTENT, NEVER A WORKING TREE. core.autocrlf=true on a Windows source
# machine means a checkout differs from the blob for every `text=auto` file; `git archive` is run
# with autocrlf/eol pinned so it produces exactly what GitHub's tag archive produces (the release
# tool proves that by downloading the real archive and verifying it before announcing success).
#
# No python, no network, no writes outside the paths a caller passes in. Every function returns
# non-zero on failure and prints its reason to stderr in the form `relman: <reason>`.

RELMAN_HEADER="# claude-code-governance release manifest v1"
RELMAN_NS="claude-code-governance-release"
RELMAN_PRINCIPAL="claude-code-governance-release"

_relman_err() { printf 'relman: %s\n' "$*" >&2; }

# relman_sha256_stdin_list <dir>
# Reads relative paths (one per line) on stdin, prints "<sha256>  <path>" per path, in input order.
# ONE sha256sum process for the whole list: per-file forks cost ~70 ms each on MSYS, which is 7 s
# for a release tree on a path that runs inside a session-start budget.
relman_sha256_stdin_list() {
  local dir="$1"
  (
    cd "$dir" 2>/dev/null || exit 1
    if command -v sha256sum >/dev/null 2>&1; then
      tr '\n' '\0' | xargs -0 sha256sum --
    else
      tr '\n' '\0' | xargs -0 shasum -a 256 --
    fi
  ) | sed 's/^\([0-9a-f]\{64\}\) [ *]/\1  /'
}

# relman_sha256 <file> -> hex digest of one file (or nothing)
relman_sha256() {
  local f="$1" d=""
  if command -v sha256sum >/dev/null 2>&1; then
    d=$(sha256sum -- "$f" 2>/dev/null)
  else
    d=$(shasum -a 256 -- "$f" 2>/dev/null)
  fi
  printf '%s' "${d%% *}"
}

# relman_tree_files <dir>
# Every regular file under <dir>, relative, LC_ALL=C sorted, minus the two root manifest files.
# Refuses (rc 1) on a path the manifest format cannot carry safely: whitespace, a backslash, or a
# leading dash. Such a name never exists in this repo; one appearing is a defect to see, not a
# character to escape.
relman_tree_files() {
  local dir="$1" list bad
  [ -d "$dir" ] || { _relman_err "no such tree: $dir"; return 1; }
  list=$(cd "$dir" && find . -type f ! -path './RELEASE-MANIFEST' ! -path './RELEASE-MANIFEST.sig' \
           | sed 's|^\./||' | LC_ALL=C sort) || return 1
  bad=$(printf '%s\n' "$list" | grep -n '[[:space:]\\]\|^-' | head -3)
  if [ -n "$bad" ]; then
    _relman_err "unsupported file name(s) in tree: $bad"
    return 1
  fi
  printf '%s\n' "$list"
}

# relman_archive_tree <repo> <tree-ish> <outdir>
# Extract <tree-ish> of <repo> into <outdir> exactly as GitHub's archive would produce it.
relman_archive_tree() {
  local repo="$1" treeish="$2" out="$3"
  mkdir -p "$out" || return 1
  git -C "$repo" -c core.autocrlf=false -c core.eol=lf archive --format=tar "$treeish" \
    | tar -xf - -C "$out" || { _relman_err "git archive of $treeish failed"; return 1; }
}

# relman_build <tree> <version> <terms_version> <install_map_file> [created]
# Prints the manifest for an extracted tree. <created> defaults to now (UTC); pass it explicitly
# to get a byte-identical rebuild.
relman_build() {
  local tree="$1" ver="$2" terms="$3" map="$4" created="${5:-}" files n signers
  [ -n "$created" ] || created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  signers="$tree/bundle/release/allowed_signers"
  [ -s "$signers" ] || { _relman_err "tree has no bundle/release/allowed_signers"; return 1; }
  [ -s "$map" ] || { _relman_err "install map is empty: $map"; return 1; }
  case "$terms" in ''|*[!0-9]*) _relman_err "terms_version must be an integer: '$terms'"; return 1 ;; esac
  files=$(relman_tree_files "$tree") || return 1
  n=$(printf '%s\n' "$files" | grep -c .)
  printf '%s\n' "$RELMAN_HEADER"
  printf 'version=%s\ntag=v%s\nterms_version=%s\ncreated=%s\n' "$ver" "$ver" "$terms" "$created"
  printf 'signers_sha256=%s\n' "$(relman_sha256 "$signers")"
  printf 'files=%s\n' "$n"
  printf '[files]\n'
  printf '%s\n' "$files" | relman_sha256_stdin_list "$tree" || return 1
  printf '[install-map]\n'
  tr -d '\r' < "$map" | grep -v '^[[:space:]]*$'
}

# relman_get <manifest> <key> -> header value (only lines before [files])
relman_get() {
  awk -v k="$2" '
    /^\[files\]$/ { exit }
    index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }
  ' "$1" 2>/dev/null
}

# relman_section <manifest> <files|install-map> -> the body lines of that section
relman_section() {
  awk -v want="[$2]" '
    /^\[[a-z-]+\]$/ { inside = ($0 == want); next }
    inside && length($0) { print }
  ' "$1" 2>/dev/null
}

# relman_validate_header <manifest> [expected_version]
# Well-formed: exact header line, every key once, both sections in order, files= equals the count,
# version is dotted-numeric, tag == v<version>, terms_version an integer, no CR anywhere.
relman_validate_header() {
  local m="$1" want="${2:-}" k v first n cnt
  [ -s "$m" ] || { _relman_err "manifest missing or empty"; return 1; }
  if grep -q $'\r' "$m" 2>/dev/null; then _relman_err "manifest has CR line endings"; return 1; fi
  IFS= read -r first < "$m" || true
  [ "$first" = "$RELMAN_HEADER" ] || { _relman_err "bad header line"; return 1; }
  for k in version tag terms_version created signers_sha256 files; do
    cnt=$(awk -v k="$k" '/^\[files\]$/{exit} index($0,k"=")==1{c++} END{print c+0}' "$m")
    [ "$cnt" = "1" ] || { _relman_err "header key '$k' appears $cnt times (want 1)"; return 1; }
  done
  n=$(awk '/^\[files\]$/{f=1} /^\[install-map\]$/{if(f==1)m=1} END{print (f==1&&m==1)?"ok":"no"}' "$m")
  [ "$n" = "ok" ] || { _relman_err "sections [files] and [install-map] missing or out of order"; return 1; }
  v=$(relman_get "$m" version)
  case "$v" in ''|*[!0-9.]*|.*|*.|*..*) _relman_err "bad version '$v'"; return 1 ;; esac
  case "$v" in *.*.*) ;; *) _relman_err "bad version '$v'"; return 1 ;; esac
  [ "$(relman_get "$m" tag)" = "v$v" ] || { _relman_err "tag does not equal v$v"; return 1; }
  if [ -n "$want" ] && [ "$v" != "$want" ]; then _relman_err "manifest version $v != requested $want"; return 1; fi
  k=$(relman_get "$m" terms_version)
  case "$k" in ''|*[!0-9]*) _relman_err "bad terms_version '$k'"; return 1 ;; esac
  k=$(relman_get "$m" signers_sha256)
  case "$k" in *[!0-9a-f]*) _relman_err "bad signers_sha256"; return 1 ;; esac
  [ "${#k}" = "64" ] || { _relman_err "bad signers_sha256"; return 1; }
  n=$(relman_get "$m" files)
  cnt=$(relman_section "$m" files | grep -c .)
  [ "$n" = "$cnt" ] || { _relman_err "files=$n but [files] has $cnt lines"; return 1; }
  return 0
}

# relman_have_sshsig -> 0 when `ssh-keygen -Y` exists (OpenSSH >= 8.2)
# Classifies by the probe's refusal text. A misclassification in the "supported" direction is
# still safe: the real verify then fails and the caller halts on `signature`, never proceeds.
relman_have_sshsig() {
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  local out
  out=$(ssh-keygen -Y verify </dev/null 2>&1)
  case "$out" in
    *"illegal option"*|*"unknown option"*|*"invalid option"*|*"unrecognized option"*) return 1 ;;
  esac
  return 0
}

# relman_fingerprints <allowed_signers> -> one "SHA256:... valid-before=YYYYMMDD" line per key
# The signers line is `principal options keytype key`; options are comma-separated with no spaces
# (MEASURED: spaces make ssh-keygen reject the line), so the key is always the last two fields.
relman_fingerprints() {
  local signers="$1" line kt key opts vb tmp fp
  [ -s "$signers" ] || return 1
  tmp=$(mktemp 2>/dev/null) || tmp="${TMPDIR:-/tmp}/relman.$$"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -f; set -- $line; set +f
    [ "$#" -ge 3 ] || continue
    eval "kt=\${$(($# - 1))}"; eval "key=\${$#}"
    opts=""; [ "$#" -ge 4 ] && opts="$2"
    vb=$(printf '%s' "$opts" | sed -n 's/.*valid-before="\{0,1\}\([0-9]*\).*/\1/p')
    printf '%s %s\n' "$kt" "$key" > "$tmp"
    fp=$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}')
    printf '%s valid-before=%s\n' "${fp:-unreadable-key}" "${vb:-none}"
  done < "$signers"
  rm -f "$tmp" 2>/dev/null
}

# relman_verify_sig <manifest> <sig> <allowed_signers>
# rc 0 = valid signature by a key in <allowed_signers>, inside its validity window, right namespace.
relman_verify_sig() {
  local m="$1" s="$2" signers="$3"
  [ -s "$m" ] && [ -s "$s" ] && [ -s "$signers" ] || { _relman_err "signature inputs missing"; return 1; }
  ssh-keygen -Y verify -f "$signers" -I "$RELMAN_PRINCIPAL" -n "$RELMAN_NS" -s "$s" < "$m" >/dev/null 2>&1
}

# relman_verify_tree <manifest> <tree>
# The file set of <tree> (minus RELEASE-MANIFEST*) must EQUAL [files] exactly — every hash and
# every path, no extra file anywhere, no missing one. Compared as whole text, so one byte of
# difference, one unlisted file or one absent file all fail the same way.
relman_verify_tree() {
  local m="$1" tree="$2" want got
  want=$(relman_section "$m" files) || return 1
  got=$(relman_tree_files "$tree" | relman_sha256_stdin_list "$tree") || return 1
  if [ "$want" != "$got" ]; then
    _relman_err "tree does not match [files]: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") 2>/dev/null | grep '^[<>]' | head -3 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

# relman_check_map <manifest> <tree>
# Install-map safety: every line `src -> dest  tag`, dest relative with no `..` segment and a first
# segment in {hooks, skills, docs, agents}, tag in {core, extended, agents}, src listed in [files]
# and present in <tree>; and signers_sha256 equals the hash of the tree's allowed_signers.
relman_check_map() {
  local m="$1" tree="$2" out line
  # ONE awk pass over the manifest (a per-line grep cost ~70 ms a line on MSYS — seconds inside a
  # session-start budget). It prints "SRC <path>" per valid line, or one error line and stops.
  out=$(awk '
    $0 == "[files]"       { sec = "f"; next }
    $0 == "[install-map]" { sec = "m"; next }
    /^\[[a-z-]+\]$/       { sec = ""; next }
    sec == "f" && length  { p = $0; sub(/^[0-9a-f]+  /, "", p); files[p] = 1; next }
    sec == "m" && length  { maps[++n] = $0 }
    END {
      if (n == 0) { print "ERR empty install map"; exit }
      for (i = 1; i <= n; i++) {
        k = split(maps[i], a, " ")
        if (k != 4 || a[2] != "->") { print "ERR malformed install-map line: " maps[i]; exit }
        src = a[1]; dest = a[3]; tag = a[4]
        if (tag != "core" && tag != "extended" && tag != "agents") { print "ERR bad tag " tag; exit }
        if (dest ~ /^\// || index(dest, "\\") || index(dest, ":") || dest ~ /(^|\/)\.\.?(\/|$)/ || index(dest, "//")) {
          print "ERR unsafe destination: " dest; exit
        }
        seg = dest; sub(/\/.*/, "", seg)
        if (seg != "hooks" && seg != "skills" && seg != "docs" && seg != "agents") { print "ERR destination outside the allowed roots: " dest; exit }
        if (seg == dest) { print "ERR destination is a bare root: " dest; exit }
        if (!(src in files)) { print "ERR install-map source not in [files]: " src; exit }
        print "SRC " src
      }
    }' "$m" 2>/dev/null)
  [ -n "$out" ] || { _relman_err "install map unreadable"; return 1; }
  while IFS= read -r line; do
    case "$line" in
      "SRC "*) [ -f "$tree/${line#SRC }" ] || { _relman_err "install-map source missing from tree: ${line#SRC }"; return 1; } ;;
      "ERR "*) _relman_err "${line#ERR }"; return 1 ;;
    esac
  done <<RELMANMAP
$out
RELMANMAP
  [ "$(relman_get "$m" signers_sha256)" = "$(relman_sha256 "$tree/bundle/release/allowed_signers")" ] \
    || { _relman_err "signers_sha256 does not match bundle/release/allowed_signers"; return 1; }
  return 0
}

# relman_map_for_mode <manifest> <full|core-only> -> "src dest" pairs the given install mode takes
relman_map_for_mode() {
  local mode="$2"
  relman_section "$1" install-map | awk -v mode="$mode" '
    NF == 4 && $2 == "->" { if (mode == "core-only" && $4 != "core") next; print $1 " " $3 }'
}
