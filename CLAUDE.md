# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo is

This is the **chezmoi source directory** for a personal dotfiles setup.
Files here are *source state*; chezmoi renders them into the *target state*
under `$HOME`. Never edit the deployed dotfiles under `$HOME` directly — edit
the source here and apply, or the next `chezmoi apply` will overwrite your
change.

The primary target is macOS (`darwin`); **Linux is also supported** in two
profiles selected at `chezmoi init` time by the `sudo` prompt (see
`.chezmoi.toml.tmpl`):

- **Linux + sudo** (Debian/Ubuntu/Pop!_OS, Fedora, and RHEL rebuilds like
  Rocky/AlmaLinux/CentOS) — the CLI toolchain is installed with the native
  package manager (apt or dnf, with EPEL/CRB enabled on RHEL rebuilds) plus each
  tool's official repo/installer for the gaps (`gh`, `starship`).
- **Linux + no-sudo** — the CLI toolchain comes from **mise** (rootless, under
  `~/.local`), configured in `private_dot_config/mise/config.toml`.

Everything is CLI/TUI-only on Linux; macOS-only GUI configs (aerospace,
linearmouse, leaderkey) and the `Brewfile` never deploy off darwin (see the
templated `.chezmoiignore`). **Changes for Linux must never break the macOS
render** — Linux logic lives in `{{ if eq .chezmoi.os "linux" }}` blocks that
render empty on darwin, and the two guarded fish additions are no-ops on macOS.

## Core workflow

```sh
chezmoi diff                 # preview what applying the source would change in $HOME
chezmoi apply -v             # render source -> $HOME (runs pending run_ scripts)
chezmoi status               # show files that differ between source and target
chezmoi cd                   # open a shell in this source directory
```

Two ways changes flow:

- **Source -> target**: edit a file here, then `chezmoi apply`.
- **Target -> source** (when you changed a live config by hand): `chezmoi
  re-add` (updates existing source files from their target) or `chezmoi add
  ~/path` (tracks a new file, auto-applying naming conventions).

There is no build/lint/test suite. "Testing" a change means `chezmoi diff` then
`chezmoi apply -v` on a real macOS machine.

## File naming conventions (chezmoi)

Source filenames encode target attributes — the prefixes are transformations,
not part of the name:

- `dot_foo` -> `.foo`
- `private_` -> target file gets `chmod 600` (e.g. `private_dot_ssh/` ->
  `~/.ssh`)
- `encrypted_` -> stored age-encrypted here, decrypted on apply
- `run_once_` -> script run once (tracked by content hash); `run_onchange_` ->
  re-run when its content changes
- `before_` / `after_` -> run before/after the file-application phase
- `.tmpl` -> rendered as a Go template

So `private_dot_config/private_fish/config.fish` is the source for
`~/.config/fish/config.fish`. When creating files, apply these prefixes
yourself rather than fighting chezmoi.

## Encryption (age)

Encrypted secrets use age (config in `.chezmoi.toml.tmpl`; identity at
`~/.config/chezmoi/key.txt`, recipient key inline). Encrypted files:
`key.txt.age` (the master key itself, bootstrapped by
`run_onchange_before_decrypt-private-key.sh.tmpl` and excluded from apply via
`.chezmoiignore`), `private_dot_config/encrypted_isyncrc.age`,
`encrypted_dot_notmuch-config.age`.

- Edit an encrypted file: `chezmoi edit ~/<target>` (chezmoi decrypts to a temp
  file and re-encrypts on save) — don't hand-edit the `.age` blob.
- IMAP/SMTP passwords are **not** in the repo; they live in the macOS Keychain
  (see the mail setup script).

## Bootstrap sequence (fresh machine)

On `chezmoi apply`, run scripts execute in prefix order:

1. `run_once_before_install-setup-xcode-cli.sh.tmpl` — (darwin) Xcode Command
   Line Tools + Rosetta 2
2. `run_onchange_before_decrypt-private-key.sh.tmpl` — decrypt the age key into
   `~/.config/chezmoi/key.txt`
3. `run_once_after_install-01-install-packages-darwin.sh.tmpl` — (darwin)
   install Homebrew, `brew bundle --file=~/.config/Brewfile`, rustup
3b. `-01-install-packages-linux.sh.tmpl` — (linux) sudo profile: native package
   manager chosen by distro *family* (via `.chezmoi.osRelease` `id`/`idLike`) —
   apt on Debian/Ubuntu, dnf on Fedora, dnf + EPEL/CRB on RHEL rebuilds
   (Rocky/Alma/CentOS) — plus the `gh`/`starship` official repos/installers for
   the gaps; no-sudo profile: rootless mise + `mise install`. Both profiles
   install `python3`, which the `git-wt-*` commands need and which neither
   Ubuntu's nor Fedora's base image ships.
4. `-02-setup-darwin.sh.tmpl` — (darwin) extensive macOS `defaults write` tweaks
5. `-03-setup-dock.sh.tmpl` — (darwin) Dock layout via `dockutil`
6. `-04-setup-fish.sh.tmpl` — register fish as the login shell: `/etc/shells` +
   `chsh` on darwin and linux+sudo; `exec fish` from `~/.bashrc` on linux+no-sudo
7. `-05-setup-bat.sh.tmpl` — `bat cache --build`; loads Homebrew's env on macOS,
   adds `~/.local/bin` + mise shims on Linux, so bat is on PATH under bash
8. `-06-setup-mail.sh.tmpl` — (darwin) prints manual mail setup steps (Keychain
   passwords, Proton Bridge TLS certs)

OS-gating: darwin-only scripts (`xcode-cli`, `01-…-darwin`, `02`, `03`, `06`)
are wrapped so they render **empty** on Linux, and chezmoi skips empty `run_`
scripts; `04` branches per OS/profile. Editing an already-run `run_once_` script
re-runs it (hash changed); keep them idempotent.

## Layout

- `private_dot_config/` — per-app configs: `aerc`, `aerospace`, `bat`, `gh`,
  `gh-dash`, `ghostty`, `khard`, `leaderkey`, `linearmouse`, `msmtp`, `nvim`,
  `private_fish/`, `starship.toml`, `vdirsyncer`, plus the `Brewfile` (macOS
  package source of truth) and `mise/config.toml` (the Linux no-sudo toolchain
  equivalent). `aerospace`/`linearmouse`/`leaderkey`/`Brewfile` are darwin-only
  and `mise` is linux-no-sudo-only, per the templated `.chezmoiignore`.
- `private_dot_config/private_fish/` — fish shell: `config.fish.tmpl` sources
  `exports.fish`, `aliases.fish`, `greet.fish`; uses vi keybindings; inits fzf
  and starship. It's a template only so the mise activation (which would make the
  shell prefer mise's binaries) is gated to the **no-sudo Linux** profile; macOS
  and sudo-Linux render without it. Add functions under `functions/`.
- `dot_local/share/mail/` — Maildir store (`pm`, `ist`, `icloud`) plus notmuch
  state.
- `dot_local/bin/` — user commands, deployed `0755` via the `executable_` prefix:
  `git-wt-clone` (clone a repo as a bare clone plus per-ref worktrees) and
  `git-wt-add` (check a branch/tag/hash out into its own folder). The `git-`
  prefix means git dispatches them as subcommands too (`git wt-add …`).
- `dot_local/lib/python/` — the `gitwt` library both commands share. **The entry
  points import `gitwt` and nothing else**; it is a facade of re-exports, so the
  split below can change without touching them. Modules import strictly
  downwards, which is what keeps them free of cycles:

  | module | holds | imports |
  | --- | --- | --- |
  | `gitwt_git.py` | constants, `GitWtError`, `git()` | nothing local |
  | `gitwt_refkind.py` | `RefKind` (what a ref names) | `gitwt_git` |
  | `gitwt_repo.py` | `Repo` (layout discovery, clone, fetch) | `gitwt_git` |
  | `gitwt_plan.py` | `Plan` (folder name + `worktree add` argv) | the three above |
  | `gitwt_worktree.py` | `Worktree` (create, or reuse in place) | all of the above |
  | `gitwt.py` | `__all__`, nothing else | all of the above |

  Standard library only and Python 3.9-compatible: that floor comes from both
  OSes — a fresh Mac has Apple's 3.9 until Homebrew's lands, and the RHEL
  rebuilds ship 3.9 as well. `tests/check.py` both lints every module with ruff
  and imports the library under each interpreter it finds, since ruff alone
  cannot see an import cycle.
- `private_dot_ssh/`, `private_dot_gitconfig`, `dot_bashrc` — top-level
  dotfiles.

`~/.local/bin` is already on `PATH` on every profile: macOS via `fish_user_paths`
in `exports.fish`, Linux via `fish_add_path` in `config.fish.tmpl`.

## Email subsystem

The most interconnected part. Sync/read pipeline: **mbsync/isync**
(`encrypted_isyncrc.age`) pulls mail into `~/.local/share/mail` -> **notmuch**
(`encrypted_dot_notmuch-config.age`) indexes it -> **aerc** reads it ->
**msmtp** sends -> **khard**/**vdirsyncer** handle contacts/CardDAV. Proton
Mail is reached through Proton Mail Bridge (TLS certs exported into
`~/.config`). After credential/config changes: `mbsync -a && notmuch new`.

## Testing (human-run — do NOT let an AI run this)

Other machines pull `main` via `chezmoi update`, so a broken `main` breaks
them. Before pushing to `main`, a human runs the safety harness:

```sh
python3 tests/check.py
```

It renders the whole source with `chezmoi archive` (proving templates + age
decryption + ignores work), lints the `run_*` bootstrap scripts (`bash -n`,
shellcheck), checks the Brewfile, lints this repo's Python with ruff, imports the
deployed `gitwt` library under every `python3` on the host, and prints a
`chezmoi apply --dry-run` diff to review. It performs **no** destructive
actions and never runs the `run_*` scripts. `check.py` is OS-aware: scripts
gated off for the current OS render empty and are skipped, so it runs on both
macOS and Linux. The `tests/` directory is chezmoi-ignored (never deployed to
`$HOME`).

To validate the **Linux** targets from any machine (macOS included), a Docker
driver renders + lints all four `distro × sudo` combinations in throwaway
containers (no host changes, no real age key):

```sh
python3 tests/linux.py          # render + lint ubuntu/fedora/rocky/alma × sudo/no-sudo
python3 tests/linux.py --full   # also run the real apt/dnf + mise bootstrap in-container
```

The macOS analogue is `tests/macos.py`, which does the same in throwaway **Lume**
VMs (Docker can't run macOS; Lume is the MIT-licensed CLI over Apple's
Virtualization framework, Apple Silicon only). It needs only `lume`
(`/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"`; `lume ssh`
handles guest access, so there is no ssh password plumbing):

```sh
python3 tests/macos.py               # render + lint the darwin scripts in a macOS VM
python3 tests/macos.py --only tahoe  # one image only (each image is a ~20-90 GB pull)
python3 tests/macos.py --full        # also run the real bootstrap (heavy: brew, defaults, dock)
```

A `pre-push` git hook enforces this on pushes to `main`. Enable it once per clone:

```sh
git config core.hooksPath tests/githooks
```

See `tests/README.md` for full documentation of the harness and the hook
(behavior, bypassing with `--no-verify`, and the per-clone caveat).

**AI agents (including Claude Code) must never run `tests/check.py` or `chezmoi
apply` — applying dotfiles has real side effects (chsh, defaults write, brew,
dockutil). Testing and applying are human-only steps.**

Python in this repo — the harness plus the deployed `git-wt-*` commands under
`dot_local/` — must pass the ruff ruleset in `tests/pyproject.toml` (`ruff check`
+ `ruff format`). The deployed ones live outside `tests/`, so `check.py` passes
them to ruff by path with an explicit `--config`; the library modules are globbed
from `dot_local/lib/python/`, so splitting one in two keeps it covered.
