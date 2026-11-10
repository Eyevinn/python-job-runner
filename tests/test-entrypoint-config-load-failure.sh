#!/bin/bash
# Tests that a failed config load never prints decrypted parameter values.
# Run: bash tests/test-entrypoint-config-load-failure.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0
# shellcheck source=../scripts/docker-entrypoint.sh
source "$ROOT/scripts/docker-entrypoint.sh"
set +e

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
absent() { # name, haystack, needle
  case "$2" in *"$3"*) bad "$1 (found '$3' in '$2')";; *) ok "$1";; esac
}
present() {
  case "$2" in *"$3"*) ok "$1";; *) bad "$1 (no '$3' in '$2')";; esac
}

# Case 1: the helper alone.
out=$(config_safe_output "export KEY='canary-1'")
absent "plain value removed" "$out" "canary-1"
out=$(config_safe_output "export MY-KEY='canary-2'")
absent "non-identifier key value removed" "$out" "canary-2"
out=$(config_safe_output "$(printf "export PEM='-----BEGIN\ncanary-3\n-----END'\nafter")")
absent "multi-line value removed" "$out" "canary-3"
present "line after multi-line value kept" "$out" "after"
out=$(config_safe_output "$(printf "export A='canary-5'\nCannot read properties of null (reading 'replace')")")
absent "partial output value removed" "$out" "canary-5"
present "trailing diagnostic kept" "$out" "Cannot read properties of null"
out=$(config_safe_output "$(printf "export A='it'\\\\''s canary-6'\nError: boom")")
absent "escaped quote value removed" "$out" "canary-6"
present "diagnostic after escaped quote kept" "$out" "Error: boom"
out=$(config_safe_output "$(printf "export A='canary-8\nError: later")")
absent "unclosed quote fails closed" "$out" "canary-8"
out=$(config_safe_output "$(printf "export BA'D='canary-9'\ncanary-10'")")
absent "quote in key fails closed (value)" "$out" "canary-9"
absent "quote in key fails closed (continuation)" "$out" "canary-10"
out=$(config_safe_output "$(printf "export K=X'='line1\ncanary-11'\nError: tail")")
absent "key containing =' fails closed" "$out" "canary-11"
out=$(config_safe_output "$(printf "export K='X='val\ncanary-13'\nError: tail")")
absent "key K='X fails closed" "$out" "canary-13"
out=$(config_safe_output "$(printf "export KE\nY='canary-14'\nError: tail")")
absent "key with newline fails closed" "$out" "canary-14"
out=$(config_safe_output "$(printf "export A='abc='\nError: boom")")
present "value ending in = keeps diagnostic" "$out" "Error: boom"
out=$(config_safe_output "$(printf "export A='a='\\\\''b canary-15'\nError: boom")")
absent "value with =' removed" "$out" "canary-15"
present "diagnostic after =' value kept" "$out" "Error: boom"
out=$(config_safe_output "$(printf "warn: x\nexport A='canary-16'")")
present "text before first export kept" "$out" "warn: x"

ghp="ghp_$(printf 'a%.0s' $(seq 1 36))"
out=$(OSC_ACCESS_TOKEN=osc-access-token-literal-value FRESH_PAT=fresh-pat-literal-value \
  config_safe_output "osc-access-token-literal-value fresh-pat-literal-value $ghp eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig Basic dXNlcjpwYXNzd29yZA==")
absent "OSC_ACCESS_TOKEN redacted" "$out" "osc-access-token-literal-value"
absent "FRESH_PAT redacted" "$out" "fresh-pat-literal-value"
absent "ghp token redacted" "$out" "ghp_"
absent "JWT redacted" "$out" "eyJ"
absent "Basic credentials redacted" "$out" "dXNlcjpwYXNzd29yZA"
present "redaction marker present" "$out" "[REDACTED]"
out=$(config_safe_output "$(printf "Error: 401 Unauthorized")")
[ "$out" = "Error: 401 Unauthorized" ] && ok "plain error unchanged" || bad "plain error unchanged ('$out')"
out=$(config_safe_output "$(printf "a\nb\nc")")
case "$out" in *$'\n'*) bad "result has no newline";; *) ok "result has no newline";; esac

# Cases 2 and 3: load_config with a failing and a succeeding stub npx.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npx" <<'EOF'
#!/bin/bash
if [ "${STUB_MODE:-fail}" = "fail" ]; then
  echo "export SECRET='canary-4'"
  echo "Cannot read properties of null (reading 'replace')"
  exit 3
fi
if [ "${STUB_MODE:-fail}" = "empty" ]; then
  echo "npm notice something"
  exit 0
fi
echo "export FOO='bar'"
exit 0
EOF
chmod +x "$WORK/bin/npx"

run_load() { # mode -> sets RC, STDOUT, STDERR, FOO_SEEN
  STUB_MODE="$1" PATH="$WORK/bin:$PATH" bash -c '
    source "$1"
    _TOKEN_REFRESHED=1
    OSC_ACCESS_TOKEN=osc-access-token-literal-value
    CONFIG_SVC=svc
    load_config
    echo "rc=$?"
    echo "FOO=${FOO:-unset}"
  ' _ "$ROOT/scripts/docker-entrypoint.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  STDOUT=$(cat "$WORK/stdout")
  STDERR=$(cat "$WORK/stderr")
}

run_load fail
present "failure reports exit code" "$STDERR" "[CONFIG] ERROR: Failed to load config (exit 3)"
present "failure keeps CLI diagnostic" "$STDERR" "Cannot read properties of null"
absent "failure stderr has no secret" "$STDERR" "canary-4"
absent "failure stdout has no secret" "$STDOUT" "canary-4"
present "failure lets the job continue" "$STDOUT" "rc=0"

run_load ok
present "success reports loaded count" "$STDOUT" "[CONFIG] Loaded 1 environment variable(s)"
present "success exports FOO" "$STDOUT" "FOO=bar"
absent "success prints no value in the log lines" "$(grep '^\[CONFIG\]' "$WORK/stdout")" "bar"

run_load empty
present "empty store warns" "$STDERR" "[CONFIG] WARNING: config service 'svc' returned no export lines"
present "empty store lets the job continue" "$STDOUT" "rc=0"
present "empty store exports nothing" "$STDOUT" "FOO=unset"

# Case 4: wiring guard, the error line goes through the helper.
line=$(declare -f load_config | grep '\[CONFIG\] ERROR')
present "error line uses config_safe_output" "$line" 'config_safe_output "$output"'
case "$line" in *': $output'*) bad "error line has a bare \$output";; *) ok "error line has no bare \$output";; esac

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) failed"
  exit 1
fi
echo "all tests passed"
