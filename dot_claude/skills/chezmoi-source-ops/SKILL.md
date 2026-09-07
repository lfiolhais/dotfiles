---
name: chezmoi-source-ops
description: Safely inspect, render, lint and verify a chezmoi source directory from inside the Claude Code sandbox, without applying anything to the machine. Use when working in a chezmoi dotfiles repo — checking a template renders, verifying a claim about what lands in $HOME, or linting a bootstrap script — and when chezmoi fails with "operation not permitted".
---

# Working in a chezmoi source directory

A chezmoi source directory is not the files that run. chezmoi renders it into
`$HOME`, applying naming conventions on the way, and only the rendered copy has
any effect. So the two things that go wrong here are editing the target instead
of the source, and verifying a claim by applying it.

Everything below is read-only. Nothing here changes the machine.

## Never apply, ever

`chezmoi apply`, `chezmoi init` and `chezmoi update` have real side effects in a
dotfiles repo: changing the login shell, writing system defaults, installing
package sets, loading launch agents, mounting shares. In a repo like this,
applying is the user's step, and a test harness that runs bootstrap scripts is
too.

These are safe and answer almost every question:

```sh
chezmoi diff                # what applying would change
chezmoi status              # files that differ between source and target
chezmoi managed             # every target path chezmoi controls
chezmoi source-path         # where the source directory is
chezmoi cat ~/.config/x     # the rendered content of one target
chezmoi execute-template    # render a template from stdin
chezmoi archive             # render the whole source to a tarball
chezmoi state dump          # what run_once_ scripts are recorded as done
```

`chezmoi state delete-bucket --bucket=scriptState` is the command that makes
`run_once_` scripts run again. It is safe to *name* in documentation and is not
yours to run.

## When chezmoi says "operation not permitted"

The shell's sandbox and the file-editing tools do not share a deny list. A write
refused on a path inside the repository itself fails from a shell command with
`Operation not permitted` and goes through the Edit tool unchanged. An EPERM on
a repository path is a reason to reach for the editing tool, not evidence that
the file cannot be written.

The sandbox denies the real `~/.config/chezmoi`, so chezmoi fails before doing
anything. Give it a throwaway config, cache and state under `$TMPDIR` — never
`/tmp`, which parallel jobs share:

```sh
CZ="$TMPDIR/cz"; mkdir -p "$CZ"
printf '[data]\n    sudo = true\n' > "$CZ/chezmoi.toml"

chezmoi execute-template \
  --config "$CZ/chezmoi.toml" \
  --cache "$CZ/cache" \
  --persistent-state "$CZ/state.boltdb" \
  --no-tty < some-template.tmpl
```

`--no-tty` matters: chezmoi prompts on `/dev/tty`, not stdin, so a prompt raised
behind captured output hangs with nothing on screen.

The `[data]` block supplies whatever variables the templates branch on. Read
`.chezmoi.toml.tmpl` to see which the repo prompts for, and set them explicitly
rather than letting a prompt block.

For anything that touches encrypted files without the real age key, add
`--exclude encrypted`. To test target-state behaviour, add
`--destination "$CZ/home"` so a render lands in scratch rather than `$HOME`.

## Rendering both OS branches

Templates gate on `.chezmoi.os` and on profile variables, and a change that
renders on one OS can break the other. A script gated off for the current OS
renders empty, and chezmoi skips empty `run_` scripts — so empty output is a
pass, not a failure.

Check a template on the OS it is not written for by overriding the variable, and
confirm the gated-off render is empty rather than broken.

## Linting what you rendered

Render first, then lint the output — linting the template itself fails on the Go
template syntax:

```sh
chezmoi execute-template … < run_once_x.sh.tmpl > "$CZ/x.sh"
bash -n "$CZ/x.sh"
shellcheck -S error "$CZ/x.sh"
```

For fish, `fish -n file.fish` parses without executing. For Python, use the
repo's own ruff config rather than a default one:

```sh
ruff check --preview --config tests/pyproject.toml <paths>
ruff format --check --config tests/pyproject.toml <paths>
```

`--preview` is usually required for docstring rules to fire at all.

Deployed libraries and command entry points live outside the test directory and
the entry points often have no `.py` extension, so they have to be passed by
path with an explicit `--config`.

## Verifying a claim about what an apply writes

Source paths and target paths are different, and documentation that names one
where the reader needs the other sends them to a file that does not exist. Two
ways to settle it:

- `chezmoi managed` lists real target paths. Grep it.
- `chezmoi archive --exclude encrypted --output "$CZ/state.tar"` then
  `tar -tvf` — the listing carries the modes, which is how to check what a
  permission prefix actually produces.

Do not reason about the naming prefixes from memory. `private_` removes group
and world permissions from the one entry it names — 0700 for a directory, 0600
for a file — and does not propagate into a directory's contents. `exact_`
declares a target directory to hold exactly the source entries and deletes
strays, which is what makes deletions propagate and what silently removes a file
created outside chezmoi.

## Checking a deployed Python library

The libraries are on no import path by default. Import them the way the repo's
harness does, and use `-B` so no `__pycache__` is left in the source tree:

```sh
python3 -B -c "import sys; sys.path.insert(0, 'dot_local/lib/python'); import <module>"
python3 -B dot_local/bin/executable_<command> --help
```

`--help` makes argument parsing exit before any real work, so it is safe on
commands that would otherwise mount, install or write.

Where a command's shebang runs it through `uv`, the sandbox usually blocks both
uv's cache and the package index. If its third-party imports are guarded, a
plain `python3` of a new enough version runs `--help` fine; otherwise report the
check as unverified rather than working around it.

## Editing rules that are easy to get wrong

- Apply the naming prefixes by hand when creating a file — `dot_`, `private_`,
  `executable_`, `encrypted_`, `exact_`, `.tmpl` — or let `chezmoi add` do it.
- Never hand-edit a generated file. A package manifest written by a command, or
  a config rendered from one, loses hand-written comments at the next write; the
  annotation belongs in whatever field the generator preserves.
- Never hand-edit a file that a dump regenerates. A Brewfile written by
  `brew bundle dump` is derived from the machine, and a spliced-in line is gone
  at the next dump.
- Editing an already-run `run_once_` script re-runs it, because the hash
  changed. Reverting the edit restores the old hash and it does not run again.
- A `run_once_` script is recorded as done only when it exits 0. A script with no
  `set -e` that fails partway still exits 0, is recorded, and never runs again —
  which is the trap worth checking for when a bootstrap step "worked" but the
  machine is missing things.
