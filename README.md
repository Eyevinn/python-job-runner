# Python Job Runner

A one-shot Python job container for OSC. On each invocation it clones a Git repository,
installs dependencies, and executes a script — then exits. Scheduling is handled externally
by the OSC platform (cron trigger), not inside the container.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `SOURCE_URL` | Yes | HTTPS URL of the Git repository to clone. Supports `#branch`, `#tag` and `/tree/branch`; a full commit SHA as the fragment (`#<40-hex>`) pins the run to that commit |
| `WORKER_CMD` | No | Shell command to run instead of the default entry point |
| `SUB_PATH` | No | Subdirectory within the cloned repo to use as the working directory |
| `GIT_TOKEN` / `GITHUB_TOKEN` | No | Personal access token for private repositories |
| `GIT_CREDENTIAL` | No | Name of a git credential registered in the OSC workspace (`user.gitcred.<name>`), used when no token is given. Needs `OSC_ACCESS_TOKEN` |
| `CONFIG_SVC` | No | OSC config service name — exports its key/value pairs as env vars before the job runs |
| `OSC_ACCESS_TOKEN` | No | OSC token, required when `CONFIG_SVC` or `GIT_CREDENTIAL` is set |
| `OSC_REFRESH_TOKEN` | No | Set by the runner to the original `OSC_ACCESS_TOKEN` when `CONFIG_SVC` is set. Exchange it for a fresh 1h token by POSTing `{"token": os.environ["OSC_REFRESH_TOKEN"]}` to `https://token.svc.<env>.osaas.io/runner-token/refresh` and reading `.token`. A parameter store key with the same name overrides it. |
| `OSC_ENV` | No | OSC environment (`prod`/`dev`); auto-detected from `OSC_MCP_URL` if unset |

## Entry point resolution

The runner looks for an entry point in this order:

1. `WORKER_CMD` — if set, executes it as a shell command
2. `job.py` — executed with `python job.py`
3. `main.py` — executed with `python main.py`

If none are found the container exits with an error.

## Run order and secrets

1. Clone the source, using `GIT_TOKEN`/`GITHUB_TOKEN` or the named `GIT_CREDENTIAL`, and check out the pinned commit if one is given.
2. Install dependencies, detected in this order: `pyproject.toml` → `requirements.txt` → `setup.py`,
   then run `setup.sh` from the repo root if present. These steps run **without** `OSC_ACCESS_TOKEN`,
   `GIT_TOKEN` or `GITHUB_TOKEN` in their environment, and before the parameter store is loaded.
3. Load the parameter store (`CONFIG_SVC`) into the environment and run the worker.

Code that runs during installation (build backends, `setup.py`, `setup.sh`) therefore never sees
parameter-store values or the runner's credentials. A named credential is resolved into the clone
only and is not exported to the worker.

## Tests

```bash
bash tests/entrypoint_test.sh
```

## Local usage

```bash
docker build -t python-job-runner .
docker run --rm \
  -e SOURCE_URL=https://github.com/your-org/your-job-repo \
  -e WORKER_CMD="python myjob.py --date 2026-01-01" \
  python-job-runner
```

## License

MIT
