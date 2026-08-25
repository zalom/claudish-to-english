#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Owner-run eval for the rewrite prompt. Replays every fixture in
# evals/fixtures/ through the real rewrite.sh and the provider configured in
# the environment (CLAUDISH_PROVIDER and friends), N times each, and counts
# how often the model ANSWERED the message instead of rewriting it.
#
# This spends real model calls (fixtures x runs), so it is never part of the
# tests; run it by hand when the prompt or the model changes:
#
#   evals/rewrite-prompt-eval.sh                 # 3 runs per fixture
#   CLAUDISH_EVAL_RUNS=5 evals/rewrite-prompt-eval.sh
#   CLAUDISH_EVAL_MAX_HIJACKS=1 evals/rewrite-prompt-eval.sh   # tolerate one
#   CLAUDISH_EVAL_AUTH=claude evals/rewrite-prompt-eval.sh     # default: claude -p, the CLI's own login
#   CLAUDISH_EVAL_AUTH=oauth  evals/rewrite-prompt-eval.sh     # anthropic + the Claude Code token
#   CLAUDISH_EVAL_AUTH=apikey evals/rewrite-prompt-eval.sh     # anthropic + API key; skips without one
#   CLAUDISH_EVAL_AUTH=env    evals/rewrite-prompt-eval.sh     # whatever CLAUDISH_* the shell has
#
# A run is a HIJACK when the output opens with a first-person reply to the
# message (refusal, "I cannot see the attachment", "only you can decide"),
# or when it drops an anchor the fixture must keep (repo names, commit
# ids, code). Anchors are the lines of fixtures/<name>.keep, one per line;
# without that file the fixture only checks the refusal patterns.
#
# CLAUDISH_KEEP_TERMS is honoured here too (the keep file is isolated into the
# sandbox, never this machine's real one). Fixture 05-plastic-terms measures
# protected-term survival: run it once with CLAUDISH_KEEP_TERMS set to the
# fixture's own anchors and once with it unset, and compare the dropped-anchor
# counts on that one fixture.
# Exit 0 when hijacks <= CLAUDISH_EVAL_MAX_HIJACKS (default 0). bash 3.2 safe.
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${CLAUDISH_EVAL_RUNS:-3}"
MAX="${CLAUDISH_EVAL_MAX_HIJACKS:-0}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/claudish-eval.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
# Isolate the hook from this machine's mode/style/off/model files and its usage
# ledger. HOME stays: on macOS `security` finds the login Keychain through it.
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR" "$SANDBOX/state"
export CLAUDISH_OFF_FILE="$SANDBOX/state/off" CLAUDISH_MODE_FILE="$SANDBOX/state/mode" \
       CLAUDISH_STYLE_FILE="$SANDBOX/state/style" CLAUDISH_MODEL_FILE="$SANDBOX/state/model" \
       CLAUDISH_LANG_FILE="$SANDBOX/state/language" CLAUDISH_LOCAL_DIR="$SANDBOX/state" \
       CLAUDISH_KEEP_TERMS_FILE="$SANDBOX/state/keep-terms"
export CLAUDISH_MODE=replace CLAUDISH_MIN_CHARS=1 CLAUDISH_NOTICE=0 CLAUDISH_DEBUG=1
# Auth selection for the anthropic provider. apikey needs CLAUDISH_ANTHROPIC_KEY
# or ANTHROPIC_API_KEY in the environment; oauth needs a providers.sh that
# understands CLAUDISH_ANTHROPIC_AUTH=oauth.
AUTH="${CLAUDISH_EVAL_AUTH:-claude}"
case "$AUTH" in
  claude)
    export CLAUDISH_PROVIDER=claude; unset CLAUDISH_ANTHROPIC_AUTH
    command -v claude >/dev/null 2>&1 || { echo "CLAUDISH_EVAL_AUTH=claude needs the claude CLI on PATH" >&2; exit 2; } ;;
  oauth)
    export CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_AUTH=oauth ;;
  apikey)
    export CLAUDISH_PROVIDER=anthropic; unset CLAUDISH_ANTHROPIC_AUTH
    if [ -z "${CLAUDISH_ANTHROPIC_KEY:-${ANTHROPIC_API_KEY:-}}" ]; then
      echo "skipped: CLAUDISH_EVAL_AUTH=apikey but no CLAUDISH_ANTHROPIC_KEY or ANTHROPIC_API_KEY in the environment"; exit 0
    fi ;;
  env) ;;
  *) echo "CLAUDISH_EVAL_AUTH must be claude, oauth, apikey, or env" >&2; exit 2 ;;
esac
unset CLAUDISH_STYLE CLAUDISH_PROMPT_FILE CLAUDISH_LANGUAGE 2>/dev/null || true
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
# The hook under test runs from a sandbox copy of the checkout.
PLUG="$SANDBOX/plugin"; mkdir -p "$PLUG"
cp "$ROOT/rewrite.sh" "$PLUG/rewrite.sh"; [ -f "$ROOT/lang.sh" ] && cp "$ROOT/lang.sh" "$PLUG/lang.sh"
cp "$ROOT/providers.sh" "$PLUG/providers.sh"
cp "$ROOT/keep-terms.sh" "$PLUG/keep-terms.sh"
DEBUG_LOG="$TMPDIR/claudish-to-english/debug.log"
printf 'provider %s (auth %s), model %s, %s run(s) per fixture\n\n' \
  "${CLAUDISH_PROVIDER:-ollama}" "$AUTH" "${CLAUDISH_MODEL:-default}" "$RUNS"

# The reply shapes a hijacked run opens with. Case-insensitive, start of text.
REFUSAL='^(i can.?t|i cannot|i don.?t have (access|the)|i do not have|i.m not able|i am not able|i.m unable|i am unable|only you can|i need you to (share|paste|provide)|as an ai|i.m sorry|i am sorry|sorry, )'

is_hijack() {  # $1 = rewrite text, $2 = keep-file or empty, $3 = reject-file or empty; prints reason or nothing
  _head="$(printf '%s' "$1" | tr -d '\r' | sed -n '1,3p' | tr '\n' ' ' | tr 'A-Z' 'a-z' | sed 's/^[[:space:]#*>_-]*//')"
  if printf '%s' "$_head" | /usr/bin/grep -q -i -E "$REFUSAL"; then printf 'opens with a reply: %s' "$(printf '%s' "$_head" | cut -c1-70)"; return; fi
  if [ -n "$2" ] && [ -f "$2" ]; then
    _lost=""
    while IFS= read -r _a; do
      [ -n "$_a" ] || continue
      case "$1" in *"$_a"*) ;; *) _lost="$_lost${_lost:+, }$_a" ;; esac
    done < "$2"
    [ -n "$_lost" ] && { printf 'dropped anchors: %s' "$_lost"; return; }
  fi
  # Negative anchors: plainer synonyms the drift is known to reach for. A
  # missing .reject file is a no-op, so fixtures 01-04 are unaffected.
  if [ -n "${3:-}" ] && [ -f "$3" ]; then
    _found=""
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      case "$1" in *"$_r"*) _found="$_found${_found:+, }$_r" ;; esac
    done < "$3"
    [ -n "$_found" ] && printf 'found reject word(s): %s' "$_found"
  fi
}

total=0; hijacks=0; failed=0
printf '%-26s %-4s %-7s %s\n' fixture run verdict note
for fx in "$ROOT"/evals/fixtures/*.txt; do
  name="$(basename "$fx" .txt)"; keep="$ROOT/evals/fixtures/$name.keep"; [ -f "$keep" ] || keep=""
  reject="$ROOT/evals/fixtures/$name.reject"; [ -f "$reject" ] || reject=""
  msg="$(cat "$fx")"
  i=1
  while [ "$i" -le "$RUNS" ]; do
    total=$((total + 1))
    out="$(jq -n --arg mid "eval-$name-$i" --arg d "$msg" \
      '{message_id:$mid, session_id:"eval", index:0, final:true, delta:$d}' \
      | bash "$PLUG/rewrite.sh" 2>/dev/null)"
    rw="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.displayContent // empty' 2>/dev/null)"
    if [ -z "$rw" ] || [ "$rw" = "$msg" ]; then
failed=$((failed + 1))
why="$(tail -1 "$DEBUG_LOG" 2>/dev/null | sed 's/^[^]]*] //')"
printf '%-26s %-4s %-7s %s\n' "$name" "$i" "FAIL" "no rewrite: ${why:-provider error or fail-open}"
    else
      # replace mode prefixes the separator label; judge the text after it
      body="$(printf '%s' "$rw" | awk 'f{print} /^💬 /{f=1}')"; [ -n "$body" ] || body="$rw"
      why="$(is_hijack "$body" "$keep" "$reject")"
      if [ -n "$why" ]; then hijacks=$((hijacks + 1)); printf '%-26s %-4s %-7s %s\n' "$name" "$i" "HIJACK" "$why"
      else printf '%-26s %-4s %-7s %s\n' "$name" "$i" "ok" "$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-60)..."; fi
    fi
    i=$((i + 1))
  done
done
printf '\n%d runs: %d ok, %d hijacked, %d failed (provider). Threshold: %d hijack(s).\n' \
  "$total" $((total - hijacks - failed)) "$hijacks" "$failed" "$MAX"
[ "$hijacks" -le "$MAX" ] && [ "$failed" -eq 0 ]
