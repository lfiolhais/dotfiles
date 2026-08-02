# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo is

This is the **chezmoi source directory** for a personal macOS dotfiles setup.
Files here are *source state*; chezmoi renders them into the *target state*
under `$HOME`. Never edit the deployed dotfiles under `$HOME` directly — edit
the source here and apply, or the next `chezmoi apply` will overwrite your
change.

The target machine is always macOS (`darwin`); all templates and bootstrap
scripts are gated accordingly.

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

1. `run_once_before_install-setup-xcode-cli.sh.tmpl` — Xcode Command Line Tools
   + Rosetta 2
2. `run_onchange_before_decrypt-private-key.sh.tmpl` — decrypt the age key into
   `~/.config/chezmoi/key.txt`
3. `run_once_after_install-01-install-packages-darwin.sh.tmpl` — install
   Homebrew, `brew bundle --file=~/.config/Brewfile`, rustup
4. `-02-setup-darwin.sh.tmpl` — extensive macOS `defaults write` system tweaks
5. `-03-setup-dock.sh.tmpl` — Dock layout via `dockutil`
6. `-04-setup-fish.sh` — register fish in `/etc/shells` and `chsh` to it
7. `-05-setup-bat.sh` — `bat cache --build`
8. `-06-setup-mail.sh` — prints manual mail setup steps (Keychain passwords,
   Proton Bridge TLS certs)

Editing an already-run `run_once_` script re-runs it (hash changed); keep them
idempotent.

## Layout

- `private_dot_config/` — per-app configs: `aerc`, `aerospace`, `bat`, `gh`,
  `gh-dash`, `ghostty`, `khard`, `leaderkey`, `linearmouse`, `msmtp`, `nvim`,
  `private_fish/`, `starship.toml`, `vdirsyncer`, plus the `Brewfile` (source
  of truth for installed packages).
- `private_dot_config/private_fish/` — fish shell: `config.fish` sources
  `exports.fish`, `aliases.fish`, `greet.fish`; uses vi keybindings; inits fzf
  and starship. Add functions under `functions/`.
- `dot_local/share/mail/` — Maildir store (`pm`, `ist`, `icloud`) plus notmuch
  state.
- `private_dot_ssh/`, `private_dot_gitconfig`, `dot_bashrc` — top-level
  dotfiles.

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
shellcheck), checks the Brewfile, lints its own Python with ruff, and prints a
`chezmoi apply --dry-run` diff to review. It performs **no** destructive
actions and never runs the `run_*` scripts. The `tests/` directory is
chezmoi-ignored (never deployed to `$HOME`).

A `pre-push` git hook enforces this on pushes to `main`. Enable it once per clone:

```sh
git config core.hooksPath tests/githooks
```

See `tests/README.md` for full documentation of the harness and the hook
(behavior, bypassing with `--no-verify`, and the per-clone caveat).

**AI agents (including Claude Code) must never run `tests/check.py` or `chezmoi
apply` — applying dotfiles has real side effects (chsh, defaults write, brew,
dockutil). Testing and applying are human-only steps.**

Python in this repo (the harness) must pass the ruff ruleset in
`tests/pyproject.toml` (`ruff check` + `ruff format`).
