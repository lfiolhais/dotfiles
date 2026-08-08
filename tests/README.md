# Test harness


> **AI agents (including Claude Code) must not run any of these.** Testing and
> applying are human-only steps.

## `check.py` — host harness

```sh
python3 tests/check.py
```

Runs on macOS and Linux. It:

- renders the whole source with `chezmoi archive` (templates + age decryption +
  ignores all work);
- confirms ignored docs/secrets (`CLAUDE.md`, `LICENSE`, `key.txt.age`) stay out
  of the target;
- lints every `run_*` script — `bash -n` and `shellcheck --severity=error` are
  hard failures, `--severity=warning` is advisory. It is **OS-aware**: a script
  gated off for the current OS renders empty and is skipped (cross-OS coverage
  comes from `linux.py`);
- checks the Brewfile (skipped if `brew` is absent, e.g. on Linux);
- lints this repo's Python with `ruff` (rules in `tests/pyproject.toml`) — the
  harness itself, plus the deployed `git-wt-*` commands under `dot_local/`, which
  are passed by path with an explicit `--config` because they sit outside
  `tests/` and the entry points have no `.py` extension. The `gitwt` library
  modules are globbed rather than listed, so splitting one in two cannot drop it
  out of the lint;
- imports that library and runs each command's `--help` under every `python3` it
  finds on the host (`which python3`, `/usr/bin/python3`, and the interpreter
  running the harness, deduplicated). `ruff` never executes anything, so this is
  what catches an import cycle, a stale call, or a construct too new for the
  oldest supported interpreter — 3.9, on both a fresh macOS and the RHEL
  rebuilds. `--help` makes argparse exit before any git command runs, so nothing
  is written; a host with no `python3` at all is a warning, not a failure;
- prints a `chezmoi apply --dry-run` diff to eyeball.

Exit code is `0` only when all hard checks pass.

## `linux.py` — Docker matrix

```sh
python3 tests/linux.py          # render + lint all four targets
python3 tests/linux.py --full   # also run the real bootstrap in-container
```

Runs from any machine with Docker. For each `distro × sudo`
target — every distro in `IMAGES` (Ubuntu, Fedora, and the RHEL-family server
rebuilds Rocky Linux and AlmaLinux) crossed with sudo/no-sudo — it spins up a
throwaway container (`tests/docker/entrypoint.sh`).



## `pre-push` git hook

`tests/githooks/pre-push` runs `check.py` and blocks a push that updates
`refs/heads/main` if the harness fails. It is **checking-only** and separate
from `check.py` itself (which never touches git). Enable it once per clone —
`core.hooksPath` is a local git setting and is not itself version-controlled:

```sh
git config core.hooksPath tests/githooks
```
