---
name: dotfiles-review
description: Review this chezmoi dotfiles repository — the three profiles it renders for, the lists it keeps in more than one place, and what is never yours to run. Use when asked to check, audit or review the repo, after changing a template or a bootstrap script, and before the user tests on a real machine.
---

# Reviewing these dotfiles

The method is the `deploy-review` skill: what a defect is here, the order to
work in, and which reviewer finds which class of defect.
The sandbox mechanics — the throwaway chezmoi config, what is read-only, how the
naming prefixes work — are in `chezmoi-source-ops`. Read both. This file holds
only what neither can know: what this repository calls things, which of its
lists mirror each other, and which of its own failures keep recurring.

The agents `deploy-review` calls for are `drift-checker` and `deploy-auditor`.
Neither is written for chezmoi, so each needs this repository's particulars in
the prompt it is given, and the section named after it here is what to hand it.

## The one thing to run

`CLAUDE.md`'s hard rules say what is never yours to run here and which chezmoi
subcommands are read-only. Within that, `bash tests/render-matrix.sh` is the
fast first step `deploy-review` asks for: it renders every template for all
three profiles and lints the output, in seconds, touching no `$HOME`. Its header
says what that render does and does not prove.

Ask for the output of the other harnesses rather than producing it.

## The profiles, for `deploy-auditor`

`.chezmoi.toml.tmpl` produces three, and a change that is right for one can be
wrong for another. macOS never prompts for sudo:

| target | `.chezmoi.os` | `.sudo` | what it is |
| --- | --- | --- | --- |
| the Mac | `darwin` | unread | the primary machine, Apple Silicon, Homebrew |
| Linux, sudo | `linux` | `true` | the distro's own package manager is usable |
| Linux, no sudo | `linux` | `false` | mise installs the packages, bash stays the login shell |

`.chezmoi.toml.tmpl` asks for `.sudo` on Linux alone, and every template that
reads it pairs it with an `.chezmoi.os` test, so the value does not reach a
darwin render. That is why `tests/render-matrix.sh` has one darwin row and
prints it as `sudo=true`.

A template gated off for a target renders empty, and chezmoi skips an empty
`run_` script, so empty output is a pass.

What fails here, in the order it is usually the answer:

- A `.chezmoidata/packages.toml` entry with no `apt`, `fedora`, `el`, `mise` or
  `repo` field installs nowhere on Linux, and its `note` says why. A `note`-only
  entry named by a file that deploys to Linux fails on every Linux machine.
- `UseKeychain` in an ssh config, a `/opt/homebrew` path, and a home directory
  that is not under `/Users` are the three one-OS things that keep coming back.
- On macOS nothing puts `/opt/homebrew/bin` on `PATH` until this repository
  does, so a lookup before that point fails on a fresh machine and works on a
  configured one.
- `run_once_` is recorded when the script exits 0, and a script with no `set -e`
  exits 0 after any number of failed commands.
- `04-setup-fish` and `08-setup-ssh` stop and wait, for the account password and
  for each key's passphrase, and each announces it first. A new prompt that does
  not is a hang to whoever is watching an unattended apply.

## The pairs, for `drift-checker`

- every `brew` and `uv` entry in `private_dot_config/Brewfile` against
  `.chezmoidata/packages.toml`;
- every file in `dot_local/bin/` and every fish function under
  `private_dot_config/private_fish/functions/` against the tables in
  `README.md` — a function there is a command the user can type;
- `DEPLOYED_ENTRY_POINTS`, `SHELL_FILES` and `GENERATED_NAMES` in
  `tests/check.py` against the directories they mirror;
- every path named in `README.md`, `CLAUDE.md` and `tests/README.md` against
  what exists, in both directions. A source file renamed to or from `exact_` or
  `.tmpl` leaves the old name behind in whichever document was not open;
- every `run_` script named in documentation against the scripts at the repo
  root, numbering included;
- a file holding a secret that is not `encrypted_`, a `.tmpl` extension on a
  file with no `{{` in it, and `{{` in a file without the extension.

## Where a finding goes

`CLAUDE.md` has it, under "Reviewing this repo": which findings go to `TODO.md`
for the user and which are corrected in place.
