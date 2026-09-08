# Backlog

Each item changes behaviour, so it is a decision rather than a correction.
Nothing here has been applied. Nothing here has been tested on a live machine.

## Testing

### The macOS VM harness passes without ever running the bootstrap

`tests/macos.py`, `tests/lume/entrypoint.sh`

A plain `python3 tests/macos.py` boots the VM, renders every non-encrypted
target with `chezmoi archive`, and lints the darwin `run_` scripts with
`bash -n` and shellcheck. That is the whole run: the entrypoint reaches
`chezmoi apply` only under `FULL=true`, which is what `--full` sets and nothing
else does.

So it reports every target passing while saying nothing about whether an apply
works. Rendering proves a template produces text; linting proves that text
parses. Neither one runs anything, so a script that calls a command the machine
does not have passes both.

`--full` is the pass that covers it, and it has never been run. It is not a
disk or memory problem: `tests/README.md` has the crash and the symptom under
`macos.py`, where the harness needs a GUI login session. It has to be started
from a terminal on the machine's own desktop, not from an automation context,
and that has not been tried. `tests/README.md` also has the prerequisites and
the disk budget.

```sh
/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"   # if lume is absent
python3 tests/macos.py --full
python3 tests/macos.py --full --keep    # keeps the VM between runs, to iterate
```

Expect it to stop somewhere. These stand between `--full` and a clean run, and
none is a defect in the scripts:

- the guest generates an age key of its own, which decrypts nothing of this
  repository's, and the entrypoint passes `--exclude encrypted` unconditionally
  — so the ssh keys, the contacts and the mail credentials are left out of the
  apply whatever the key situation. `08-setup-ssh` then finds no key and prints
  instead of prompting, so this one costs nothing;
- `04-setup-fish` runs `sudo tee /etc/shells` and `chsh -s` under `set -e`.
  Whether those go through unattended depends on the guest image's sudoers and
  on whether `chsh` will authenticate with no terminal behind it. If either
  refuses, the apply stops at 04 and nothing after it is exercised;
- `02-setup-darwin` and `03-setup-dock` talk to a logged-in GUI session — one
  rewrites preferences and kills the apps that hold them, the other drives
  `dockutil` — and the VM boots with `--display none`;
- `07-setup-nas` runs `launchctl bootstrap gui/$(id -u)` unguarded under
  `set -eu`, and a headless guest has no Aqua session for that uid to bootstrap
  into.

The decision is what `--full` should mean given that: have the entrypoint set
something the interactive and GUI-bound scripts check and skip;
boot the VM with a display and drive it as a real machine; or accept that
`--full` covers `01` through `03` and stops, and say so in `tests/README.md`.
Even stopping at `01` would run the package install, which is the part
rendering and linting say nothing about, so the cheapest option is still worth
having.

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

Routes, and only the last covers `-m`, `--amend` and an editor commit
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

### `mount-nas unmount` reports a network failure that did not happen

`dot_local/bin/executable_mount-nas`

`REPORT[UNMOUNTED]` is `"unmounted, the NAS stopped answering"`, and `show()`
prints it for every share `cmd_unmount` takes down. `cmd_unmount` unmounts every
mounted share whatever its reachability, so a plain `mount-nas unmount` against a
NAS that is answering normally ends with the machine reporting that the NAS
stopped answering.

The label is right for the one caller that established it: `sync()` unmounts
because the server went away. `cmd_unmount` reuses the same string for a
deliberate eject.

Closing it means `Outcome` carrying why it unmounted, and `show()` picking the
line from that -- "unmounted" for an eject, "unmounted, the NAS stopped
answering" for a share `sync()` cleared. Whether that is worth a field on
`Outcome` is the decision.

### Nothing writes outstanding data back before the network goes away

`dot_local/bin/executable_mount-nas`, `dot_local/lib/python/mountnas.py`

`mount-nas unmount` flushes and unmounts plainly while the NAS answers, and
forces only a share whose server has already gone; `mount-nas flush` runs the
flush on demand.

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

The source directory is not `exact_`, so chezmoi does not declare the
target to hold exactly the entries the source has. The consequences pull in
opposite directions:

- a card `khard new` writes survives the next apply, so `khard-track` is a
  convenience and not the only way to keep a card;
- a card dropped from the source stays on every machine that
  already has it. `khard-rm` forgets the source entry, the commit reaches the
  other machine, and the contact stays there for good.

Deletions only reach the other machines if the source directory is `exact_`,
which means restoring `exact_default`. The danger in it is covered from the
other side: the `khard` wrapper re-adds the address book after every subcommand
that writes a card, and `khard-status` lists by name — decrypting each card to
do it — anything on the machine and not in the source, in the source and not on
the machine, or different between the two.

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

### Linux has no compiler, so aerc's filters are built from source

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

### `~/.cargo/bin` holds symlinks that resolve to nothing

`~/.cargo/bin`, where `find -L ~/.cargo/bin -type l` prints anything

Each entry there is a symlink to `~/.cargo/bin/rustup`, and that one a symlink
to `/opt/homebrew/bin/rustup-init`. The `rustup` formula provides no binary of
that name, so none of them resolves; `find -L ~/.cargo/bin -type l` lists them.

Nothing crashes, which is why it goes unnoticed. `fish_add_path --path` keeps
the directory because the directory itself exists, and `command --query` answers
no for a symlink pointing at nothing. The guarded commands go quiet, each for
its own reason:

- `aliases.fish` guards on `command --query cargo`, so `c` and `clippy` are
  never defined;
- `update` guards on `command --query rustup`, so its rust step is skipped —
  but only while `rustup` itself is unreachable. The `rustup` formula puts a
  working `/opt/homebrew/bin/rustup` on PATH and that step returns, whatever
  state `~/.cargo/bin` is in.

Putting `/opt/homebrew/opt/rustup/bin` ahead of `~/.cargo/bin` in `exports.fish`
answers the first, and takes effect at the next apply. Until then a shell has
neither the dead links nor rustup's directory, and `cargo` and `rustc` are
absent.

Clearing the dead links is separate and is one line per machine. `aliases.fish`
aliases `find` to `fd`, which does not take find's predicates, so in a shell
this repository has configured it is the fd form that works:

```fish
fd --hidden --no-ignore --type symlink . ~/.cargo/bin \
   --exec sh -c 'test -e "$1" || echo "$1"' _ {}      # list the dead ones
fd --hidden --no-ignore --type symlink . ~/.cargo/bin \
   --exec sh -c 'test -e "$1" || rm "$1"' _ {}        # remove them
```

`fd` has no broken-symlink predicate, so `--type symlink` selects every link and
`test -e`, which follows the link, keeps only those pointing at nothing. The
real `find`, reached past the alias, does it the same way:

```fish
command find ~/.cargo/bin -type l ! -exec test -e '{}' ';' -delete
```

The shorter `command find -L ~/.cargo/bin -type l -delete` does not work on
macOS: BSD find refuses `-delete` whenever `-L` makes it follow symlinks —
`find: -delete: forbidden when symlinks are followed` — so the brokenness test
has to be the `-exec`, not the `-L`. It is fine for listing, just not for
deleting.

All of these delete inside `$HOME`, at a path chezmoi does not manage — nothing
in this repository writes `~/.cargo/bin`. That is why it is a line to run by
hand and not a `run_once_` script. The directory still belongs on PATH
afterwards: it is where `cargo install` puts things.

Done on the Mac this was written on; `find -L ~/.cargo/bin -type l` says
whether another machine still needs it.

### anylinuxfs is uninstalled, and the tap may be sound

`private_dot_config/Brewfile`, `.chezmoidata/packages.toml`

`anylinuxfs` came from the `nohajc/anylinuxfs` tap and `anylinuxfs-gui` from
`fenio/tap`. Both entries and both taps are already dropped, so the bundle
completes. Whether they come back is the open part.

`brew` on this machine fails intermittently, and the failure is in writing its
own API cache, not in reading a remote:

```
curl: (56) Failure writing output to destination, passed 2370 returned 4294967295
HTTP status: 200
```

The HTTP status is 200, so the request itself succeeded, and the destination it
could not write to is a path under `$(brew --cache)`, not a URL. That is a local
cache fault, and a tap fetch failing the same way looks like the tap being
unavailable. If that is what happened, the tap is fine and the cache is not:

```sh
rm -rf "$(brew --cache)/api"
brew update --force
brew doctor
```

Then `chezmoi-packages add anylinuxfs` puts it back if it installs. If it fails
the same way with a clean cache, the tap really is gone and the entries stay
out. Nothing in this repository names anylinuxfs, so leaving it out costs no
documentation — only the ability to mount a Linux filesystem on this Mac.

## Bootstrap

### `03-setup-dock` gives two answers about what a re-run does

`run_once_after_install-03-setup-dock.sh.tmpl`

Line 5 says editing the script re-runs it, "which appends them again". Lines
18-20 say `dockutil --add` "exits non-zero when the item is already in the
Dock", and that the trailing echo hides it. Both describe the same re-run and
they do not agree: one has the apps appended a second time, the other has
`dockutil` refusing and the failure swallowed.

`README.md` tells anyone whose bootstrap failed to run `chezmoi state
delete-bucket --bucket=scriptState && chezmoi apply -v`, which re-runs every
`run_once_` script, and justifies it with "they are written to be safe to
repeat". That claim rests on this script among others.

Settling it takes one run of `dockutil --add` against an app already in the
Dock, on a machine where duplicating the Dock is acceptable. Whichever comment
turns out wrong is deleted, and if the apps do duplicate then the script needs a
membership check before each add.

## Shell functions

### `zip` excludes more than the repository internals

`private_dot_config/private_fish/functions/zip.fish`

The wrapper passes `-x '*.git*'`. That is a substring match, so `.gitignore`,
`.gitmodules` and the whole `.github/` tree are dropped alongside `.git/`, and
zip says nothing about what it left out. An archive of a checkout handed to
someone else arrives with no CI workflows.

The description now says so. Whether the pattern should be narrowed to `.git/`
alone -- `-x '*/.git/*' '.git/*'` -- is the decision, and it turns on whether
the archives this is used for are meant to carry `.github/`.

## Documentation

### Authoring conventions live where a person does not read them

`CLAUDE.md`, `README.md`

`CLAUDE.md` opens by saying `README.md` is the documentation and that it covers
only what an agent needs on top. Its closing section breaks that: a new fish
function is one file per function named after the function, because fish
autoloads by filename; a new deployed command goes in `dot_local/bin/` with
`executable_`, imports a single facade, and is added to `DEPLOYED_ENTRY_POINTS`
in `tests/check.py`. Neither is agent-specific, and `README.md` has neither.

Moving them into `README.md` changes what that file is for -- it documents using
this machine, not extending it. The alternative is a short "Adding to this
repository" section there, with `CLAUDE.md` citing it.

### The Pi-hole procedures have no reader who is a person

`dot_claude/skills/pihole-dns-ops/SKILL.md`

That file carries the recovery steps for a household DNS and DHCP server: the
config key that explains every service name breaking at once, the wildcard
record trap, and the warning that restarting FTL drops DNS and DHCP for every
device. Nothing in `README.md` mentions Pi-hole, so those steps exist only in a
file addressed to an agent, and a person debugging the network at night has
nowhere to look.

The skill is deployed to every machine, so the material travels; only its
audience is wrong. Whether a Pi-hole runbook belongs in this repository at all,
given that the repository is otherwise about this laptop, is the decision.

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

Ways out: delete it, replace the last line with
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
