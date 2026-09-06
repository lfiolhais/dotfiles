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
  chezmoi skips an empty `run_` script. `bash tests/render-matrix.sh` renders
  every template for all three profiles and parses the output; run it before
  claiming a template works. It is read-only and takes seconds.
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
| `private_dot_config/khard/work/default/` | the `khard` wrapper, via `chezmoi add` | one age-encrypted vCard per contact |
| `~/.config/aerc/filters/colorize`, `wrap` | `run_onchange_…-09` compiles them | the C sources are what this repo tracks; a built filter is one architecture's |

The manifest's field set is `brew`, `apt`, `fedora`, `el`, `mise`, `mise_exe`,
`repo`, `note`; `tests/check.py` fails on any other field name. The distro
dispatch that maps a machine onto the `apt`/`fedora`/`el` columns lives once, in
`.chezmoitemplates/linux-target`, and is read by both bootstrap scripts and the
harness.

## Where things are

- `dot_local/bin/` — the deployed commands, `0755` via `executable_`:
  `git-wt-clone`, `git-wt-add`, `chezmoi-packages`, `cask-updates`, `mount-nas`.
  The `git-` prefix is what makes git dispatch the first two as subcommands.
  `cask-updates`, `mount-nas` and `chezmoi-packages` are chezmoi-ignored off
  darwin — the first two are macOS-only, and `chezmoi-packages` runs through uv,
  which is a Homebrew and Fedora package only.
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
Keychain has its password), `Outcome`, `flush()`, and `sync()` over them.
`unmount()` takes `force`, and only a caller that has established the server is
gone may pass it -- `sync()` does, `cmd_unmount` does so only for a share that
does not answer or when asked. It is both facade
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

The `run_` scripts at the repo root execute in prefix order on apply -- `ls
run_*` is the list. `README.md` has the table of what each one does to the
machine; what matters when editing them:

- Darwin-only scripts (`setup-xcode-cli`, `01-…-darwin`, `02`, `03`, `07`, `08`)
  are wrapped so they render empty on Linux. `04` branches per OS and profile;
  `09` runs everywhere.
- `run_once_` is tracked by content hash, so editing an already-run script
  re-runs it on the next apply. Keep them idempotent.
- `07-setup-nas` and `09-build-aerc-filters` are `run_onchange_` and each embeds
  a sha256 of the file it depends on in a comment. For `07` that is the plist,
  because launchd caches a job's definition at bootstrap and reads an edited
  plist only on a fresh one; for `09` it is the two C sources, so an edit to
  either rebuilds the filter. Leave those digest lines in place.
- `06-setup-mail` only prints instructions. It is safe to render and read with
  `chezmoi execute-template`.
- `01-…-darwin` splits `brew bundle` in two, because the halves fail for
  different reasons: everything except the App Store first, exiting non-zero if
  it fails so chezmoi does not record the script, and the `mas` entries after,
  reporting a failure without stopping the apply. `brew bundle install` has no
  per-type filter, so the split is a filtered Brewfile on stdin.
- `04-setup-fish` and `08-setup-ssh` both block on a prompt -- the account
  password and each key's passphrase. Each announces it first; `08` prints the
  command instead when stdin is not a terminal.

## The harness

`tests/check.py` renders the source with `chezmoi archive`, confirms `CLAUDE.md`,
`LICENSE`, `key.txt.age` and `tests` stay out of the target, lints every `run_`
script with `bash -n` and shellcheck, lints the deployed shell that is not a
`run_` script, parses every fish file with `fish -n`, hands the rendered ssh
config to `ssh -G` and the rendered gitconfig to `git config --list`, refuses a
compiled binary or a program-written file anywhere in the source, checks the
Brewfile against the manifest, lints this repo's Python with ruff, imports
`caskupd`/`gitwt`/`linux_distros`/`mountnas` and runs the four stdlib entry
points' `--help` under each `python3` on the host, runs the `mount-nas` unit
tests, exercises `chezmoi-packages` through `uv run --script`, and prints a
dry-run diff.

Four of those lists are hand-maintained in `tests/check.py` and a new file has to
be added to the right one: `SHELL_FILES` for deployed shell outside a `run_`
script, `DEPLOYED_ENTRY_POINTS` for a new command in `dot_local/bin/`,
`BINARY_MAGIC` for another executable format, and `GENERATED_NAMES` for another
file a program writes. Everything else is globbed -- the library modules, and
every fish file under `private_dot_config/private_fish/` -- so splitting one in
two keeps it covered.

Ruff covers `tests/` plus everything in `dot_local/lib/python/` and every entry
point in `dot_local/bin/`.

`tests/render-matrix.sh` is the fast pre-check: it renders every template for
darwin, linux-with-sudo and linux-without-sudo and parses the output. chezmoi
takes `.chezmoi.os` from the machine it runs on, so it rewrites that to a
`.fakeos` data variable -- which is why it proves the branch renders and parses,
and nothing about that machine's packages. `tests/linux.py` is the authority
there.

`tests/linux.py` renders and lints every distro crossed with sudo/no-sudo —
eight targets, from the four images in `linux_distros.IMAGES`. `tests/macos.py`
does the same in Lume VMs. `tests/nasprobe.py` is the one test that talks to
something real.

The user runs these. Do not. `tests/render-matrix.sh` is the exception: it is
read-only, runs no script and touches no `$HOME`.

## Reviewing this repo

`.claude/skills/dotfiles-review/` is the order to work in, and
`.claude/agents/` holds the two reviewers it calls for:
`dotfiles-drift-checker` (haiku, cheap, compares the lists this repo keeps in
more than one place) and `dotfiles-deploy-auditor` (sonnet, the expensive pass
that asks what fails on a machine where this has just been applied).

A defect that changes behaviour goes in `TODO.md` for the user to approve. A
comment, a document or a claim that disagrees with the system is corrected in
place, because that is not a behaviour change.

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
- A command a program writes -- a compiled filter, a cache, an editor's state --
  is not tracked. Track what it is built from and build it in a `run_onchange_`
  script; `tests/check.py` fails on a binary or a program-written name anywhere
  in the source.
- A file that names a path, an option or a prefix that only one OS has is a
  template, gated on `.chezmoi.os`. `UseKeychain`, `/opt/homebrew`, and a home
  directory that is not `/Users/…` are the three that keep coming back.
- Documentation for a person goes in `README.md`. This file is not documentation
  and is never cited to a user.
