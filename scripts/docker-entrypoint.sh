#!/bin/bash
set -e

if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "Error: SOURCE_URL or GITHUB_URL environment variable is required"
  exit 1
fi

URL="${SOURCE_URL:-$GITHUB_URL}"

clone_from_git() {
  local url="$1"
  local branch=""
  local repo_path=""

  local git_host=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
  local git_host_public=$(echo "$git_host" | sed -E 's|^[^@]+@||')

  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi

  if [[ "$url" == *"/tree/"* ]]; then
    branch=$(echo "$url" | sed -E 's|.*/tree/||')
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed -E 's|/tree/.*||')
  else
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed 's|/$||')
  fi

  if [ -n "$branch" ]; then
    echo "Cloning repository: $repo_path (branch: $branch) from $git_host_public"
  else
    echo "Cloning repository: $repo_path from $git_host_public"
  fi

  rm -rf /usercontent/* /usercontent/.[!.]*

  local clone_opts=""
  if [ -n "$branch" ]; then
    clone_opts="-b $branch"
  fi

  local git_token="${GIT_TOKEN:-$GITHUB_TOKEN}"

  if [ -n "$git_token" ]; then
    echo "cloning https://***@${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://token:${git_token}@${git_host_public}/${repo_path}.git" /usercontent
  elif [ "$git_host" != "$git_host_public" ]; then
    echo "cloning https://***@${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://${git_host}/${repo_path}.git" /usercontent
  else
    echo "cloning https://${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://${git_host_public}/${repo_path}.git" /usercontent
  fi

  git -C /usercontent remote set-url origin "https://${git_host_public}/${repo_path}.git"
}

if [[ "$URL" == https://* ]]; then
  clone_from_git "$URL"
else
  echo "Error: Unsupported URL scheme. Use an HTTPS git URL."
  exit 1
fi

cd /usercontent

if [ -n "${SUB_PATH:-}" ]; then
  WORK_DIR="/usercontent/$SUB_PATH"
  if [ ! -d "$WORK_DIR" ]; then
    echo "Error: SUB_PATH directory '$WORK_DIR' does not exist"
    exit 1
  fi
  echo "Using SUB_PATH: $SUB_PATH"
  cd "$WORK_DIR"
fi

# BEGIN CONFIG LOAD
# Load environment variables from OSC config service if configured
if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
    _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    OSC_ENV=${_extracted:-prod}
  fi
  # Keep the original runner refresh token available to the job.
  export OSC_REFRESH_TOKEN="${OSC_REFRESH_TOKEN:-$OSC_ACCESS_TOKEN}"
  # Exchange the refresh token for a fresh 1h PAT. The fresh PAT is used only
  # for the config load below; the job keeps its original OSC_ACCESS_TOKEN.
  # Every step is guarded so that set -e can never end the container here.
  FRESH_PAT=""
  REFRESH_HTTP="000"
  REFRESH_CODE=""
  refresh_body_file=$(mktemp)
  refresh_out_file=$(mktemp)
  chmod 600 "$refresh_body_file" "$refresh_out_file"
  printf '{"token":"%s"}' "$OSC_REFRESH_TOKEN" > "$refresh_body_file"
  REFRESH_HTTP=$(curl -s --connect-timeout 5 --max-time 10 -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "Content-Type: application/json" \
    --data @"$refresh_body_file" \
    -o "$refresh_out_file" -w '%{http_code}' 2>/dev/null) || REFRESH_HTTP="${REFRESH_HTTP:-000}"
  # jq is not installed in this image; parse with node (empty on any failure).
  json_field() {
    node -e 'try{const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=o[process.argv[2]];if(typeof v==="string")process.stdout.write(v)}catch(e){}' "$1" "$2" 2>/dev/null || true
  }
  if [ "$REFRESH_HTTP" = "200" ]; then
    FRESH_PAT=$(json_field "$refresh_out_file" token)
  fi
  if [ -z "$FRESH_PAT" ]; then
    REFRESH_CODE=$(json_field "$refresh_out_file" code)
    echo "[CONFIG] WARNING: runner token exchange failed (HTTP ${REFRESH_HTTP:-000}, code=${REFRESH_CODE:-none}); using the original token" >&2
  fi
  rm -f "$refresh_body_file" "$refresh_out_file"
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  config_env_output=$(OSC_ACCESS_TOKEN="${FRESH_PAT:-$OSC_ACCESS_TOKEN}" npx -y @osaas/cli@latest web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" 2>&1)
  config_exit=$?
  if [ $config_exit -eq 0 ]; then
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=")
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_env_output" >&2
  fi
fi

# END CONFIG LOAD

# Install Python dependencies
if [ -f "pyproject.toml" ]; then
  echo "Installing with pip (pyproject.toml)..."
  pip install --no-cache-dir .
elif [ -f "requirements.txt" ]; then
  echo "Installing requirements.txt..."
  pip install --no-cache-dir -r requirements.txt
elif [ -f "setup.py" ]; then
  echo "Installing via setup.py..."
  pip install --no-cache-dir .
else
  echo "Warning: No requirements.txt, pyproject.toml, or setup.py found"
fi

# Run setup script if present
if [ -f "setup.sh" ]; then
  chmod +x setup.sh
  ./setup.sh
fi

# Execute the job — WORKER_CMD overrides, otherwise run main.py / job.py
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
