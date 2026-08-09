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
- checks the Brewfile against `.chezmoidata/packages.toml`, the manifest that maps
  each formula onto its Linux equivalents. Every `brew "…"` / `uv "…"` entry must
  be mapped in `[packages]` (by its `brew` field) or listed in `[skip]` with a
  reason, or this fails — it is what stops a `brew bundle dump` on
  the Mac from silently widening the macOS/Linux gap. It also fails on a manifest
  entry naming a formula the Brewfile no longer has, an entry that names no target
  at all (so it would install nowhere), a misspelled field name, and two entries
  claiming the same `mise` tool (which would render a duplicate key into the
  generated mise config). Pure text, so unlike the check above it runs on Linux
  too;
- lints this repo's Python with `ruff` (rules in `tests/pyproject.toml`) — the
  harness itself, plus the deployed `git-wt-*` commands under `dot_local/`, which
  are passed by path with an explicit `--config` because they sit outside
  `tests/` and the entry points have no `.py` extension. The `gitwt` library
  modules are globbed rather than listed, so splitting one in two cannot drop it
  out of the lint;
- imports the deployed `gitwt` library and runs each command's `--help` under
  every `python3` it finds on the host (`which python3`, `/usr/bin/python3`, and
  the interpreter running the harness, deduplicated). `ruff` never executes anything, so this is
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

Besides rendering and linting, the entrypoint **asks the package manager whether
every name the manifest targets at that distro actually resolves** (`apt-cache
show` / `dnf info`), installing nothing. This is what makes the strict, one
transaction install in the `01` bootstrap script safe: a name that does not exist
would otherwise abort the whole bootstrap on a real machine. It runs on the sudo
target of each distro only — the names do not vary with the sudo flag, and the
no-sudo profile's mise names are exercised by `mise install` under `--full`. A
failure lists the offending names; fix them in `.chezmoidata/packages.toml`, or
drop that distro's field so the tool is skipped there.

Note that `--full` on the sudo targets installs the full toolchain, including TeX
— expect it to pull several gigabytes and run for a long time.

**Set `GITHUB_TOKEN` before a `--full` run.** The no-sudo profile installs its
toolchain with mise, which resolves most tools from GitHub releases; without a
token that is 60 API requests an hour for the whole host, and four no-sudo
targets exhaust it. `linux.py` forwards the variable into each container when the
environment has it. The symptom without one is
`mise WARN GitHub rate limit exceeded` followed by
`mise ERROR Failed to install tools`, and it resets on the hour.

## `packages.py` — add, remove, and look up packages

```sh
python3 tests/packages.py search ripgrep
python3 tests/packages.py add ripgrep --brew ripgrep --apt ripgrep --fedora ripgrep
python3 tests/packages.py skip dockutil "macOS Dock only"
python3 tests/packages.py remove gurk
```

Not a test — repo tooling that happens to live here because `tests/` is
chezmoi-ignored, so nothing in it ever reaches `$HOME`. `search` reuses this
directory's `IMAGES` and Docker driver to ask each distro's real repositories
what a tool is called there (plus `brew search` and `mise registry` on the host),
and prints the `add` command to run. The other three need no Docker, and each
re-parses the manifest afterwards, refusing to write anything that is not valid
TOML: `add` writes the manifest entry and the Brewfile line; `skip` records a
formula as not installed on Linux, dropping any `[packages]` entry for it but
**leaving the Brewfile alone** so macOS keeps it; `remove` takes it out of both,
for a tool you want gone everywhere.

The full workflow, including manual name lookups, is in the Packages section of
the top-level [README](../README.md).

## `macos.py` — Lume VM matrix

```sh
python3 tests/macos.py               # render + lint the darwin scripts in a macOS VM
python3 tests/macos.py --only tahoe  # one image only (each is a large pull)
python3 tests/macos.py --keep        # reuse/keep the VM instead of re-pulling it
python3 tests/macos.py --full        # also run the real bootstrap in-guest
```

The macOS analogue of `linux.py`. Docker can't run macOS, so this uses
[Lume](https://cua.ai/docs/lume) — an MIT-licensed CLI over Apple's
Virtualization framework — to boot a throwaway macOS VM per image in `IMAGES`
(Tahoe, Sequoia), shares the repo read-only, and over `lume ssh` runs
`tests/lume/entrypoint.sh` — which fetches chezmoi/shellcheck/age as static
arm64 binaries into `~/.local/bin` (no package manager, no sudo), generates a
fresh age key, renders with `--exclude encrypted`, and lints the darwin
bootstrap scripts. `--full` additionally runs the real `chezmoi apply` (heavy:
Homebrew bundle, `defaults write`, dockutil). Lume is the only host dependency;
it ships its own `lume ssh` with the images' default `lume`/`lume` credentials,
so there is no ssh password plumbing:

```sh
/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"
```

The VM is pulled fresh and deleted after each run (including a pre-run delete
that clears a VM left behind by an interrupted run), so the host is never
touched. That means every run re-downloads the image, so `--keep` reuses an
existing `chezmoi-test-<image>` VM and leaves it stopped instead of deleting it
— much faster to iterate with, at the cost of the throwaway guarantee. Apple
Silicon only, and each image is a large sparse disk — budget well over 50 GB
free. Image tags live in `IMAGES` at the top of `macos.py`;
they resolve against Lume's default registry/organization, `ghcr.io/trycua`.

### Notes (Lume 0.5.1, checked 2026-08-07)

- **Sequoia images cannot be pulled.** Every `macos-sequoia-*` tag
  (`cua:latest`, `cua:15.3`, `vanilla:latest`, `vanilla:15.2`) ships its disk as
  generic `application/vnd.oci.image.layer.v1.tar` layers, which Lume 0.5.1 does
  not reassemble: it logs `Skipping unsupported cached layer media type` for
  every layer, finds `0 lz4 disk parts`, and then fails with the misleading
  `Virtual machine not found: <name>`. Only the Tahoe images use Lume's native
  `vnd.trycua.lume.disk.v1` packaging, so `IMAGES` is Tahoe-only for now.
- **Run this from your own terminal, not from an automation context.** Driven
  from a non-GUI session, `lume run` crashed in Apple's Virtualization framework
  (`_VZVNCServer _setupVirtualMachineAccessor` → `assertion_trap()`), and every
  probe of the guest's IP failed — `lume get` reported `ssh=no` on a guest whose
  sshd was in fact running and reachable from a normal shell. That pattern
  matches macOS's Local Network privacy gate. Run by hand, the published image
  boots repeatedly, has Remote Login enabled, and `lume ssh` connects with no
  credentials needed.

## `pre-push` git hook

`tests/githooks/pre-push` runs `check.py` and blocks a push that updates
`refs/heads/main` if the harness fails. It is **checking-only** and separate
from `check.py` itself (which never touches git). Enable it once per clone —
`core.hooksPath` is a local git setting and is not itself version-controlled:

```sh
git config core.hooksPath tests/githooks
```
