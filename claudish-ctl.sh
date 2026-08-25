#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claudish-ctl.sh — runtime state switcher + dashboard backing /claudish.
#
# The hooks re-read flag files on every message, so switches take effect mid-
# session where the frozen env cannot:
#   off-file   (default ~/.claude/claudish-off)    exists -> rewrites paused
#   mode-file  (default ~/.claude/claudish-mode)   append|replace -> display mode
#   style-file (default ~/.claude/claudish-style)  tldr|5y -> rewrite style (display hook)
#   lang-file  (default ~/.claude/claudish-lang)   rewrite language (see lang.sh)
#   model-file (default ~/.claude/claudish-model)  model (see providers.sh)
#   keep-file  (default ~/.claude/claudish-keep-terms) one protected term per
#              line; a line starting with # (leading whitespace allowed) is a
#              comment, and blank lines are skipped, so the file can document
#              itself. A term therefore cannot start with #.
# rewrite.sh reads mode/style; lang/model/off are shared with rewrite-md.sh.
# They PERSIST across sessions (like the off-file) until cleared — the dashboard
# flags any that are in force so that persistence is never a silent surprise,
# and the SessionStart hook (session-notice.sh) announces them on a new session.
#
# Usage: claudish-ctl.sh [status|on|off|append|replace|style [name]|language [name]|model [name]|keep [term]|keep import <file>|drift|last|cycle|reset]
#   status        (default) print the dashboard: every setting, its value, and
#                 WHERE that value comes from (env / a /claudish flag / default)
#   on            resume rewrites (keeps the current mode)
#   off           pause rewrites (originals only; also pauses the Markdown hook)
#   append        original + rewrite appended (and turn on)
#   replace       rewrite only (and turn on)
#   style X       rewrite style: "tldr" (short summary) or "5y" (explain like
#                 I'm five); no name / "default" resets to the plain rewrite.
#                 A custom CLAUDISH_PROMPT_FILE always wins over styles
#   language X    rewrite into language X, e.g. "language Brazilian Portuguese"
#                 (no name / "default" resets to the session/settings language)
#   model X       use model X for whatever provider is configured (no name /
#                 "default" resets to the provider default; also turns on)
#   keep X        protect term X from being renamed by the rewrite; several at
#                 once with commas. "keep list" shows the list and where each
#                 term comes from, "keep remove X" drops one, "keep clear"
#                 empties it, "keep import FILE" merges in a file of terms
#                 (one per line, # comments and blank lines allowed; see
#                 keep-terms.example). Adding never rewrites the file, only
#                 appends, so comments already in it survive. The words list,
#                 remove, clear and import cannot be added this way; put them
#                 in CLAUDISH_KEEP_TERMS or the file instead
#   last          print the ORIGINAL text of the last assistant message
#   cycle         off -> append -> replace -> off
#   reset         clear ALL overrides (off/mode/style/language/model/keep) -> env
#
# Mutating commands print a one-line confirmation:
#   "claudish: <off|append|replace> (style: …, language: …, model: …)".
# Writes fail loudly (exit 1) if a flag file cannot be created/removed.
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

OFF_FILE="${CLAUDISH_OFF_FILE:-$HOME/.claude/claudish-off}"
MODE_FILE="${CLAUDISH_MODE_FILE:-$HOME/.claude/claudish-mode}"
STYLE_FILE="${CLAUDISH_STYLE_FILE:-$HOME/.claude/claudish-style}"
LANG_FILE="${CLAUDISH_LANG_FILE:-$HOME/.claude/claudish-lang}"
MODEL_FILE="${CLAUDISH_MODEL_FILE:-$HOME/.claude/claudish-model}"
KEEP_FILE="${CLAUDISH_KEEP_TERMS_FILE:-$HOME/.claude/claudish-keep-terms}"
KEEP_NL='
'

# The /claudish slash command hands the user's whole argument string to us as a
# QUOTED here-doc on stdin (invoked as `claudish-ctl.sh --stdin-args`). A quoted
# here-doc delimiter makes the shell copy the body verbatim, so NOTHING typed
# after /claudish is re-parsed as shell syntax: command substitution ($(...),
# backticks), parameter expansion ($VAR), quotes, and operators (; | && *) all
# arrive as literal text and are never evaluated. Quoting "$ARGUMENTS" into the
# command line could not do this — Claude Code substitutes $ARGUMENTS textually
# before the shell runs, so $(...) and $VAR stayed live inside the quotes.
# We read that one line and split it into words ourselves, with globbing off so
# a literal "*" is not expanded, to keep multi-word args like
# `language Brazilian Portuguese` working. A direct call from a terminal passes
# normal positional args (no --stdin-args) and is left untouched; an empty
# here-doc yields zero positionals, so bare `/claudish` falls through to status.
if [ "${1:-}" = "--stdin-args" ]; then
  _argline=""
  IFS= read -r _argline || true
  set -f
  # shellcheck disable=SC2086
  set -- $_argline
  set +f
fi

fail() { printf 'claudish-ctl: %s\n' "$1" >&2; exit 1; }

# Borrow the hooks' own resolvers so the dashboard can't drift from them:
# providers.sh sets PROVIDER + the provider-default MODEL, lang.sh resolves the
# effective language. providers.sh is sourced with its model-file override
# NEUTRALISED (pointed at a path that does not exist) so $MODEL is the clean
# PROVIDER default — otherwise a `model default` that removes the file this same
# run would read the file's value back through $MODEL. current_model reads the
# real file itself, fresh. Both sources are fail-soft.
_saved_mf="${CLAUDISH_MODEL_FILE:-}"
export CLAUDISH_MODEL_FILE="$SELF_DIR/.claudish-no-model-file"
MODEL=""; PROVIDER=""
dbg() { :; }
. "$SELF_DIR/providers.sh" 2>/dev/null || true
if [ -n "$_saved_mf" ]; then export CLAUDISH_MODEL_FILE="$_saved_mf"; else unset CLAUDISH_MODEL_FILE; fi
claudish_language() { :; }
. "$SELF_DIR/lang.sh" 2>/dev/null || true
# Protected-vocabulary resolver. Stub first, then source; KEEP_OK records whether
# the real file was found, so a `keep` subcommand fails loudly instead of doing
# nothing at all.
claudish_keep_terms() { :; }
claudish_keep_file_terms() { :; }
claudish_keep_env_terms() { :; }
_claudish_keep_norm() { :; }
claudish_keep_strip_comments() { :; }
KEEP_OK=0
if . "$SELF_DIR/keep-terms.sh" 2>/dev/null; then KEEP_OK=1; fi

# ---- effective values (each reads its flag file FRESH) --------------------
current_model() {
  m=""
  [ -f "$MODEL_FILE" ] && m="$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
  [ -n "$m" ] && { printf '%s' "$m"; return; }
  printf '%s' "${MODEL:-${CLAUDISH_MODEL:-unknown}}"
}
current_lang() {
  l="$(claudish_language "$PWD" 2>/dev/null)"
  [ -n "$l" ] && printf '%s' "$l" || printf 'auto'
}
current_mode() {
  m=""
  [ -f "$MODE_FILE" ] && m="$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$m" in append|replace) printf '%s' "$m" ;; *) printf '%s' "${CLAUDISH_MODE:-append}" ;; esac
}
current_style() {
  s=""
  [ -f "$STYLE_FILE" ] && s="$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')"
  case "$s" in tldr|5y) printf '%s' "$s"; return ;; esac
  case "${CLAUDISH_STYLE:-}" in tldr|5y) printf '%s' "$CLAUDISH_STYLE" ;; *) printf 'default' ;; esac
}
keep_value() {
  n="$(claudish_keep_terms | grep -c '[^[:space:]]' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$n" in
    0) printf 'none' ;;
    1) printf '1 term' ;;
    *) printf '%s terms' "$n" ;;
  esac
}
state() { [ -f "$OFF_FILE" ] && printf 'off' || current_mode; }

turn_on() { rm -f "$OFF_FILE" 2>/dev/null || fail "cannot remove $OFF_FILE"; }
set_mode() { { printf '%s\n' "$1" > "$MODE_FILE"; } 2>/dev/null || fail "cannot write $MODE_FILE"; turn_on; }

# ---- provenance: where does each effective value come from? ---------------
# "flag" is the one worth flagging — a /claudish file that persists across
# sessions. The dashboard turns these into a ⚠ line.
mode_source() {
  if [ -f "$MODE_FILE" ]; then
    case "$(cat "$MODE_FILE" 2>/dev/null | tr -d '[:space:]')" in append|replace) echo flag; return ;; esac
  fi
  [ -n "${CLAUDISH_MODE+x}" ] && { echo env; return; }
  echo default
}
style_source() {
  if [ -f "$STYLE_FILE" ]; then
    case "$(cat "$STYLE_FILE" 2>/dev/null | tr -d '[:space:]')" in tldr|5y) echo flag; return ;; esac
  fi
  case "${CLAUDISH_STYLE:-}" in tldr|5y) echo env; return ;; esac
  echo default
}
keep_source() {
  [ -n "$(claudish_keep_file_terms)" ] && { echo flag; return; }
  [ -n "$(claudish_keep_env_terms)" ]  && { echo env; return; }
  echo default
}
lang_source() {
  [ -f "$LANG_FILE" ] && [ -n "$(head -c 64 "$LANG_FILE" 2>/dev/null | tr -d '[:space:]')" ] && { echo flag; return; }
  [ -n "${CLAUDISH_LANG+x}" ] && { echo env; return; }
  [ -n "$(claudish_language "$PWD" 2>/dev/null)" ] && { echo settings; return; }
  echo default
}
model_source() {
  [ -f "$MODEL_FILE" ] && [ -n "$(head -c 128 "$MODEL_FILE" 2>/dev/null | tr -d '[:space:]')" ] && { echo flag; return; }
  [ -n "${CLAUDISH_MODEL+x}" ] && { echo env; return; }
  echo provider
}

WARN=0  # set when any value is a persisting /claudish override

status_label() {
  case "$(state)" in
    off)     _mean="originals only" ;;
    replace) _mean="rewrite only" ;;
    *)       _mean="original + rewrite" ;;
  esac
  if [ -f "$OFF_FILE" ]; then
    WARN=1; printf '⚠ /claudish off — %s; persists across sessions' "$_mean"; return
  fi
  case "$(mode_source)" in
    flag) WARN=1; printf '⚠ /claudish — %s; beats env, persists across sessions' "$_mean" ;;
    env)  printf 'env CLAUDISH_MODE — %s' "$_mean" ;;
    *)    printf 'default — %s' "$_mean" ;;
  esac
}
style_label() {
  case "$(style_source)" in
    flag) WARN=1; printf '⚠ /claudish — beats env CLAUDISH_STYLE, persists across sessions' ;;
    env)  printf 'env CLAUDISH_STYLE' ;;
    *)    printf 'default — plain-language rewrite' ;;
  esac
}
keep_label() {
  case "$(keep_source)" in
    flag) WARN=1; printf '⚠ /claudish - adds to env CLAUDISH_KEEP_TERMS, persists across sessions' ;;
    env)  printf 'env CLAUDISH_KEEP_TERMS' ;;
    *)    printf 'default - no protected terms' ;;
  esac
}
language_label() {
  case "$(lang_source)" in
    flag)     WARN=1; printf '⚠ /claudish — beats env & settings, persists across sessions' ;;
    env)      printf 'env CLAUDISH_LANG' ;;
    settings) printf 'your .claude/settings.json language' ;;
    *)        printf 'default — keeps each message'\''s own language' ;;
  esac
}
model_label() {
  case "$(model_source)" in
    flag)     WARN=1; printf '⚠ /claudish — beats env CLAUDISH_MODEL, persists across sessions' ;;
    env)      printf 'env CLAUDISH_MODEL' ;;
    *)        printf '%s provider default' "${PROVIDER:-ollama}" ;;
  esac
}
provider_label() { [ -n "${CLAUDISH_PROVIDER+x}" ] && printf 'env CLAUDISH_PROVIDER' || printf 'default'; }

dashboard() {
  # Compute labels first (they set WARN as a side effect).
  _sl="$(status_label)"; _yl="$(style_label)"; _kl="$(keep_label)"; _ll="$(language_label)"; _ml="$(model_label)"; _pl="$(provider_label)"
  printf '\n  claudish · plain-language rewrite of each assistant message\n\n'
  printf '  %-9s %-16s · %s\n' 'status'   "$(state)"            "$_sl"
  printf '  %-9s %-16s · %s\n' 'style'    "$(current_style)"    "$_yl"
  printf '  %-9s %-16s · %s\n' 'keep'     "$(keep_value)"       "$_kl"
  printf '  %-9s %-16s · %s\n' 'language' "$(current_lang)"     "$_ll"
  printf '  %-9s %-16s · %s\n' 'model'    "$(current_model)"    "$_ml"
  printf '  %-9s %-16s · %s\n' 'provider' "${PROVIDER:-ollama}" "$_pl"
  printf '\n  change   /claudish on · off · append · replace · style <tldr|5y> · language <name> · model <name> · keep <term>\n'
  printf '  other    /claudish keep list · drift · last · cycle · reset (clear all overrides) · status\n'
  if [ "$WARN" = "1" ]; then
    printf '\n  ⚠ lines above are /claudish overrides in ~/.claude/claudish-* that persist\n'
    printf '    across sessions. Reset one with its `default` form, or all with /claudish reset.\n'
  fi
  printf '\n'
}

# ---- keep terms -----------------------------------------------------------
# The list the rewrite must never rename. Terms are exact strings: no globbing,
# no regular expressions, no shell patterns anywhere in here.
keep_write() {  # $1 = newline separated clean terms; empty removes the file
  if [ -n "$1" ]; then
    _kw_tmp="$(mktemp "${KEEP_FILE}.XXXXXX" 2>/dev/null)" || fail "cannot create a temp file next to $KEEP_FILE"
    { printf '%s\n' "$1" > "$_kw_tmp"; } 2>/dev/null || { rm -f "$_kw_tmp" 2>/dev/null; fail "cannot write $KEEP_FILE"; }
    mv -f "$_kw_tmp" "$KEEP_FILE" 2>/dev/null || { rm -f "$_kw_tmp" 2>/dev/null; fail "cannot write $KEEP_FILE"; }
  else
    rm -f "$KEEP_FILE" 2>/dev/null || fail "cannot remove $KEEP_FILE"
  fi
}

# Position-preserving normalized copy of the raw keep FILE: every line goes
# through the SAME control-character strip, edge trim and 64 character cut
# the read path applies (_claudish_keep_norm's clean), so an interior tab or
# an over-length line still compares equal to its cleaned form. A comment or
# blank line comes back BLANK (never dropped), so line numbers still map
# 1:1 onto the raw file and a comment can never accidentally equal a term.
keep_raw_normalized() {
  [ -f "$KEEP_FILE" ] || return 0
  sed -e 's/^[[:space:]]*#.*$//' "$KEEP_FILE" \
    | sed -e 's/[[:cntrl:]]//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | LC_ALL=C cut -c "1-${CLAUDISH_KEEP_MAX_LEN:-64}"
}

# Append clean terms to the keep FILE, keeping whatever is already in it
# (comments included). $1 = newline separated clean terms. Sets KEEP_ADDED to
# the terms actually written and KEEP_DUP to how many were already there.
# Membership is an exact whole-line `case` test on a newline-wrapped string: no
# subprocess, no pipe, and never a pattern match against the term itself.
keep_append() {
  KEEP_ADDED=""; KEEP_DUP=0
  # Dedup against every RAW term line, not the capped/deduped read: a term
  # sitting past the 200 cap is invisible to claudish_keep_file_terms, and
  # deduping against that capped view let a repeated add past the cap write
  # a second copy of the same line every time.
  known="${KEEP_NL}$(keep_raw_normalized | grep -v '^$')${KEEP_NL}"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$known" in
      *"${KEEP_NL}${t}${KEEP_NL}"*) KEEP_DUP=$((KEEP_DUP + 1)); continue ;;
    esac
    KEEP_ADDED="${KEEP_ADDED}${t}${KEEP_NL}"
    known="${known}${t}${KEEP_NL}"
  done <<KEEP_APPEND_EOF
$1
KEEP_APPEND_EOF
  [ -n "$KEEP_ADDED" ] || return 0
  # A leading newline only when the file has content that does NOT already
  # end in one, so a repeated add never grows a blank line between entries.
  if [ -s "$KEEP_FILE" ] && [ "$(tail -c1 "$KEEP_FILE" 2>/dev/null | wc -l | tr -d ' ')" != "1" ]; then
    { printf '\n%s' "$KEEP_ADDED" >> "$KEEP_FILE"; } 2>/dev/null || fail "cannot write $KEEP_FILE"
  else
    { printf '%s' "$KEEP_ADDED" >> "$KEEP_FILE"; } 2>/dev/null || fail "cannot write $KEEP_FILE"
  fi
  return 0
}

# Warn once when the file now holds as many terms as the read path will use.
# When KEEP_ADDED (set by keep_append) names the terms just written, name
# whichever of those specifically fell past the cap, so the user learns THEIR
# term was the one dropped rather than a generic notice. Sets KEEP_CAP_DROPPED
# (possibly empty) so a caller can keep its own "added" report honest instead
# of claiming a term was added when it was actually dropped by the cap.
keep_cap_note() {
  KEEP_CAP_DROPPED=""
  c="$(claudish_keep_file_terms | grep -c '[^[:space:]]')"
  [ "$c" -ge "${CLAUDISH_KEEP_MAX_TERMS:-200}" ] || return 0
  if [ -n "${KEEP_ADDED:-}" ]; then
    _cftmp="$(mktemp "${TMPDIR:-/tmp}/claudish-capped.XXXXXX" 2>/dev/null)"
    if [ -n "$_cftmp" ]; then
      claudish_keep_file_terms > "$_cftmp" 2>/dev/null
      KEEP_CAP_DROPPED="$(printf '%s\n' "$KEEP_ADDED" | grep -vFxf "$_cftmp" 2>/dev/null)"
      rm -f "$_cftmp" 2>/dev/null
    fi
  fi
  if [ -n "$KEEP_CAP_DROPPED" ]; then
    printf 'claudish-ctl: the keep list is full at %s terms; not added: %s\n' \
      "${CLAUDISH_KEEP_MAX_TERMS:-200}" "$(printf '%s' "$KEEP_CAP_DROPPED" | tr '\n' ',' | sed 's/,/, /g; s/, $//')" >&2
  else
    printf 'claudish-ctl: the keep list is full at %s terms; anything past that is ignored\n' \
      "${CLAUDISH_KEEP_MAX_TERMS:-200}" >&2
  fi
  return 0
}

# $1 = KEEP_ADDED-shaped newline list, $2 = KEEP_CAP_DROPPED-shaped newline
# list (may be empty). Prints $1 with any lines also present in $2 removed,
# so a caller's "added" report never claims a term the cap note just said
# was dropped.
keep_added_minus_dropped() {
  if [ -z "${2:-}" ]; then
    printf '%s' "$1"
    return 0
  fi
  _dtmp="$(mktemp "${TMPDIR:-/tmp}/claudish-dropped.XXXXXX" 2>/dev/null)"
  if [ -z "$_dtmp" ]; then
    printf '%s' "$1"
    return 0
  fi
  printf '%s\n' "$2" > "$_dtmp"
  printf '%s\n' "$1" | grep -vFxf "$_dtmp" 2>/dev/null
  rm -f "$_dtmp" 2>/dev/null
}

keep_add() {  # $1 = the whole argument string, comma separated
  new="$(_claudish_keep_norm "$1" "")"
  [ -n "$new" ] || fail "nothing to add (use /claudish keep <term>[, <term>...])"
  keep_append "$new"
  keep_cap_note
  reported="$(keep_added_minus_dropped "$KEEP_ADDED" "$KEEP_CAP_DROPPED")"
  keep_summary added "$reported"
}

keep_remove() {  # $1 = one term, matched as a whole line, commas included
  term="$(_claudish_keep_norm "" "$1")"
  [ -n "$term" ] || fail "usage: /claudish keep remove <term>"
  # A term cannot start with "#" (it would be a comment, never a term), so
  # refuse up front rather than let one match and delete a real comment.
  case "$term" in '#'*) fail "\"$term\" is not in the keep list (see /claudish keep list)" ;; esac
  [ -f "$KEEP_FILE" ] || fail "\"$term\" is not in the keep list (see /claudish keep list)"
  # Non-blank lines only: a trailing blank line (the README explicitly
  # invites hand-editing the file) must not count as "real content still
  # there" and false-trigger the empty-result guard below on a legitimate
  # full clear.
  total="$(grep -c '[^[:space:]]' "$KEEP_FILE")"
  case "$total" in ''|*[!0-9]*) fail "cannot rewrite $KEEP_FILE" ;; esac
  # Match against the read path's own normalization (control characters
  # stripped, edges trimmed, cut to 64), not just a whitespace trim, so a
  # term the sanitizer reshaped (an interior tab, an over-length line)
  # still matches. grep -nxF on the normalized copy: whole-line, fixed
  # string, never a pattern, never awk (no backslash expansion, no numeric
  # look-alike coercion).
  lines="$(keep_raw_normalized | grep -nxF -- "$term" | cut -d: -f1)"
  [ -n "$lines" ] || fail "\"$term\" is not in the keep list (see /claudish keep list)"
  matched="$(printf '%s\n' "$lines" | grep -c '[^[:space:]]')"
  # Delete by line number via a two-file awk join (numbers file first,
  # populates an array; KEEP_FILE second, prints anything not in it), which
  # has no command-count ceiling the way "1d;2d;3d;...;841d" does under BSD
  # sed (BSD sed refuses more than 840 -e commands, and past that point the
  # previous implementation used to fail silently and hand keep_write an
  # empty string, which took the "clear the whole file" branch).
  _numf="$(mktemp "${TMPDIR:-/tmp}/claudish-lines.XXXXXX" 2>/dev/null)" || fail "cannot create a temp file"
  printf '%s\n' "$lines" > "$_numf"
  out="$(awk 'FNR==NR{d[$1];next} !(FNR in d)' "$_numf" "$KEEP_FILE")"
  _rc=$?
  rm -f "$_numf" 2>/dev/null
  [ "$_rc" -eq 0 ] || fail "cannot rewrite $KEEP_FILE"
  # An empty result is only correct if EVERY line in the file matched. Any
  # other empty result is a bug (a filter that silently ate the file), never
  # a clear: refuse to hand it to keep_write, which would otherwise take the
  # rm-the-whole-file branch and look like a successful, quiet removal.
  if [ -z "$out" ] && [ "$total" -gt "$matched" ]; then
    fail "cannot rewrite $KEEP_FILE: removal produced an unexpectedly empty result"
  fi
  keep_write "$out"
  keep_summary removed "$term"
}

keep_import() {  # $1 = path to a file of terms, one per line, # comments allowed
  p="$1"
  [ -n "$p" ] || fail "usage: /claudish keep import <file>"
  # The argument arrives as literal text, so a typed "~" is not expanded yet.
  case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
  [ -f "$p" ] && [ -r "$p" ] || fail "cannot read $p"
  new="$(_claudish_keep_norm "" "$(claudish_keep_strip_comments "$p")")"
  [ -n "$new" ] || fail "no terms in $p (blank lines and lines starting with # are skipped)"
  keep_append "$new"
  keep_cap_note
  reported="$(keep_added_minus_dropped "$KEEP_ADDED" "$KEEP_CAP_DROPPED")"
  added="$(printf '%s\n' "$reported" | grep -c '[^[:space:]]')"
  case "$added" in ''|*[!0-9]*) added=0 ;; esac
  printf 'claudish: imported %s: %s added, %s already there\n' "$p" "$added" "$KEEP_DUP"
  keep_summary
}

keep_list() {
  t="$(claudish_keep_terms)"
  if [ -z "$t" ]; then
    printf 'claudish keep terms: none. Add one with /claudish keep <term>.\n'
    printf 'file: %s\n' "$KEEP_FILE"
    return 0
  fi
  e="$(claudish_keep_env_terms)"
  n="$(printf '%s\n' "$t" | grep -c '[^[:space:]]')"
  out="claudish keep terms ($n):"$'\n'
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    case "$KEEP_NL$e$KEEP_NL" in
      *"$KEEP_NL$term$KEEP_NL"*) out="${out}  $(printf '%-24s' "$term") env CLAUDISH_KEEP_TERMS"$'\n' ;;
      *)                         out="${out}  $(printf '%-24s' "$term") /claudish keep"$'\n' ;;
    esac
  done <<KEEPLIST
$t
KEEPLIST
  out="${out}file: $KEEP_FILE"$'\n'
  if [ "$n" -ge "${CLAUDISH_KEEP_MAX_TERMS:-200}" ]; then
    out="${out}note: the list is full at ${CLAUDISH_KEEP_MAX_TERMS:-200} terms; anything past that is ignored."$'\n'
  fi
  printf '%s' "$out"
  return 0
}

keep_summary() {  # $1 optional label ("added"/"removed"), $2 the terms that label applies to
  t="$(claudish_keep_terms)"
  n="$(printf '%s\n' "$t" | grep -c '[^[:space:]]' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -eq 0 ]; then
    printf 'claudish: no keep terms (add one with /claudish keep <term>)\n'
    return 0
  fi
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    printf 'claudish: %s keep term(s); %s: %s\n' "$n" "$1" "$(printf '%s' "$2" | tr '\n' ',' | sed 's/,/, /g; s/, $//')"
  else
    printf 'claudish: %s keep term(s): %s\n' "$n" "$(printf '%s' "$t" | tr '\n' ',' | sed 's/,/, /g')"
  fi
}

cmd="${1:-status}"

# Read-only views print the dashboard and exit; `last` prints a transcript.
case "$cmd" in
  status|menu|help|dashboard|"") dashboard; exit 0 ;;
  last)
    # The rewrite is display-only: transcripts always keep Claude's original
    # text. Transcripts live under ~/.claude/projects/<encoded cwd>/, so scope
    # the search to the CURRENT project first (the command runs in the session's
    # cwd) and take the most recently touched transcript there — with several
    # sessions open on the SAME project that is still the best available guess.
    # Fall back to all projects when the encoded directory does not exist.
    proj="$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
    tp="$(ls -t "$HOME/.claude/projects/$proj"/*.jsonl 2>/dev/null | head -n1)"
    [ -n "$tp" ] || tp="$(ls -t "$HOME/.claude/projects"/*/*.jsonl 2>/dev/null | head -n1)"
    [ -n "$tp" ] || { printf 'claudish-ctl: no session transcript found\n' >&2; exit 1; }
    jq -rs '
      [ .[]
        | select(.type=="assistant" and .isSidechain!=true)
        | [.message.content[]? | select(.type=="text") | .text]
        | join("\n\n")
        | select(length>0) ]
      | last // "claudish-ctl: no assistant message in the transcript yet"
    ' "$tp" 2>/dev/null || { printf 'claudish-ctl: could not parse %s\n' "$tp" >&2; exit 1; }
    exit 0
    ;;
  drift)
    # Which protected-looking words did the last rewrite drop? rewrite.sh stores
    # the last original and the last rewrite side by side, so this compares two
    # halves of the SAME message instead of guessing at a transcript the way
    # `last` has to. It NEVER changes the keep list; see the filter below for
    # why it never prints a ready-to-run command either.
    [ "$KEEP_OK" = "1" ] || fail "keep-terms.sh not found next to claudish-ctl.sh"
    LD="${CLAUDISH_LOCAL_DIR:-$HOME/.claude/claudish-local}"
    SID="${CLAUDE_CODE_SESSION_ID:-}"
    case "$SID" in
      ""|nosession) LO="$LD/last-original"; LR="$LD/last-rewrite" ;;
      *)             LO="$LD/last-original.$SID"; LR="$LD/last-rewrite.$SID" ;;
    esac
    if [ ! -f "$LO" ] || [ ! -f "$LR" ]; then
      # A future disagreement between the write side (rewrite.sh keys off
      # the hook payload's own .session_id) and the read side (this keys off
      # CLAUDE_CODE_SESSION_ID) would otherwise dead-end here with a
      # misleading "let one message go through" while the data sits on disk
      # under a different suffix. Fall back to the newest last-original.*
      # that has a matching last-rewrite.* sibling before giving up.
      _newest="$(ls -t "$LD"/last-original.* 2>/dev/null | head -n1)"
      if [ -n "$_newest" ]; then
        _suffix="$(basename "$_newest")"; _suffix="${_suffix#last-original.}"
        _cand_lr="$LD/last-rewrite.$_suffix"
        [ -f "$_cand_lr" ] && { LO="$_newest"; LR="$_cand_lr"; }
      fi
    fi
    if [ ! -f "$LO" ] || [ ! -f "$LR" ]; then
      printf 'claudish-ctl: no stored rewrite yet. Let one assistant message go through with the rewrite on, then run /claudish drift (CLAUDISH_DRIFT=0 turns the storing off).\n' >&2
      exit 1
    fi
    # Fenced code blocks are dropped by the tldr preset by design, so counting
    # them would report every identifier in every code block as lost. The
    # fence marker may be indented inside a list item, and an unterminated
    # fence (an odd number of markers) means the file is not reliably split
    # into code/prose at all, so fall back to treating the whole message as
    # prose rather than silently discarding everything after the opener.
    _fences="$(grep -c '^[[:space:]]*```' "$LO" 2>/dev/null)"
    case "$_fences" in *[!0-9]*) _fences=0 ;; esac
    if [ $((_fences % 2)) -eq 0 ] && [ "$_fences" -gt 0 ]; then
      _body="$(awk 'BEGIN{f=0} /^[[:space:]]*```/{f=!f; next} f==0{print}' "$LO")"
    else
      _body="$(cat "$LO")"
    fi
    cand="$(printf '%s\n' "$_body" \
      | tr -c 'A-Za-z0-9._-' '\n' \
      | sed -e 's/^[._-]*//' -e 's/[._-]*$//' \
      | sort -u)"
    prot="${KEEP_NL}$(claudish_keep_terms 2>/dev/null)${KEEP_NL}"
    # Every protected term split into its own words too, so a candidate that
    # is only a FRAGMENT of a multi-word term ("delivery" out of "delivery
    # lock") is skipped rather than offered as if it were its own word.
    protwords="${KEEP_NL}$(claudish_keep_terms 2>/dev/null | tr -c 'A-Za-z0-9._-' '\n' | grep -v '^$')${KEEP_NL}"
    hits=""; nhits=0
    # Common English words drift never proposes. Data, not filter logic, so
    # there is no size limit to respect here: a short stop list cannot carry
    # the load of separating "checklist" (worth protecting) from "green" (not),
    # so this is deliberately large, not a hand-picked handful.
    _drift_common="$(cat <<'DRIFT_STOP_EOF'
a
about
above
across
actually
advise
advised
advises
affected
after
again
against
ago
ahead
all
almost
alone
along
already
also
although
always
am
among
an
and
another
any
anyone
anything
anywhere
are
area
around
as
ask
asked
asking
at
away
back
bad
barely
basically
be
became
because
become
becomes
been
before
began
begin
beginning
behind
being
believe
below
best
better
between
beyond
big
bit
body
both
bring
brought
build
building
built
but
buy
by
call
called
calling
came
can
cannot
car
case
cases
cause
certain
certainly
change
changed
child
children
city
clearly
close
code
come
comes
coming
commit
commits
committed
committing
common
company
complete
completely
consider
considered
constantly
continue
continued
continuously
contract
contracts
correct
correctly
could
couldn
course
create
created
current
currently
day
days
decide
decided
deposit
deposits
detail
details
did
didn
different
directly
discover
discovered
discovers
discovery
do
document
documented
documents
does
doing
done
door
down
downstream
during
each
early
easily
easy
either
else
end
ended
enough
entire
entirely
especially
even
evening
eventually
ever
every
everyone
everything
exactly
except
experience
explain
explained
explains
fact
far
few
final
finally
find
finding
fine
first
five
follow
followed
following
for
form
found
four
frequently
friend
from
full
fully
further
gave
general
generally
get
gets
getting
girl
give
given
gives
giving
go
goes
going
gone
good
got
great
green
group
grow
had
half
hand
happen
happened
happens
hard
hardly
has
have
having
he
head
hear
heard
help
her
here
herself
high
him
himself
his
hold
home
hour
house
how
however
hundred
idea
if
immediately
implement
implementation
implementations
implemented
implements
important
in
include
included
including
incorrect
indeed
information
initially
inside
instantly
instead
internal
into
is
it
its
itself
just
keep
kept
kind
knew
know
known
large
last
late
later
least
leave
left
less
let
level
life
light
like
likely
line
list
listed
lists
little
live
long
look
looked
looking
looks
lot
love
low
made
main
make
makes
making
man
many
may
maybe
me
mean
means
meant
meet
men
might
mind
minute
miss
moment
money
month
more
morning
most
mostly
mother
move
moved
much
must
my
myself
name
near
nearly
need
needed
never
new
next
nice
night
no
none
nor
not
nothing
now
number
occasionally
of
off
often
ok
old
on
once
one
only
onto
open
opened
opening
or
order
originally
other
others
our
out
outside
over
own
part
particularly
parts
pass
passed
passing
past
people
perhaps
person
place
point
possible
previously
probably
problem
program
promise
promises
properly
provide
provided
public
put
quickly
quite
ran
rarely
rather
reach
read
ready
real
really
reason
recently
regarding
regularly
remember
repeatedly
report
result
return
right
room
run
said
same
saw
say
saying
says
second
see
seem
seemed
seems
seen
sent
set
several
shall
she
should
show
showed
shown
side
similarly
simplified
simplify
simply
since
single
sit
site
situation
six
slowly
small
so
some
someone
something
sometimes
soon
sort
sound
space
speak
speaking
specific
stable
start
started
starting
state
stay
still
stop
story
successfully
such
suddenly
sure
system
take
taken
takes
taking
talk
tell
term
terms
than
that
the
their
theirs
them
themselves
then
there
these
they
thing
things
think
third
this
those
though
thought
three
through
throughout
time
times
to
today
together
told
too
took
top
total
toward
towards
tried
tries
true
truly
try
trying
turn
turned
two
under
understand
until
up
upon
upstream
us
use
used
using
usually
very
want
wanted
wants
was
watch
watched
way
ways
we
well
went
were
what
whatever
when
where
whether
which
while
who
whole
whose
why
will
with
within
without
word
work
worked
working
world
would
wouldn
write
written
wrong
yes
yet
you
your
yours
yourself
DRIFT_STOP_EOF
)"
    # Tier 2: names the intent-44 curation decided in writing degrade the
    # rewrite if protected, because they read as ordinary English or as a
    # generic status word rather than a name (spec, plan, checklist, outcome,
    # roadmap, batch, store, gate, advisor, stage, lock, chain, active,
    # future, completed, INDEX). Listed here explicitly, both cases where a
    # sentence-initial capital is plausible, so drift never recommends
    # protecting a word its own documentation tells the owner not to.
    _drift_tier2="$(cat <<'DRIFT_TIER2_EOF'
spec
Spec
plan
Plan
checklist
Checklist
outcome
Outcome
roadmap
Roadmap
batch
Batch
store
Store
gate
Gate
advisor
Advisor
stage
Stage
lock
Lock
chain
Chain
active
Active
future
Future
completed
Completed
INDEX
Index
index
DRIFT_TIER2_EOF
)"
    common="${KEEP_NL}${_drift_common}${KEEP_NL}${_drift_tier2}${KEEP_NL}"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      [ "$nhits" -ge 20 ] && break
      # A small, cheap filter, not a claim of precision: drop a pure number
      # (never a protected term), anything under 4 characters, and a
      # hyphenated token with neither an uppercase letter nor a dot, since
      # de-hyphenating an ordinary compound is exactly what a plain-language
      # rewrite should be free to do.
      case "$tok" in ''|*[!0-9]*) ;; *) continue ;; esac
      [ "${#tok}" -ge 4 ] || continue
      case "$tok" in
        *-*) case "$tok" in ?*[A-Z]*|*.*) ;; *) continue ;; esac ;;
      esac
      # In the common-word / Tier 2 list above? A case-sensitive whole-word
      # test, so this still misses a stop word spelled with capitals the
      # list does not carry; that is a known gap, not a claim otherwise.
      case "$common" in *"${KEEP_NL}${tok}${KEEP_NL}"*) continue ;; esac
      # Already protected, whole term or a word inside a multi-word one?
      case "$prot" in *"${KEEP_NL}${tok}${KEEP_NL}"*) continue ;; esac
      case "$protwords" in *"${KEEP_NL}${tok}${KEEP_NL}"*) continue ;; esac
      # Still in the rewrite? -F so the token is never a pattern, -w so a
      # substring does not count, reading the file directly so nothing can
      # take a SIGPIPE.
      grep -qFw -- "$tok" "$LR" 2>/dev/null && continue
      hits="${hits}${hits:+, }$tok"
      nhits=$((nhits + 1))
    done <<DRIFT_EOF
$cand
DRIFT_EOF
    if [ -z "$hits" ]; then
      printf '\n  claudish drift: no candidates.\n\n'
      exit 0
    fi
    # A plain list, never a paste-ready command: the point is one deliberate
    # /claudish keep <term> the owner types after judging a candidate is
    # real vocabulary, not a multi-term line he runs without reading it.
    printf '\n  claudish drift: in the last original, not in the last rewrite\n\n'
    printf '  %s\n\n' "$hits"
    printf '  This is a hint, not a verdict: expect some ordinary words in the list\n'
    printf '  alongside real ones. Add only the ones that are real names, with\n'
    printf '  /claudish keep <term>.\n\n'
    exit 0
    ;;
esac

# Mutating commands.
case "$cmd" in
  on)      turn_on ;;
  off)     { : > "$OFF_FILE"; } 2>/dev/null || fail "cannot create $OFF_FILE" ;;
  append)  set_mode append ;;
  replace) set_mode replace ;;
  style)
    s="$(printf '%s' "${2:-}" | tr -d '[:space:]')"
    case "$s" in
      ''|default|Default) rm -f "$STYLE_FILE" 2>/dev/null || fail "cannot remove $STYLE_FILE" ;;
      tldr|5y)            { printf '%s\n' "$s" > "$STYLE_FILE"; } 2>/dev/null || fail "cannot write $STYLE_FILE" ;;
      *) printf 'claudish-ctl: unknown style "%s" (use tldr|5y|default)\n' "$s" >&2; exit 2 ;;
    esac
    turn_on
    ;;
  language)
    # Take the WHOLE remaining argument so multi-word names survive (e.g.
    # "Brazilian Portuguese"). lang.sh (via _claudish_lang_clean) does the
    # authoritative normalisation on read, so multibyte names like "简体中文"
    # survive too; here we only strip newlines and cap the length.
    shift
    lang="$(printf '%s' "$*" | tr -d '\r\n' | head -c 64)"
    case "$lang" in
      ''|default|Default) rm -f "$LANG_FILE" 2>/dev/null || fail "cannot remove $LANG_FILE" ;;
      *) { printf '%s\n' "$lang" > "$LANG_FILE"; } 2>/dev/null || fail "cannot write $LANG_FILE" ;;
    esac
    turn_on
    ;;
  model)
    # Sanitise to the characters model names use (ollama tags, OpenAI/Anthropic ids).
    m="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9:._/-' | head -c 64)"
    case "$m" in
      ''|default|Default) rm -f "$MODEL_FILE" 2>/dev/null || fail "cannot remove $MODEL_FILE" ;;
      *) { printf '%s\n' "$m" > "$MODEL_FILE"; } 2>/dev/null || fail "cannot write $MODEL_FILE" ;;
    esac
    turn_on
    ;;
  keep)
    [ "$KEEP_OK" = "1" ] || fail "keep-terms.sh not found next to claudish-ctl.sh"
    shift
    sub="${1:-list}"
    case "$sub" in
      ''|list) [ "$#" -le 1 ] || { keep_add "$*"; exit 0; }; keep_list; exit 0 ;;
      clear)   [ "$#" -le 1 ] || { keep_add "$*"; exit 0; }; keep_write ""; printf 'claudish: keep list cleared\n'; exit 0 ;;
      remove)  [ "$#" -le 1 ] && fail "usage: /claudish keep remove <term>"; shift; keep_remove "$*"; exit 0 ;;
      import)  [ "$#" -le 1 ] && fail "usage: /claudish keep import <file>"; shift; keep_import "$*"; exit 0 ;;
      *)       keep_add "$*"; exit 0 ;;
    esac
    ;;
  reset)
    _ld="${CLAUDISH_LOCAL_DIR:-$HOME/.claude/claudish-local}"
    rm -f "$OFF_FILE" "$MODE_FILE" "$STYLE_FILE" "$LANG_FILE" "$MODEL_FILE" "$KEEP_FILE" \
          "$_ld"/last-original "$_ld"/last-original.* \
          "$_ld"/last-rewrite "$_ld"/last-rewrite.* 2>/dev/null || fail "cannot remove one or more flag files"
    ;;
  cycle)
    case "$(state)" in
      off)    set_mode append ;;
      append) set_mode replace ;;
      *)      { : > "$OFF_FILE"; } 2>/dev/null || fail "cannot create $OFF_FILE" ;;
    esac
    ;;
  *)
    printf 'claudish-ctl: unknown command "%s" (use status|on|off|append|replace|style [name]|language [name]|model [name]|keep [term]|keep import <file>|drift|last|cycle|reset)\n' "$cmd" >&2
    exit 2
    ;;
esac

printf 'claudish: %s (style: %s, language: %s, model: %s)\n' "$(state)" "$(current_style)" "$(current_lang)" "$(current_model)"
