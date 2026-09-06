# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

`README.md` is the documentation. It covers installing on a new machine,
everyday chezmoi use, packages, casks, the NAS, contacts and mail, and it is
written for a person. Read it for anything a user would do; this file covers
only what an agent needs on top of it, and deliberately does not restate it.

## Hard rules

- Never run `chezmoi apply`, `chezmoi init`, `chezmoi update`, or anything under
  `tests/`. Applying has real side effects — `chsh`, a long list of
  `defaults write` calls, Homebrew, dockutil, launchctl, mounting shares.
  Testing and applying are the
  user's steps. `chezmoi diff`, `status`, `cat`, `execute-template`,
  `source-path` and `archive` are read-only and safe.
- Never edit the deployed copy under `$HOME`. This repository is the source
  state; the next apply overwrites the target. Edit here.
- A change for Linux must not alter the macOS render. Linux logic lives in
  `{{ if eq .chezmoi.os "linux" }}` blocks that render empty on darwin, and
  chezmoi skips an empty `run_` script. Check both renders with
  `chezmoi execute-template` before claiming a template works.
- Python here must pass `ruff check` and `ruff format` with the config in
  `tests/pyproject.toml`. Google-style docstrings with `Args:`/`Returns:` are
  mandatory on public functions, because `D` and `DOC` are enabled under
  `preview`.

## What is generated, and what is authored

Editing a generated file by hand is the most common way to break this repo,
because the change survives review and disappears at the next write.

| file | written by | so |
| --- | --- | --- |
| `private_dot_config/Brewfile` | `brew bundle dump` | never hand-edit; `chezmoi-packages dump` is the only path |
| `.chezmoidata/packages.toml` | `chezpkg_manifest.py` | never hand-edit; every write rewrites it whole, and hand-written comments are lost — use `note` |
| `private_dot_config/mise/config.toml.tmpl` | rendered from the manifest | change the manifest, not this |
| `private_dot_config/khard/work/exact_default/` | `chezmoi add` | one age-encrypted vCard per contact |

The manifest's field set is `brew`, `apt`, `fedora`, `el`, `mise`, `mise_exe`,
`repo`, `note`; `tests/check.py` fails on any other field name. The distro
dispatch that maps a machine onto the `apt`/`fedora`/`el` columns lives once, in
`.chezmoitemplates/linux-target`, and is read by both bootstrap scripts and the
harness.

## Where things are

- `dot_local/bin/` — the deployed commands, `0755` via `executable_`:
  `git-wt-clone`, `git-wt-add`, `chezmoi-packages`, `cask-updates`, `mount-nas`.
  The `git-` prefix is what makes git dispatch the first two as subcommands.
  `cask-updates` and `mount-nas` are chezmoi-ignored off darwin.
- `dot_local/lib/python/` — the libraries those commands share. Deployed rather
  than kept in `tests/`, because `chezmoi-packages` runs from `~/.local/bin`,
  where `tests/` does not exist.
- `Library/LaunchAgents/xyz.botasal.mount-nas.plist.tmpl` — the only LaunchAgent.
  A template because `ProgramArguments` needs the home directory, and without a
  `dot_` prefix because `~/Library` is not hidden.
- `.chezmoitemplates/` — `linux-target` and `linux-packages`, shared by the
  bootstrap scripts and the Docker harness so they cannot disagree.
- `private_dot_config/` — per-app configs. `aerospace`, `linearmouse`,
  `leaderkey` and `Brewfile` are darwin-only; `mise` is linux-no-sudo-only. The
  gating is in the templated `.chezmoiignore`.
- `tests/` — the harness. Chezmoi-ignored, so it never deploys.

## The Python libraries

Four families, each a facade over modules that import strictly downwards, which
is what keeps them free of cycles. Each entry point imports its facade and
nothing else, so a split inside a family never touches the command.

`gitwt`, behind `git-wt-clone` and `git-wt-add`:

| module | holds | imports |
| --- | --- | --- |
| `gitwt_git.py` | constants, `GitWtError`, `git()` | nothing local |
| `gitwt_refkind.py` | `RefKind` (what a ref names) | `gitwt_git`; `gitwt_repo` for typing only |
| `gitwt_repo.py` | `Repo` (layout discovery, clone, fetch) | `gitwt_git` |
| `gitwt_plan.py` | `Plan` (folder name + `worktree add` argv) | git, refkind, repo |
| `gitwt_worktree.py` | `Worktree` (create, or reuse in place) | git, refkind, repo, plan |
| `gitwt.py` | `__all__`, nothing else | all of the above |

`chezpkg`, behind `chezmoi-packages`:

| module | holds | imports |
| --- | --- | --- |
| `chezpkg_run.py` | `PackagesError`, `run()`, `maybe()`, `have()` | nothing local |
| `chezpkg_source.py` | `Source` (the source dir and the two file paths) | run |
| `chezpkg_brew.py` | `Entry`, `Brewfile` (parse, dump, install, uninstall) | run |
| `chezpkg_manifest.py` | `Manifest` (read, save, problems) | run, brew |
| `chezpkg_search.py` | `Match`, `Search` (ask every platform, return it) | run, `linux_distros` |
| `chezpkg.py` | `__all__`, nothing else | all of the above |

`caskupd`, behind `cask-updates`:

| module | holds | imports |
| --- | --- | --- |
| `caskupd_app.py` | `App` (a cask's app: bundle id, updater kind), `EXEMPT` | `chezpkg_run` |
| `caskupd_sparkle.py` | `Sparkle` (the two keys: read, write, delete) | `chezpkg_run` |
| `caskupd.py` | `__all__`, nothing else | both above, `chezpkg_run` |

`mountnas.py`, behind `mount-nas`, is a family of one: `Share` (its URL, its
device column, whether the NAS answers, where it is mounted, whether the
Keychain has its password), `Outcome`, and `sync()` over them. It is both facade
and implementation because the surface is a single dataclass; the entry point
still imports from `mountnas` alone, so splitting it later changes nothing there.

`linux_distros.py` is not a family. It holds `IMAGES` and `TARGET_OF`, the Linux
target matrix, read by both `chezpkg_search` and `tests/linux.py` so that adding
a distro is one edit.

### Interpreter floors

`gitwt`, `caskupd`, `mountnas` and `linux_distros` are standard library only and
must stay Python 3.9-clean: a fresh Mac has Apple's 3.9 until Homebrew's lands,
and the RHEL rebuilds ship 3.9 as well. `tests/check.py` imports each of them
under every `python3` on the host, which is what catches a construct too new —
ruff cannot see that.

`chezpkg` is 3.11+, because uv supplies its interpreter. Writing TOML is the one
thing the standard library cannot do and Homebrew packages no writer for it, so
`chezmoi-packages` is a PEP 723 script run through uv, which supplies both
`tomlkit` and the interpreter. `tomlkit` is imported under a guard so that
importing the library needs nothing but the stdlib, which is how `tests/check.py`
reads the manifest under a plain interpreter.

`chezpkg_run` is the exception inside `chezpkg`: `caskupd` and `mountnas` import
it, so that module alone must stay stdlib-only and 3.9-clean.

`tests/check.py` itself needs 3.11 — it uses `enum.StrEnum`.

## Bootstrap scripts

Ten `run_` scripts execute in prefix order on apply. `README.md` has the table of
what each one does to the machine; what matters when editing them:

- Darwin-only scripts (`setup-xcode-cli`, `01-…-darwin`, `02`, `03`, `07`) are
  wrapped so they render empty on Linux. `04` branches per OS and profile.
- `run_once_` is tracked by content hash, so editing an already-run script
  re-runs it on the next apply. Keep them idempotent.
- `07-setup-nas` is `run_onchange_` and embeds the plist's sha256 in a comment,
  because launchd caches a job's definition at bootstrap and reads an edited
  plist only on a fresh one. Leave that digest line in place.
- `06-setup-mail` only prints instructions. It is safe to render and read with
  `chezmoi execute-template`.

## The harness

`tests/check.py` renders the source with `chezmoi archive`, confirms `CLAUDE.md`,
`LICENSE`, `key.txt.age` and `tests` stay out of the target, lints every `run_`
script with `bash -n` and shellcheck, checks the Brewfile against the manifest,
lints this repo's Python with ruff, imports `caskupd`/`gitwt`/`linux_distros`/
`mountnas` and runs the four stdlib entry points' `--help` under each `python3` on
the host, runs the `mount-nas` unit tests, exercises `chezmoi-packages` through
`uv run --script`, and prints a dry-run diff.

Ruff covers `tests/` plus everything in `dot_local/lib/python/` and every entry
point in `dot_local/bin/`. The library modules are globbed, so splitting one in
two keeps it covered; a new entry point has to be added to
`DEPLOYED_ENTRY_POINTS` in `tests/check.py` by hand.

`tests/linux.py` renders and lints every distro crossed with sudo/no-sudo —
eight targets, from the four images in `linux_distros.IMAGES`. `tests/macos.py`
does the same in Lume VMs. `tests/nasprobe.py` is the one test that talks to
something real.

The user runs these. Do not.

## Conventions when adding to this repo

- A new file gets its chezmoi prefixes applied by hand (`dot_`, `private_`,
  `executable_`, `encrypted_`, `exact_`, `.tmpl`), or by `chezmoi add`, which
  applies them.
- A new fish function is one file per function under
  `private_dot_config/private_fish/functions/`, named after the function, since
  fish autoloads by filename.
- A new deployed command goes in `dot_local/bin/` with `executable_`, imports a
  single facade from `dot_local/lib/python/`, and is added to
  `DEPLOYED_ENTRY_POINTS` in `tests/check.py`.
- Documentation for a person goes in `README.md`. This file is not documentation
  and is never cited to a user.
