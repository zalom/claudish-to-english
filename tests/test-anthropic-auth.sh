#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermetic test for the anthropic provider's two auth paths in providers.sh:
#   apikey  CLAUDISH_ANTHROPIC_KEY -> "x-api-key" header, no oauth beta flag
#   oauth   CLAUDISH_ANTHROPIC_AUTH=oauth -> token from the Keychain, sent as
#           "Authorization: Bearer" plus the oauth beta flag, expiry honored,
#           file fallback, cap marker, ledger line; refresh token never stored
# curl and security are stubs on PATH; nothing leaves the machine and no real
# key or token is involved. Works on macOS /bin/bash 3.2.
#
#   tests/test-anthropic-auth.sh        # exit 0 = all checks passed
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Hermetic: forget every claudish or Anthropic setting the caller's shell has
# (a machine running oauth mode would otherwise leak it into the apikey case).
for _v in $(env | sed -n 's/^\(CLAUDISH_[A-Z_]*\)=.*/\1/p') ANTHROPIC_API_KEY; do unset "$_v"; done
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/claudish-auth.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR" "$SANDBOX/bin" "$SANDBOX/out" "$SANDBOX/home" "$SANDBOX/state"
OUT="$SANDBOX/out"; export CLAUDISH_TEST_OUT="$OUT"

# --- stubs -----------------------------------------------------------------
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/bin/bash
# record argv, keep a copy of the -K key file, write fake response headers on -D
printf '%s\n' "$@" > "$CLAUDISH_TEST_OUT/curl.args"
cat > "$CLAUDISH_TEST_OUT/curl.stdin"
prev=""
for a in "$@"; do
  [ "$prev" = "-K" ] && cp "$a" "$CLAUDISH_TEST_OUT/keyfile"
  [ "$prev" = "-D" ] && printf 'HTTP/2 200\r\nanthropic-ratelimit-unified-5h-utilization: 0.22\r\nanthropic-ratelimit-unified-7d-utilization: 0.07\r\nanthropic-ratelimit-unified-5h-reset: 1800000000\r\n\r\n' > "$a"
  prev="$a"
done
printf '{"content":[{"type":"text","text":"STUB REWRITE"}],"usage":{"input_tokens":15,"output_tokens":5}}\n200'
STUB
cat > "$SANDBOX/bin/security" <<'STUB'
#!/bin/bash
[ "${CLAUDISH_TEST_KEYCHAIN:-1}" = "1" ] || exit 1
printf '{"claudeAiOauth":{"accessToken":"TESTTOKEN-abc","refreshToken":"TESTREFRESH-must-never-leak","expiresAt":%s}}\n' "${CLAUDISH_TEST_EXPIRES:-$(( ($(date +%s) + 3600) * 1000 ))}"
STUB
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/bin/security"
export PATH="$SANDBOX/bin:$PATH"

pass=0; fail=0
check() { if [ "$1" = "0" ]; then pass=$((pass + 1)); printf 'PASS  %s\n' "$2"; else fail=$((fail + 1)); printf 'FAIL  %s\n' "$2"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# run_case <name> [VAR=value ...]: source providers.sh in a subshell with the
# given env, call llm_complete, and dump the state to $OUT/<name>.state
run_case() {
  _name="$1"; shift
  rm -f "$OUT/curl.args" "$OUT/curl.stdin" "$OUT/keyfile"
  (
    export "$@"
    LLM_TIMEOUT=5; TIMEOUT_HINT=""; DEBUG=0; dbg() { return 0; }
    . "$ROOT/providers.sh"
    llm_complete "SYS" "USER"
    llm_notice_why
    printf 'rewrite=%s\ncurl_rc=%s\nhttp=%s\noauth_expired=%s\noauth_paused=%s\nnotice=%s\nkey_exported=%s\nkey_in_env=%s\n' \
      "$rewrite" "$curl_rc" "${http:-}" "${oauth_expired:-}" "${oauth_paused:-}" "${NOTICE_WHY:-}" \
      "$(export -p | /usr/bin/grep -c 'ANTHROPIC_KEY=' || true)" "$(env | /usr/bin/grep -c 'oat-test-token' || true)" \
      > "$OUT/$_name.state"
  )
}
val() { sed -n "s/^$2=//p" "$OUT/$1.state"; }

# --- apikey ---------------------------------------------------------------
run_case apikey CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_KEY=TESTKEY-not-a-real-key CLAUDISH_LOCAL_DIR="$SANDBOX/state"
[ "$(val apikey rewrite)" = "STUB REWRITE" ]; check $? "apikey: rewrite comes back through curl"
has "$(cat "$OUT/keyfile" 2>/dev/null)" 'header = "x-api-key: TESTKEY-not-a-real-key"'; check $? "apikey: key travels in the -K file as x-api-key"
! has "$(cat "$OUT/curl.args" 2>/dev/null)" "TESTKEY-not-a-real-key"; check $? "apikey: key never appears on the curl command line"
! has "$(cat "$OUT/curl.args" 2>/dev/null)" "oauth-2025-04-20"; check $? "apikey: no oauth beta flag"
[ -z "$(ls "$TMPDIR"/claudish-key.* 2>/dev/null)" ]; check $? "apikey: the key file is removed after the call"

# --- oauth, Keychain ------------------------------------------------------
run_case oauth CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_AUTH=oauth CLAUDISH_LOCAL_DIR="$SANDBOX/state" SID=sess-1234
[ "$(val oauth rewrite)" = "STUB REWRITE" ]; check $? "oauth: rewrite comes back through curl"
has "$(cat "$OUT/keyfile" 2>/dev/null)" 'header = "Authorization: Bearer TESTTOKEN-abc"'; check $? "oauth: Keychain token travels as Authorization: Bearer"
has "$(cat "$OUT/curl.args" 2>/dev/null)" "anthropic-beta: oauth-2025-04-20"; check $? "oauth: beta flag is sent"
! has "$(cat "$OUT/curl.args" 2>/dev/null)" "TESTTOKEN-abc"; check $? "oauth: token never appears on the curl command line"
[ "$(val oauth key_exported)" = "0" ] && [ "$(val oauth key_in_env)" = "0" ]; check $? "oauth: token is never exported to the environment"
! /usr/bin/grep -rq "TESTREFRESH-must-never-leak" "$SANDBOX/out" "$SANDBOX/state" "$TMPDIR" 2>/dev/null; check $? "oauth: refresh token lands in no file"
ledger="$(tail -1 "$SANDBOX/state/usage.log" 2>/dev/null)"
[ "$(printf '%s' "$ledger" | awk -F'\t' '{print NF}')" = "11" ]; check $? "oauth: ledger line has 11 tab-separated columns"
[ "$(printf '%s' "$ledger" | cut -f7)" = "22" ] && [ "$(printf '%s' "$ledger" | cut -f8)" = "7" ] && [ "$(printf '%s' "$ledger" | cut -f11)" = "sess-1234" ]; check $? "oauth: ledger carries the 5h/7d meters and the session id"
! has "$ledger" "USER"; check $? "oauth: ledger carries no message content"
[ -z "$(ls "$TMPDIR"/claudish-key.* "$TMPDIR"/claudish-hdr.* 2>/dev/null)" ]; check $? "oauth: key and header temp files are removed"

# --- oauth, expired token -------------------------------------------------
run_case expired CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_AUTH=oauth CLAUDISH_LOCAL_DIR="$SANDBOX/state" CLAUDISH_TEST_EXPIRES=1000000000000
[ ! -f "$OUT/curl.args" ] && [ "$(val expired oauth_expired)" = "1" ]; check $? "oauth: an expired token is not sent"
has "$(val expired notice)" "expired"; check $? "oauth: the notice explains the expiry"

# --- oauth, no Keychain, credentials file fallback ------------------------
mkdir -p "$SANDBOX/home/.claude"
printf '{"claudeAiOauth":{"accessToken":"TESTFILETOKEN-xyz","refreshToken":"TESTFILEREFRESH-secret","expiresAt":%s}}' "$(( ($(date +%s) + 3600) * 1000 ))" > "$SANDBOX/home/.claude/.credentials.json"
run_case filefb CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_AUTH=oauth CLAUDISH_LOCAL_DIR="$SANDBOX/state" CLAUDISH_TEST_KEYCHAIN=0 HOME="$SANDBOX/home"
has "$(cat "$OUT/keyfile" 2>/dev/null)" 'Authorization: Bearer TESTFILETOKEN-xyz'; check $? "oauth: falls back to ~/.claude/.credentials.json without a Keychain"

# --- oauth, cap marker ----------------------------------------------------
printf '%s 90\n' "$(( $(date +%s) + 3600 ))" > "$SANDBOX/state/paused"
run_case capped CLAUDISH_PROVIDER=anthropic CLAUDISH_ANTHROPIC_AUTH=oauth CLAUDISH_LOCAL_DIR="$SANDBOX/state" CLAUDISH_OAUTH_MAX_UTIL=85
[ ! -f "$OUT/curl.args" ] && has "$(val capped oauth_paused)" "90%"; check $? "oauth: the utilization cap skips the call and reports the pause"
rm -f "$SANDBOX/state/paused"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
