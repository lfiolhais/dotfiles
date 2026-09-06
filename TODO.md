# Backlog

Code defects found while reviewing the documentation. Each was left unfixed
because the correction changes behaviour, which is a separate decision from
documenting it. Where a comment described the intended behaviour rather than the
actual one, the comment now describes what the code does, so the source and the
documentation agree on the current, defective state.

Nothing here has been tested on a live machine.

## Bootstrap

### `04-setup-fish` cannot add fish to `/etc/shells`, and aborts before trying

`run_once_after_install-04-setup-fish.sh.tmpl:2,4,9,22`

```sh
set -eu
has_fish=$(grep -c fish < /etc/shells)
...
if [ -z "${has_fish}" ]; then
```

Two independent faults on one line. `grep -c` exits 1 when it matches nothing —
the fresh-machine case this code exists for — and under `set -e` that aborts the
script at line 4. If it survives (a machine where fish is already listed),
`grep -c` prints `0`, so `has_fish` is the string `0`, never empty, and the
`[ -z ]` test is false either way. The `which fish | tee -a /etc/shells` line is
unreachable in both directions.

`chsh -s "$(which fish)"` at line 13 and 26 then runs unguarded and fails with
"non-standard shell" on a machine where the append never happened. Because this
script exits non-zero it is not recorded, so every apply retries it and stops
there — scripts `05`, `06` and `07` never run.

A working form tests membership rather than counting:

```sh
if ! grep -qxF "$(command -v fish)" /etc/shells; then
    command -v fish | sudo tee -a /etc/shells
fi
```

`chsh` also prompts for the account password, which is worth an `echo` before it
so an unattended apply does not look like a hang.

### `01-install-packages-darwin` blocks on a prompt, then runs a command that is not there

`run_once_after_install-01-install-packages-darwin.sh.tmpl:26-28`

```sh
if ! command -v rustup > /dev/null 2>&1; then
    rustup-init
    rustup install stable
fi
```

`rustup-init` is interactive without `-y`, so an unattended apply waits at a
menu. After it finishes, `rustup` is in `~/.cargo/bin`, which this shell's
`PATH` does not include, so line 28 reports "command not found". The script sets
no `-e`, so that failure is ignored and the script still exits 0 — and a
`run_once_` script that exits 0 is recorded and never runs again.

`rustup-init -y` alone installs the stable toolchain, which makes line 28
redundant.

### The macOS package script records a partial install as complete

`run_once_after_install-01-install-packages-darwin.sh.tmpl`

No `set -e`, and `brew bundle` covers 113 formulae, 41 casks and 22 Mac App Store
apps. `mas` entries fail individually when the App Store is not signed in. The
script exits 0 regardless, chezmoi records it, and the machine is missing
packages with nothing to indicate it.

Deciding between `set -e` (stop at the first failure, retry the whole bundle) and
an explicit exit-status check after `brew bundle` is the open question. Either
makes the failure visible; today it is silent.

## macOS defaults

### New Finder windows open on the Desktop, and the path key is dead

`run_once_after_install-02-setup-darwin.sh.tmpl:151-152`

```sh
defaults write com.apple.finder NewWindowTarget -string "PfDe"
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}"
```

`PfDe` is Desktop. `NewWindowTargetPath` is read only when the target is `PfLo`,
so the second line has no effect. For Home, either `PfHm` with no path, or
`PfLo` with the path. The comment now describes the Desktop behaviour, so
changing the value means updating it too.

## Deployed commands

### `mount-nas unmount` force-unmounts a reachable share

`dot_local/bin/executable_mount-nas:167-187`, `dot_local/lib/python/mountnas.py`

`cmd_unmount` iterates every mounted share and calls `unmount()` with no
reachability test. `unmount()` is forced. The safety argument for forcing is
that `sync()` only reaches it once the server has gone, so nothing could be
written back — which does not hold for this caller. Running `mount-nas unmount`
while connected discards unwritten data with no warning.

Either gate the forced path on `share.reachable()` being false and use a plain
unmount otherwise, or require a flag to force. The docstring now states both
callers rather than only the safe one.

## Shell configuration

### `zip` alias breaks ordinary use

`private_dot_config/private_fish/aliases.fish:37`

```fish
alias zip="zip -x '*.git*'"
```

`-x` consumes every following non-option argument as an exclude pattern, so
`zip out.zip dir` becomes `zip -x '*.git*' out.zip dir` and zip exits with
"Nothing to do!". A function that places `-x` after the archive name is the fix.

### Man-page highlighting is exported empty

`private_dot_config/private_fish/exports.fish:37`

```fish
set -gx LESS_TERMCAP_md $yellow
```

`$yellow` is set nowhere in this repository, so the variable is exported empty
and nothing is highlighted. A real value is an escape sequence, for example
`(set_color -o yellow | string collect)`.

### The greeting's disk-usage line matches nothing

`private_dot_config/private_fish/greet.fish:13`

```fish
df -l -h | grep -e 'dev/(xvda|sd|mapper|disk)'
```

`grep -e` takes a basic regular expression, where `(`, `)` and `|` are literal
characters, so the pattern matches no line. The "Disk usage:" heading above it
prints on every new shell with nothing under it. `grep -E` makes the alternation
work.

### `gen-chisel-template` fails on both of its `sed` calls

`private_dot_config/private_fish/functions/gen-chisel-template.fish:38-39`

```fish
sed -r -i "s/%NAME%/$proper_name/" build.sbt
sed -r -i "s/%ORGANIZATION%/$proper_name" build.sbt
```

Line 39 is missing its closing `/`, so sed exits with a syntax error. Both lines
use GNU syntax: BSD sed on macOS reads `-i` as taking a backup suffix and
consumes the next argument. `sed -E -i ''` is the portable form on macOS.

## Git and SSH

### `signOff` does not apply to commits

`private_dot_gitconfig:86`

```ini
[format]
	signOff = yes
```

`format.signOff` adds `Signed-off-by` to `git format-patch` output. It has no
effect on `git commit`; there is no config that adds the trailer to every
commit. A `prepare-commit-msg` hook, or `commit.template`, is the usual route.

### The SSH config names a key this repository does not deploy

`private_dot_ssh/config:4`

```
IdentityFile ~/.ssh/id_ed25519
```

The repository deploys `gh_sign` and `gh_sign.pub`; `config.fish` loads
`gh_sign` into the agent and the gitconfig signs with `gh_sign.pub`. Nothing
creates `id_ed25519`.

`UseKeychain yes` on line 3 is macOS-only, and this file is not in the non-darwin
block of `.chezmoiignore`, so it deploys to Linux where OpenSSH rejects it as a
bad configuration option.

### `dot_bashrc` breaks on any machine without eza or starship

`dot_bashrc:1-4,8`

`alias ls="eza"` with `l`, `ll` and `la` built on top means all four fail
together, with an error naming `eza` rather than `ls`. Line 8 runs
`starship init bash` unguarded and errors on every bash login where starship is
absent. Both want a `command -v` guard.

Separately, `04-setup-fish` appends `exec …/fish` to `~/.bashrc` on the no-sudo
Linux profile, and chezmoi manages that file from `dot_bashrc` — so the next
apply removes the line and the profile stops starting fish.

## Dead code

- `private_dot_config/private_fish/functions/__ssh_agent_is_started.fish` and
  `__ssh_agent_start.fish` read and write `$SSH_ENV`, which nothing sets, and
  neither function is called anywhere. `config.fish` loads the key with
  `ssh-add` directly.
- `private_dot_config/private_fish/functions/symlink_fzf_key_bindings.fish` is
  not a function. It contains one path and defines nothing.
- `private_dot_config/private_fish/functions/restart-wifi.fish` hardcodes the
  `brcmfmac` driver and ends with `sudo nmcli device`, which lists devices
  rather than restarting anything. `reboot-keyboard.fish` is X11-only. Both are
  Linux-only in a repository whose primary target is macOS.
