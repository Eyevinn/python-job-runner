#!/bin/bash
set -e

# Order of a run:
#   1. resolve the git credential and clone the source (pinned to a commit when asked)
#   2. install dependencies and run setup.sh, with no credentials in the environment
#   3. load the parameter store and run the worker
# Parameter-store values are fetched only after steps 1 and 2, so repository code that runs
# during installation (setup.py, build backends, setup.sh) never sees them.

WORK_ROOT="${WORK_ROOT:-/usercontent}"

# Credentials the runner itself uses. They are removed from the environment of the
# dependency installation and setup.sh.
RUNNER_SECRET_VARS=(OSC_ACCESS_TOKEN OSC_REFRESH_TOKEN GIT_TOKEN GITHUB_TOKEN)

osc_env() {
  if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
    local extracted
    extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    OSC_ENV=${extracted:-prod}
  fi
  echo "${OSC_ENV:-prod}"
}

# Read one string field from a JSON file; prints nothing on any failure. Uses node because
# the exchange must not depend on jq being installed in the image.
json_field() {
  node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=o[process.argv[2]];if(typeof v==="string")process.stdout.write(v)}catch(e){}' "$1" "$2" 2>/dev/null || true
}

# Exchange the runner token for a fresh 1h token (POST {"token": ...} to
# runner-token/refresh). The result goes in FRESH_PAT, which is a plain shell variable and
# so never reaches child processes. OSC_ACCESS_TOKEN is left as it is: the job keeps the
# original token, and only the git credential lookup and the config load use the fresh one.
# Every step is guarded so that set -e can never end the run here; on failure FRESH_PAT stays
# empty and callers fall back to the original token.
refresh_access_token() {
  [ -n "${OSC_ACCESS_TOKEN:-}" ] || return 0
  [ -z "${_TOKEN_REFRESHED:-}" ] || return 0
  _TOKEN_REFRESHED=1
  FRESH_PAT=""
  local source_token="${OSC_REFRESH_TOKEN:-$OSC_ACCESS_TOKEN}"
  local http="000" code="" body_file out_file
  body_file=$(mktemp)
  out_file=$(mktemp)
  chmod 600 "$body_file" "$out_file"
  printf '{"token":"%s"}' "$source_token" > "$body_file"
  http=$(curl -s --connect-timeout 5 --max-time 10 -X POST \
    "https://token.svc.$(osc_env).osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    --data @"$body_file" \
    -o "$out_file" -w '%{http_code}' 2>/dev/null) || http="${http:-000}"
  if [ "$http" = "200" ]; then
    FRESH_PAT=$(json_field "$out_file" token)
  fi
  if [ -z "$FRESH_PAT" ]; then
    code=$(json_field "$out_file" code)
    echo "[CONFIG] WARNING: runner token exchange failed (HTTP ${http:-000}, code=${code:-none}); using the original token" >&2
  fi
  rm -f "$body_file" "$out_file"
  return 0
}

# The token the runner uses for its own calls to the platform.
runner_token() {
  echo "${FRESH_PAT:-$OSC_ACCESS_TOKEN}"
}

# A named git credential is a workspace secret `user.gitcred.<name>`, the same credentials
# My Apps and My Jobs use. Prints the token; never logs it.
resolve_git_credential() {
  local name="$1"
  if ! [[ "$name" =~ ^[a-z0-9-]{1,40}$ ]]; then
    echo "Error: GIT_CREDENTIAL must be 1-40 lowercase letters, digits or hyphens" >&2
    return 1
  fi
  if [ -z "${OSC_ACCESS_TOKEN:-}" ]; then
    echo "Error: GIT_CREDENTIAL '$name' needs OSC_ACCESS_TOKEN to resolve it" >&2
    return 1
  fi
  refresh_access_token
  local body status
  body=$(mktemp)
  status=$(curl -s -o "$body" -w '%{http_code}' \
    "https://deploy.svc.$(osc_env).osaas.io/mytenantsecrets/user.gitcred.${name}" \
    -H "x-pat-jwt: Bearer $(runner_token | sed 's/^Bearer //')") || status=000
  if [ "$status" != "200" ]; then
    rm -f "$body"
    echo "Error: could not resolve git credential '$name' (HTTP $status)" >&2
    return 1
  fi
  jq -r '.value // empty' "$body"
  rm -f "$body"
}

is_commit_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

# Split a source URL into host, repository path and ref.
# Sets SRC_HOST (as given, may include user@), SRC_HOST_PUBLIC, SRC_REPO and SRC_REF.
parse_source_url() {
  local url="$1"
  SRC_REF=""
  SRC_HOST=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
  SRC_HOST_PUBLIC=$(echo "$SRC_HOST" | sed -E 's|^[^@]+@||')
  if [[ "$url" == *"#"* ]]; then
    SRC_REF="${url##*#}"
    url="${url%#*}"
  fi
  if [[ "$url" == *"/tree/"* ]]; then
    SRC_REF=$(echo "$url" | sed -E 's|.*/tree/||')
    SRC_REPO=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed -E 's|/tree/.*||')
  else
    SRC_REPO=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed 's|/$||')
  fi
  SRC_REPO="${SRC_REPO%.git}"
}

clone_from_git() {
  parse_source_url "$1"
  local sha=""
  local clone_opts=()
  if [ -n "$SRC_REF" ]; then
    if is_commit_sha "$SRC_REF"; then
      sha="$SRC_REF"
      echo "Cloning repository: $SRC_REPO (commit: $sha) from $SRC_HOST_PUBLIC"
    else
      clone_opts=(-b "$SRC_REF")
      echo "Cloning repository: $SRC_REPO (branch: $SRC_REF) from $SRC_HOST_PUBLIC"
    fi
  else
    echo "Cloning repository: $SRC_REPO from $SRC_HOST_PUBLIC"
  fi

  rm -rf "${WORK_ROOT:?}"/* "${WORK_ROOT:?}"/.[!.]* 2>/dev/null || true

  local git_token="${GIT_TOKEN:-$GITHUB_TOKEN}"
  if [ -z "$git_token" ] && [ -n "${GIT_CREDENTIAL:-}" ]; then
    git_token=$(resolve_git_credential "$GIT_CREDENTIAL")
    echo "Using git credential '$GIT_CREDENTIAL'"
  fi

  local public_url="https://${SRC_HOST_PUBLIC}/${SRC_REPO}.git"
  if [ -n "$git_token" ]; then
    echo "cloning https://***@${SRC_HOST_PUBLIC}/${SRC_REPO}.git"
    git clone "${clone_opts[@]}" "https://token:${git_token}@${SRC_HOST_PUBLIC}/${SRC_REPO}.git" "$WORK_ROOT"
  elif [ "$SRC_HOST" != "$SRC_HOST_PUBLIC" ]; then
    echo "cloning https://***@${SRC_HOST_PUBLIC}/${SRC_REPO}.git"
    git clone "${clone_opts[@]}" "https://${SRC_HOST}/${SRC_REPO}.git" "$WORK_ROOT"
  else
    echo "cloning ${public_url}"
    git clone "${clone_opts[@]}" "$public_url" "$WORK_ROOT"
  fi
  git -C "$WORK_ROOT" remote set-url origin "$public_url"

  if [ -n "$sha" ]; then
    # `git clone -b` accepts branches and tags only; check the commit out explicitly.
    if ! git -C "$WORK_ROOT" -c advice.detachedHead=false checkout -q "$sha" 2>/dev/null; then
      echo "Error: commit $sha not found in $SRC_REPO" >&2
      exit 1
    fi
    echo "Checked out commit $(git -C "$WORK_ROOT" rev-parse HEAD)"
  fi
}

# Run a command without the runner's credentials in its environment.
without_secrets() {
  local unset_args=()
  local var
  for var in "${RUNNER_SECRET_VARS[@]}"; do
    unset_args+=(-u "$var")
  done
  env "${unset_args[@]}" "$@"
}

install_dependencies() {
  if [ -f "pyproject.toml" ]; then
    echo "Installing with pip (pyproject.toml)..."
    without_secrets pip install --no-cache-dir .
  elif [ -f "requirements.txt" ]; then
    echo "Installing requirements.txt..."
    without_secrets pip install --no-cache-dir -r requirements.txt
  elif [ -f "setup.py" ]; then
    echo "Installing via setup.py..."
    without_secrets pip install --no-cache-dir .
  else
    echo "Warning: No requirements.txt, pyproject.toml, or setup.py found"
  fi

  if [ -f "setup.sh" ]; then
    chmod +x setup.sh
    without_secrets ./setup.sh
  fi
}

# Load environment variables from the OSC parameter store, if one is configured.
load_config() {
  [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ] || return 0
  # Keep the original runner token available to the job, so it can exchange it again later.
  export OSC_REFRESH_TOKEN="${OSC_REFRESH_TOKEN:-$OSC_ACCESS_TOKEN}"
  refresh_access_token
  local env_name output status=0 exports count
  env_name=$(osc_env)
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  output=$(OSC_ACCESS_TOKEN="$(runner_token)" npx -y @osaas/cli@latest web config-to-env --env "$env_name" "$CONFIG_SVC" 2>&1) || status=$?
  if [ $status -ne 0 ]; then
    echo "[CONFIG] ERROR: Failed to load config (exit $status): $output" >&2
    return 0
  fi
  exports=$(echo "$output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=" || true)
  if [ -n "$exports" ]; then
    eval "$exports"
    count=$(echo "$exports" | wc -l | tr -d ' ')
    echo "[CONFIG] Loaded $count environment variable(s)"
  fi
}

run_worker() {
  if [ -n "${WORKER_CMD:-}" ]; then
    echo "Running: $WORKER_CMD"
    exec sh -c "$WORKER_CMD"
  elif [ -f "job.py" ]; then
    echo "Running: python job.py"
    exec python job.py
  elif [ -f "main.py" ]; then
    echo "Running: python main.py"
    exec python main.py
  else
    echo "Error: No entry point found. Set WORKER_CMD or provide job.py / main.py"
    exit 1
  fi
}

main() {
  if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
    echo "Error: SOURCE_URL or GITHUB_URL environment variable is required"
    exit 1
  fi
  local url="${SOURCE_URL:-$GITHUB_URL}"
  if [[ "$url" != https://* ]]; then
    echo "Error: Unsupported URL scheme. Use an HTTPS git URL."
    exit 1
  fi

  clone_from_git "$url"

  cd "$WORK_ROOT"
  if [ -n "${SUB_PATH:-}" ]; then
    if [ ! -d "$WORK_ROOT/$SUB_PATH" ]; then
      echo "Error: SUB_PATH directory '$WORK_ROOT/$SUB_PATH' does not exist"
      exit 1
    fi
    echo "Using SUB_PATH: $SUB_PATH"
    cd "$WORK_ROOT/$SUB_PATH"
  fi

  install_dependencies
  load_config
  run_worker
}

# Sourcing the script (as the tests do) only defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
