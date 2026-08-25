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

# Append clean terms to the keep FILE, keeping whatever is already in it
# (comments included). $1 = newline separated clean terms. Sets KEEP_ADDED to
# the terms actually written and KEEP_DUP to how many were already there.
# Membership is an exact whole-line `case` test on a newline-wrapped string: no
# subprocess, no pipe, and never a pattern match against the term itself.
keep_append() {
  KEEP_ADDED=""; KEEP_DUP=0
  known="${KEEP_NL}$(claudish_keep_file_terms)${KEEP_NL}"
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
  # A leading newline when the file already has content: a stray blank line is
  # harmless (blank lines are skipped on read) and it is cheaper than probing
  # whether the last byte is a newline.
  if [ -s "$KEEP_FILE" ]; then
    { printf '\n%s' "$KEEP_ADDED" >> "$KEEP_FILE"; } 2>/dev/null || fail "cannot write $KEEP_FILE"
  else
    { printf '%s' "$KEEP_ADDED" > "$KEEP_FILE"; } 2>/dev/null || fail "cannot write $KEEP_FILE"
  fi
  return 0
}

# Warn once when the file now holds as many terms as the read path will use.
# When KEEP_ADDED (set by keep_append) names the terms just written, name
# whichever of those specifically fell past the cap, so the user learns THEIR
# term was the one dropped rather than a generic notice.
keep_cap_note() {
  c="$(claudish_keep_file_terms | grep -c '[^[:space:]]')"
  [ "$c" -ge "${CLAUDISH_KEEP_MAX_TERMS:-200}" ] || return 0
  dropped=""
  if [ -n "${KEEP_ADDED:-}" ]; then
    _cftmp="$(mktemp "${TMPDIR:-/tmp}/claudish-capped.XXXXXX" 2>/dev/null)"
    if [ -n "$_cftmp" ]; then
      claudish_keep_file_terms > "$_cftmp" 2>/dev/null
      dropped="$(printf '%s\n' "$KEEP_ADDED" | grep -vFxf "$_cftmp" 2>/dev/null)"
      rm -f "$_cftmp" 2>/dev/null
    fi
  fi
  if [ -n "$dropped" ]; then
    printf 'claudish-ctl: the keep list is full at %s terms; not added: %s\n' \
      "${CLAUDISH_KEEP_MAX_TERMS:-200}" "$(printf '%s' "$dropped" | tr '\n' ',' | sed 's/,/, /g; s/, $//')" >&2
  else
    printf 'claudish-ctl: the keep list is full at %s terms; anything past that is ignored\n' \
      "${CLAUDISH_KEEP_MAX_TERMS:-200}" >&2
  fi
  return 0
}

keep_add() {  # $1 = the whole argument string, comma separated
  new="$(_claudish_keep_norm "$1" "")"
  [ -n "$new" ] || fail "nothing to add (use /claudish keep <term>[, <term>...])"
  keep_append "$new"
  keep_cap_note
  keep_summary added "$KEEP_ADDED"
}

keep_remove() {  # $1 = one term, matched as a whole line, commas included
  term="$(_claudish_keep_norm "" "$1")"
  [ -n "$term" ] || fail "usage: /claudish keep remove <term>"
  [ -f "$KEEP_FILE" ] || fail "\"$term\" is not in the keep list (see /claudish keep list)"
  # Match against each raw line with surrounding whitespace trimmed (so a
  # hand-indented term still matches), then delete by line number. grep -xF
  # is a whole-line, fixed-string test on the trimmed copy: unlike awk -v it
  # never expands a backslash in the term and never compares numeric
  # look-alikes (0, 0.0, 1e3, 1000, +7, 7) as equal. Comments and blank lines
  # are untouched: a comment never equals a term, so it is never selected.
  lines="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$KEEP_FILE" | grep -nxF -- "$term" | cut -d: -f1)"
  [ -n "$lines" ] || fail "\"$term\" is not in the keep list (see /claudish keep list)"
  sed_expr=""
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    sed_expr="${sed_expr}${sed_expr:+;}${ln}d"
  done <<KEEP_REMOVE_EOF
$lines
KEEP_REMOVE_EOF
  out="$(sed -e "$sed_expr" "$KEEP_FILE")"
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
  added="$(printf '%s' "$KEEP_ADDED" | grep -c '[^[:space:]]')"
  case "$added" in ''|*[!0-9]*) added=0 ;; esac
  keep_cap_note
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
  LF="
"
  n="$(printf '%s\n' "$t" | grep -c '[^[:space:]]')"
  out="claudish keep terms ($n):"$'\n'
  while IFS= read -r term; do
    [ -n "$term" ] || continue
    case "$LF$e$LF" in
      *"$LF$term$LF"*) out="${out}  $(printf '%-24s' "$term") env CLAUDISH_KEEP_TERMS"$'\n' ;;
      *)                out="${out}  $(printf '%-24s' "$term") /claudish keep"$'\n' ;;
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
    # `last` has to. It NEVER changes the keep list: it prints the command to run.
    [ "$KEEP_OK" = "1" ] || fail "keep-terms.sh not found next to claudish-ctl.sh"
    LD="${CLAUDISH_LOCAL_DIR:-$HOME/.claude/claudish-local}"
    if [ ! -f "$LD/last-original" ] || [ ! -f "$LD/last-rewrite" ]; then
      printf 'claudish-ctl: no stored rewrite yet. Let one assistant message go through with the rewrite on, then run /claudish drift (CLAUDISH_DRIFT=0 turns the storing off).\n' >&2
      exit 1
    fi
    # Fenced code blocks are dropped by the tldr preset by design, so counting
    # them would report every identifier in every code block as lost.
    cand="$(awk 'BEGIN{f=0} /^```/{f=!f; next} f==0{print}' "$LD/last-original" \
      | tr -c 'A-Za-z0-9._-' '\n' \
      | sed -e 's/^[._-]*//' -e 's/[._-]*$//' \
      | sort -u)"
    prot="${KEEP_NL}$(claudish_keep_terms 2>/dev/null)${KEEP_NL}"
    hits=""; nhits=0
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      [ "$nhits" -ge 20 ] && break
      # Does it look like a term rather than ordinary English? An uppercase
      # letter after the first position, or a dot, hyphen or digit, or simply
      # long and not one of a few common words.
      looks=0
      case "$tok" in
        ?*[A-Z]*)        looks=1 ;;
        *[0-9]*|*.*|*-*) looks=1 ;;
      esac
      if [ "$looks" = "0" ] && [ "${#tok}" -ge 8 ]; then
        case "$tok" in
          because|therefore|something|everything|different|available|important|following|remaining|assistant|original|question|sentence|probably|actually|anything|possible|together) ;;
          *) looks=1 ;;
        esac
      fi
      [ "$looks" = "1" ] || continue
      # Already protected? Exact whole-line test, no subprocess, no pipe.
      case "$prot" in *"${KEEP_NL}${tok}${KEEP_NL}"*) continue ;; esac
      # Still in the rewrite? -F so the token is never a pattern, -w so a
      # substring does not count, reading the file directly so nothing can
      # take a SIGPIPE.
      grep -qFw -- "$tok" "$LD/last-rewrite" 2>/dev/null && continue
      hits="${hits}${hits:+, }$tok"
      nhits=$((nhits + 1))
    done <<DRIFT_EOF
$cand
DRIFT_EOF
    if [ -z "$hits" ]; then
      printf '\n  claudish drift: nothing to flag in the last rewrite.\n\n'
      exit 0
    fi
    printf '\n  claudish drift: in the last original, not in the last rewrite\n\n'
    printf '  %s\n\n' "$hits"
    printf '  These are candidates to check, not a verdict: a rewrite may drop a word for good\n'
    printf '  reasons. Cut the ones that do not matter, then run the rest:\n\n'
    printf '  /claudish keep %s\n\n' "$hits"
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
          "$_ld/last-original" "$_ld/last-rewrite" 2>/dev/null || fail "cannot remove one or more flag files"
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
