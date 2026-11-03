#!/bin/bash
# Unit tests for scripts/docker-entrypoint.sh. Run: bash tests/entrypoint_test.sh
set -u
cd "$(dirname "$0")/.."
# shellcheck source=../scripts/docker-entrypoint.sh
source scripts/docker-entrypoint.sh
set +e

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" == "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

parse_source_url "https://github.com/org/repo"
check "plain url" "github.com|org/repo|" "$SRC_HOST_PUBLIC|$SRC_REPO|$SRC_REF"

parse_source_url "https://github.com/org/repo.git#v1.2.0"
check "fragment ref" "github.com|org/repo|v1.2.0" "$SRC_HOST_PUBLIC|$SRC_REPO|$SRC_REF"

parse_source_url "https://github.com/org/repo/tree/feature/x"
check "tree ref" "org/repo|feature/x" "$SRC_REPO|$SRC_REF"

parse_source_url "https://user@gitea.example.com/org/repo#main"
check "host with user" "user@gitea.example.com|gitea.example.com" "$SRC_HOST|$SRC_HOST_PUBLIC"

sha=0123456789abcdef0123456789abcdef01234567
is_commit_sha "$sha"; check "40-hex is a sha" 0 $?
is_commit_sha "${sha}${sha:0:24}"; check "64-hex is a sha" 0 $?
is_commit_sha "v1.2.0"; check "tag is not a sha" 1 $?
is_commit_sha "${sha:0:7}"; check "short sha is not pinned" 1 $?
is_commit_sha "0123456789ABCDEF0123456789ABCDEF01234567"; check "uppercase is not a sha" 1 $?

export OSC_ACCESS_TOKEN=osc-secret GIT_TOKEN=git-secret GITHUB_TOKEN=gh-secret KEEP_ME=visible
seen=$(without_secrets env | grep -E '^(OSC_ACCESS_TOKEN|GIT_TOKEN|GITHUB_TOKEN|KEEP_ME)=' | sort | tr '\n' ' ')
check "install env has no credentials" "KEEP_ME=visible " "$seen"
check "runner keeps its own token" "osc-secret" "$OSC_ACCESS_TOKEN"

err=$(resolve_git_credential "Bad/Name" 2>&1 >/dev/null); check "bad credential name rejected" 1 $?
unset OSC_ACCESS_TOKEN
err=$(resolve_git_credential "github-work" 2>&1 >/dev/null); check "credential needs access token" 1 $?

# Parameter-store values are loaded after installation: setup.sh must not see them.
work=$(mktemp -d)
cat > "$work/setup.sh" <<'SH'
#!/bin/sh
echo "${FROM_STORE:-unset}" > setup-saw
SH
(
  cd "$work"
  # Simulate a store load by defining load_config to export a value.
  load_config() { export FROM_STORE=store-value; }
  install_dependencies >/dev/null
  load_config
  echo "$FROM_STORE" > worker-saw
)
check "setup.sh runs before config is loaded" "unset" "$(cat "$work/setup-saw")"
check "worker gets config" "store-value" "$(cat "$work/worker-saw")"
rm -rf "$work"

if [ $failures -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
