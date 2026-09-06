---
name: dotfiles-review
description: Review this chezmoi dotfiles repository — what to run, in what order, which reviewer finds which class of defect, and what is never yours to run. Use when asked to check, audit or review the repo, after changing a template or a bootstrap script, and before the user tests on a real machine.
---

# Reviewing these dotfiles

A defect here is not a failing test. It is a machine that comes up wrong: a
shell that greets a new terminal with an error, a bootstrap script recorded as
done while half its work failed, a file deployed to Linux that only runs on
macOS. The repository's own harness catches syntax and package drift; the rest
is found by asking, for each target, what a person sees on a machine where this
has just been applied.

`chezmoi-source-ops` covers the sandbox mechanics — the throwaway config, what
is read-only, how the naming prefixes work. Read it first. This is what to do
with those mechanics in this repository.

## Never applied, never run

`chezmoi apply`, `init` and `update` change the machine: the login shell,
system defaults, package installs, launch agents, mounted shares. So does any
`run_` script and anything under `tests/`. Testing and applying are the user's
steps, on their machine.

The user runs `python3 tests/check.py`, `python3 tests/linux.py` and
`python3 tests/macos.py`. Ask for the output rather than producing it.

## The order

1. `bash tests/render-matrix.sh` — renders every template for all three
   profiles and lints the output. Seconds, no Docker, and everything it reports
   is a fact. Its header says what the render does and does not prove.
2. The `dotfiles-drift-checker` agent — cheap and mechanical: the two package
   files against each other, documented paths against real ones, prefixes,
   counts written into prose.
3. The `dotfiles-deploy-auditor` agent — the expensive pass, and the one that
   finds what the harness cannot: a command used before it is installed, an
   option the other OS rejects, a script that exits 0 after failing.
4. `doc-review`, when documentation is in scope. `README.md` is written for a
   person; `CLAUDE.md` is written for an agent and is never cited to a person.

Only steps 2 and 3 need an agent. A single file changed is usually answered by
step 1 alone.

## The three profiles

`.chezmoi.toml.tmpl` produces three, and a change that is right for one can be
wrong for another. macOS never prompts for sudo:

| target | `.chezmoi.os` | `.sudo` |
| --- | --- | --- |
| the Mac | `darwin` | n/a |
| Linux, sudo | `linux` | `true` |
| Linux, no sudo | `linux` | `false` |

A template gated off for a target renders empty, and chezmoi skips an empty
`run_` script — so empty output is a pass.

## What has gone wrong before, and is worth checking again

- A file deployed everywhere that only works on one OS: a hardcoded
  `/opt/homebrew` or `/Users/lipe` path, an ssh option macOS alone accepts, a
  `df` or `uptime` column that differs. The fix is a template, not a comment.
- A command used with no guard, on a target whose manifest entry does not
  install it. An entry in `.chezmoidata/packages.toml` with only a `note` and no
  distro column installs nowhere on Linux.
- Something looked up before whatever puts it on `PATH` has run. On macOS
  nothing puts `/opt/homebrew/bin` on `PATH` until this repository does.
- A `run_once_` script with no `set -e`: it exits 0 after any number of failed
  commands, chezmoi records it, and it never runs again.
- A generated file tracked as source — a compiled binary, a `.DS_Store`, an
  editor's state directory. `tests/check.py` refuses these now; the question to
  ask of a new file is which program writes it.
- A comment describing what the code was meant to do rather than what it does.
  Where the two disagree, the comment is the thing being reported, and it is
  fixed by describing the current behaviour.

## Where a finding goes

A defect that changes behaviour goes in `TODO.md` for the user to approve, not
straight into the code. A comment, a document, or a claim that disagrees with
the system is corrected in place — that is not a behaviour change.

Never commit, push, or open a pull request. Finished work is left uncommitted in
the working tree, and the user is told where it is.
