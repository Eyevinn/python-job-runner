#!/usr/bin/env bash
# Checks that the entrypoint runs @osaas/cli at the pinned OSAAS_CLI_VERSION
# and fails fast when it is unset.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$3', got '$2')"; fail=1; fi; }

# Extract the config-to-env command line from the entrypoint
line=$(grep 'npx -y "@osaas/cli@' "$root/scripts/docker-entrypoint.sh" | head -1)
printf '#!/bin/bash\necho "NPX_ARGS: $*"\n' > "$tmp/npx"; chmod +x "$tmp/npx"
printf '%s\n' "set -e" "CONFIG_SVC=store" "$line" 'echo "$config_env_output"' > "$tmp/block.sh"

# Passing path: pinned spec is used
out=$(env -i PATH="$tmp:$PATH" OSAAS_CLI_VERSION=4.35.0 bash "$tmp/block.sh" 2>&1)
check "npx uses pinned spec" "$(echo "$out" | grep -c 'NPX_ARGS: -y @osaas/cli@4.35.0 web config-to-env')" "1"

# Failing path: unset version aborts and never calls npx
out=$(env -i PATH="$tmp:$PATH" bash "$tmp/block.sh" 2>&1); rc=$?
check "unset version fails" "$([ $rc -ne 0 ] && echo yes)" "yes"
check "unset version never runs npx" "$(echo "$out" | grep -c NPX_ARGS)" "0"

# No floating tag, and the version is pinned in exactly one place
check "no @latest for @osaas/cli" "$(grep -rn '@osaas/cli@latest' "$root/scripts" "$root/Dockerfile" | wc -l | tr -d ' ')" "0"
check "version pinned once in Dockerfile" "$(grep -c '^ENV OSAAS_CLI_VERSION=' "$root/Dockerfile")" "1"
exit $fail
