# Backlog

Each item changes behaviour, so it is a decision rather than a correction.
Nothing here has been applied. Nothing here has been tested on a live machine.

## Git

### `signOff` puts the trailer on a patch, not on a commit

`private_dot_gitconfig.tmpl:85`

```ini
[format]
	signOff = yes
```

This is not dead — it is what puts `Signed-off-by` on `git format-patch` output,
which is how a patch reaches a mailing list, and the `[sendemail]` block above it
says that is a workflow this machine has. Keep it.

The gap is `git commit`. No git configuration adds the trailer to a commit, so a
commit that goes out as a pull request rather than a patch carries no sign-off,
and RISC-V's DCO rejects it.

Three routes, and only the third covers `-m`, `--amend` and an editor commit
alike:

- `git commit -s`, or an alias for it. This is the step being forgotten, so
  making it shorter does not help.
- `commit.template`. git ignores the template when `-m` is given, and the
  trailer would sit at the top of the buffer rather than after the body.
- a `prepare-commit-msg` hook. git runs it for every commit, whatever wrote the
  message.

A hook has to be found, and `core.hooksPath` is how — but set globally it
replaces `.git/hooks` in *every* repository, which silently disables husky,
`pre-commit`, and this repository's own `tests/githooks/pre-push`. So it is
scoped to the repositories that need it. git 2.36 added the conditional that
does it; this machine has 2.55.

In `private_dot_gitconfig.tmpl`, at the end:

```ini
# The DCO applies to some projects and not others, and core.hooksPath below
# replaces .git/hooks for whatever it covers -- so it is turned on per remote
# rather than globally. Add a pattern here for each project that wants it.
[includeIf "hasconfig:remote.*.url:https://github.com/riscv/**"]
	path = ~/.config/git/dco.inc
[includeIf "hasconfig:remote.*.url:git@github.com:riscv/**"]
	path = ~/.config/git/dco.inc
[includeIf "hasconfig:remote.*.url:https://github.com/riscv-*/**"]
	path = ~/.config/git/dco.inc
[includeIf "hasconfig:remote.*.url:git@github.com:riscv-*/**"]
	path = ~/.config/git/dco.inc
```

A new `private_dot_config/git/dco.inc`:

```ini
# Only the repositories the includeIf above matched read this file. A repository
# here that has hooks of its own loses them: core.hooksPath replaces .git/hooks
# rather than adding to it.
[core]
	hooksPath = ~/.config/git/hooks-dco
```

And a new `private_dot_config/git/hooks-dco/executable_prepare-commit-msg`:

```sh
#!/bin/sh
# git passes the message file and how the message was produced: "message" for
# -m, "commit" for --amend or -c, "merge", "squash", "template", or nothing at
# all for an editor commit. Only a merge message is git's own to write.
[ "$2" = "merge" ] && exit 0

trailer="Signed-off-by: $(git config user.name) <$(git config user.email)>"

# --amend re-runs this on a message that already has the trailer.
grep -qF "$trailer" "$1" && exit 0

# interpret-trailers puts it after the body, beside any trailer already there,
# and above the comment block git strips -- which is where the DCO check looks.
git interpret-trailers --in-place --trailer "$trailer" "$1"
```

This was tried in scratch repositories, one with a `riscv` remote and one
without, under a `GIT_CONFIG_GLOBAL` holding the two files above. It behaves in
all four cases that matter: a `-m` commit in the matching repository gets the
trailer, the other repository gets nothing, amending twice does not duplicate
it, and on a message that already has a `Reviewed-by:` the sign-off joins the
trailer block underneath it rather than starting a second one.

What was not tried is a real RISC-V repository, and the pattern list above is a
guess at which remotes want it. `git config --get-all include.path` inside a
clone says whether the conditional matched.

## The NAS

### Nothing writes outstanding data back before the network goes away

`dot_local/bin/executable_mount-nas`, `dot_local/lib/python/mountnas.py`

`mount-nas unmount` now flushes and unmounts plainly while the NAS answers, and
forces only a share whose server has already gone — so the way this used to
discard data is closed, and `mount-nas flush` runs the flush on demand.

What is left is the case nothing can detect: a laptop shut and carried to
another network. By the time anything notices, the NAS is unreachable and an
outstanding write has nowhere to go.

macOS gives launchd no sleep trigger, so a flush on sleep needs a process that
is already running to be told. `sleepwatcher` is the usual one — a Homebrew
formula that runs `~/.sleep` before sleep and `~/.wakeup` after:

```sh
chezmoi-packages add sleepwatcher --note "runs mount-nas flush before sleep"
```

then a `dot_sleep` holding `exec "$HOME/.local/bin/mount-nas" flush`, and
`brew services start sleepwatcher` in the 07 script.

The cost is one more formula, one more background daemon and one more entry
under Login Items. The alternative is to run `mount-nas flush` by hand before
closing the lid, which is the same class of thing as remembering to eject a
disk.

## Contacts

### A contact deleted on one machine stays on every other

`private_dot_config/khard/work/default/`

The source directory is no longer `exact_`, so chezmoi no longer declares the
target to hold exactly the entries the source has. Two consequences, and they
pull in opposite directions:

- a card `khard new` writes is no longer deleted by the next apply, which is
  what `exact_` used to do and what made `khard-track` urgent;
- a card dropped from the source is no longer deleted from any machine that
  already has it. `khard-rm` forgets the source entry, the commit reaches the
  other machine, and the contact stays there for good.

The address book is only a shared source of truth if deletions propagate, which
means restoring `exact_default`. The trap that made it dangerous is now covered
from the other side: the `khard` wrapper re-adds the address book after every
subcommand that writes a card, and `khard-status` lists by name — decrypting each
card to do it — anything that is on the machine and not in the source, in the
source and not on the machine, or different between the two.

Restoring it is a directory rename:

```sh
git -C "$(chezmoi source-path)" mv \
    private_dot_config/khard/work/default \
    private_dot_config/khard/work/exact_default
```

Run `khard-status` on every machine before doing it. After the rename, a contact
that is on a machine and not in the source is deleted at that machine's next
apply.

## Packages

### Six formulae are in the Brewfile and in no manifest entry

`python3 tests/check.py` fails on this now:

```
ansible, codespell, delve, gdb, go, scdoc:
    in the Brewfile, unaccounted for in the manifest
handbrake:
    claims the formula 'handbrake', which the Brewfile no longer has
```

Every one needs a Linux name, or a `note` saying it installs nowhere there.
Guessing the names would put unverified ones in the manifest, and the manifest is
what the Linux bootstrap installs from in a single strict transaction — one bad
name aborts the whole thing. `search` asks each platform:

```sh
chezmoi-packages search ansible      # then the add it prints
chezmoi-packages search codespell
chezmoi-packages search delve
chezmoi-packages search gdb
chezmoi-packages search go
chezmoi-packages search scdoc
```

`handbrake` is the other direction: the formula is gone from the Brewfile and the
manifest entry still claims it. `chezmoi-packages remove handbrake` drops it.

Afterwards `python3 tests/linux.py` confirms each new name resolves in the
repositories it claims to.

### Linux has no compiler, and aerc's filters are now built rather than shipped

`run_onchange_after_install-09-build-aerc-filters.sh.tmpl`,
`.chezmoidata/packages.toml`

The `colorize` and `wrap` filters are compiled from the C sources this
repository deploys, because a built one is specific to an architecture and an
operating system. macOS has `cc` from the Xcode command-line tools, which
`setup-xcode-cli` guarantees. No Linux target installs a compiler — the manifest
has no `gcc` entry — so on Linux the script prints what is missing and exits 0,
and aerc renders plain text and calendar parts unhighlighted.

Either add the compiler:

```sh
chezmoi-packages search gcc      # then the add it prints, with --no-install
```

or accept that aerc on Linux is unfiltered and say so in `README.md`. Adding
`gcc` pulls a toolchain onto every Linux machine for two small filters, which is
the trade-off.

### `brew` is guarded and `mas` is not

`private_dot_config/private_fish/functions/brew.fish`

The Brewfile records App Store apps as well as formulae and casks, so
`mas install` and `mas uninstall` desync it exactly as `brew install` does. A
`mas.fish` alongside `brew.fish`, blocking the same two verbs and naming
`chezmoi-packages dump`, would close it.

Whether it is worth a second wrapper depends on how often the App Store is used
outside the bundle.

## Linux-only helpers on a macOS-first machine

### `restart-wifi` lists the devices instead of restarting the interface

`private_dot_config/private_fish/functions/restart-wifi.fish`

```fish
sudo modprobe -r brcmfmac; sudo modprobe brcmfmac
sleep 2
sudo nmcli device
```

The reload is real; the last line reports rather than acts, and the description
now says so. It also names one driver, so it works on the machine it was written
for and no other.

Three ways out: delete it, replace the last line with
`sudo nmcli networking off; and sudo nmcli networking on`, or take the driver as
an argument. Which one depends on whether the Linux machine it was written for
still exists.

### `convert-vp9-to-x264` encodes with an NVIDIA-only encoder

`private_dot_config/private_fish/functions/convert-vp9-to-x264.fish`

```fish
ffmpeg -i "$file" -c:v h264_nvenc …
```

`h264_nvenc` needs an NVIDIA GPU, so on this Mac every conversion fails at the
encoder. `h264_videotoolbox` is the macOS equivalent and takes different quality
flags — `-q:v` rather than `-cq:v -b:v 0` — so it is not a substitution, and
`libx264` is the one that works everywhere at the cost of speed.

Picking the encoder from `uname` would make the function work on both, but the
quality settings have to be chosen per encoder rather than carried across.

## The macOS harness

### `--full` in a headless VM cannot get past `chsh`

`run_once_after_install-04-setup-fish.sh.tmpl:22`

```sh
if [ "${login_shell}" != "${fish_path}" ]; then
    echo "Making ${fish_path} the login shell. chsh asks for the account password."
    chsh -s "${fish_path}"
fi
```

`tests/macos.py --full` runs `chezmoi apply` over `lume ssh`, which has no
controlling terminal. Bare `chsh` authenticates through PAM against the account
password and, with nothing to read it from, exits non-zero; `set -eu` in `04`
then stops the apply, so `--full` reports `FAILED` even when every step up to
that point passed. The NOPASSWD sudo rule the entrypoint installs does not help,
because `chsh` does not go through sudo.

`run_once_after_install-08-setup-ssh.sh.tmpl` already handles the same situation
for `ssh-add` by guarding on `[ -t 0 ]` and printing the command when stdin is
not a terminal. The same guard on `04`'s `chsh` call leaves a real interactive
`chezmoi apply` unchanged and lets `--full` run to completion in the VM.
`07-setup-nas`'s `launchctl bootstrap gui/$(id -u)` is the next step that assumes
a GUI login session and may need the same treatment.
