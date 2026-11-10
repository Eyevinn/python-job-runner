# Python Job Runner

A one-shot Python job container for OSC. On each invocation it clones a Git repository,
installs dependencies, and executes a script — then exits. Scheduling is handled externally
by the OSC platform (cron trigger), not inside the container.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `SOURCE_URL` | Yes | HTTPS URL of the Git repository to clone (supports `#branch` and `/tree/branch` fragments) |
| `WORKER_CMD` | No | Shell command to run instead of the default entry point |
| `SUB_PATH` | No | Subdirectory within the cloned repo to use as the working directory |
| `GIT_TOKEN` / `GITHUB_TOKEN` | No | Personal access token for private repositories |
| `CONFIG_SVC` | No | OSC config service name — exports its key/value pairs as env vars before the job runs |
| `OSC_ACCESS_TOKEN` | No | OSC PAT required when `CONFIG_SVC` is set |
| `OSC_REFRESH_TOKEN` | No | Set by the runner to the original `OSC_ACCESS_TOKEN` when `CONFIG_SVC` is set. Exchange it for a fresh 1h token by POSTing `{"token": os.environ["OSC_REFRESH_TOKEN"]}` to `https://token.svc.<env>.osaas.io/runner-token/refresh` and reading `.token`. A parameter store key with the same name overrides it. |
| `OSC_ENV` | No | OSC environment (`prod`/`dev`); auto-detected from `OSC_MCP_URL` if unset |

## Entry point resolution

The runner looks for an entry point in this order:

1. `WORKER_CMD` — if set, executes it as a shell command
2. `job.py` — executed with `python job.py`
3. `main.py` — executed with `python main.py`

If none are found the container exits with an error.

## Dependency installation

Detected automatically in this order: `pyproject.toml` → `requirements.txt` → `setup.py`.
A `setup.sh` in the repo root is executed after pip install if present.

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
