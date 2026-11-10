#!/bin/bash
# Tests the runner-token refresh exchange in scripts/docker-entrypoint.sh.
# Sources the entrypoint (which only defines functions) and runs load_config under set -e
# with stubbed curl/npx/node.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT/scripts/docker-entrypoint.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILS=0

mkdir -p "$WORK/bin"
# curl stub: honours -o and -w '%{http_code}'; records the request body file.
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    --data) data="${2#@}"; shift 2;;
    *) shift;;
  esac
done
[ -n "$data" ] && cp "$data" "$STUB_DIR/request_body"
[ -n "$data" ] && { stat -c %a "$data" 2>/dev/null || stat -f %Lp "$data"; } > "$STUB_DIR/body_mode"
[ "${STUB_CURL_EXIT:-0}" != "0" ] && exit "$STUB_CURL_EXIT"
printf '%s' "${STUB_BODY:-}" > "$out"
printf '%s' "${STUB_HTTP:-200}"
EOF
# npx stub: records the token it was called with.
cat > "$WORK/bin/npx" <<'EOF'
#!/bin/bash
echo "$OSC_ACCESS_TOKEN" > "$STUB_DIR/npx_token"
echo "export FOO=bar"
EOF
chmod +x "$WORK/bin/curl" "$WORK/bin/npx"
# node stub that exits 127 (parser unavailable)
mkdir -p "$WORK/bin127"
cp "$WORK/bin/curl" "$WORK/bin/npx" "$WORK/bin127/"
printf '#!/bin/bash\nexit 127\n' > "$WORK/bin127/node"
chmod +x "$WORK/bin127/node"

REAL_NODE=$(command -v node)
ln -s "$REAL_NODE" "$WORK/bin/node"

run_case() { # name pathdir http body curlexit
  local name="$1" pathdir="$2"
  export STUB_DIR="$WORK/s_$name" STUB_HTTP="$3" STUB_BODY="$4" STUB_CURL_EXIT="${5:-0}"
  mkdir -p "$STUB_DIR"
  cat > "$WORK/run_$name.sh" <<EOF
set -e
export PATH="$pathdir:/usr/bin:/bin"
export ENTRYPOINT="$ENTRYPOINT"
export OSC_ACCESS_TOKEN=original CONFIG_SVC=cfg OSC_ENV=dev
source "$ENTRYPOINT"
load_config
echo "BLOCK_DONE access=\$OSC_ACCESS_TOKEN refresh=\$OSC_REFRESH_TOKEN foo=\${FOO:-}"
# The install stage runs without the runner credentials: the refresh token must be removed too.
echo "INSTALL_ENV=\$(without_secrets env | grep -cE '^(OSC_ACCESS_TOKEN|OSC_REFRESH_TOKEN)=' || true)"
EOF
  bash "$WORK/run_$name.sh" > "$WORK/out_$name" 2> "$WORK/err_$name"
  echo $? > "$WORK/exit_$name"
}

check() { # name description condition-exit
  if [ "$3" -eq 0 ]; then echo "PASS: $1: $2"; else echo "FAIL: $1: $2"; FAILS=$((FAILS+1)); fi
}
contains() { grep -q -- "$2" "$1"; }

# Success: fresh token used by config load, job keeps original
run_case ok "$WORK/bin" 200 '{"token":"NEWTOK123","expiresIn":3600}'
check ok "block completes" "$(contains "$WORK/out_ok" BLOCK_DONE; echo $?)"
check ok "config load used FRESH token" "$([ "$(cat "$WORK/s_ok/npx_token")" = NEWTOK123 ]; echo $?)"
check ok "job OSC_ACCESS_TOKEN unchanged" "$(contains "$WORK/out_ok" 'access=original'; echo $?)"
check ok "OSC_REFRESH_TOKEN is original" "$(contains "$WORK/out_ok" 'refresh=original'; echo $?)"
check ok "body is JSON with token" "$([ "$(cat "$WORK/s_ok/request_body")" = '{"token":"original"}' ]; echo $?)"
check ok "body file mode 600" "$([ "$(cat "$WORK/s_ok/body_mode")" = 600 ]; echo $?)"
check ok "no warning" "$(! contains "$WORK/err_ok" WARNING; echo $?)"
check ok "env from config applied" "$(contains "$WORK/out_ok" 'foo=bar'; echo $?)"
check ok "install stage sees no runner tokens" "$(contains "$WORK/out_ok" 'INSTALL_ENV=0'; echo $?)"

# Failure paths: warning, original token used, block continues
fail_case() { # name http body curlexit expected-substring
  run_case "$1" "$WORK/bin" "$2" "$3" "$4"
  local n="$1"
  check "$n" "block completes" "$(contains "$WORK/out_$n" BLOCK_DONE; echo $?)"
  check "$n" "exit 0" "$([ "$(cat "$WORK/exit_$n")" = 0 ]; echo $?)"
  check "$n" "config load used ORIGINAL token" "$([ "$(cat "$WORK/s_$n/npx_token")" = original ]; echo $?)"
  check "$n" "[CONFIG] warning with $5" "$(contains "$WORK/err_$n" "\[CONFIG\] WARNING.*$5"; echo $?)"
  check "$n" "token not leaked" "$(! cat "$WORK/out_$n" "$WORK/err_$n" | grep -q NEWTOK123; echo $?)"
}
fail_case expired 401 '{"code":"refresh_token_expired"}' 0 'HTTP 401, code=refresh_token_expired'
fail_case invalid 401 '{"code":"refresh_token_invalid"}' 0 'code=refresh_token_invalid'
fail_case revoked 401 '{"code":"refresh_token_revoked"}' 0 'code=refresh_token_revoked'
fail_case err500 500 'oops' 0 'HTTP 500'
fail_case emptybody 200 '' 0 'HTTP 200'
fail_case garbled 200 'not json{' 0 'HTTP 200'
fail_case notoken 200 '{"expiresIn":3600}' 0 'HTTP 200'
fail_case curl22 200 '' 22 'HTTP 000'
fail_case curl28 200 '' 28 'HTTP 000'

# Parser unavailable (node exits 127): empty token is a failure, original used
run_case nonode "$WORK/bin127" 200 '{"token":"NEWTOK123","expiresIn":3600}'
check nonode "block completes" "$(contains "$WORK/out_nonode" BLOCK_DONE; echo $?)"
check nonode "config load used ORIGINAL token (not empty)" "$([ "$(cat "$WORK/s_nonode/npx_token")" = original ]; echo $?)"
check nonode "[CONFIG] warning printed" "$(contains "$WORK/err_nonode" '\[CONFIG\] WARNING'; echo $?)"

[ "$FAILS" -eq 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
