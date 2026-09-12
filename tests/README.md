# Test harness

Other machines pull `main`, so a broken `main` breaks them. These are what stands
between a change and that: `render-matrix.sh` parses every template for every
profile in seconds, `check.py` validates the current host, `linux.py` the Linux
targets, `macos.py` a clean macOS. None of them is run automatically except
through the `pre-push` hook at the end of this file.

Only `check.py` exercises the real age key. The container and VM harnesses run
`chezmoi archive --exclude encrypted`, since neither has the key, so a change to
an encrypted file is validated on the host and nowhere else.

## `check.py` — host harness

```sh
python3 tests/check.py
```

It needs Python 3.11 or newer (it uses `enum.StrEnum`), `ruff`, `shellcheck`,
`fish`, `chezmoi`, and a working age key. Homebrew and `uv` are optional: their
checks are skipped or advisory when absent. It runs on macOS and Linux, performs
no destructive action, and never runs the `run_*` scripts.

It:

- renders the whole source with `chezmoi archive`, proving templates, age
  decryption and ignores all work;
- confirms the repo-only files — the agent instructions, the licence, the
  encrypted age key and `tests` itself — stay out of the target;
- lints every `run_*` script. `bash -n` and `shellcheck --severity=error` are
  hard failures; `--severity=warning` is advisory. This is OS-aware: a script
  gated off for the current OS renders empty and is skipped, and `linux.py`
  covers those;
- lints the deployed shell that is not a `run_*` script — `dot_bashrc.tmpl`,
  aerc's filter scripts, notmuch's `post-new` hook. `_scripts()` finds only
  `run_*` at the repo root, so these are listed by hand in `SHELL_FILES`, and an
  rc file with no shebang carries a `# shellcheck shell=` directive instead;
- parses every fish file under `private_dot_config/private_fish/` with
  `fish -n`, rendering the templates first. fish is the login shell, so a parse
  error here is what every new terminal opens with, and nothing else checks it:
  ruff does not read fish and shellcheck refuses it;
- hands the rendered ssh config to `ssh -G` and the rendered gitconfig to
  `git config --list`, so the programs that read them are what say whether they
  are valid. ssh rejects a whole config file over one option it does not know,
  which stops every ssh on the machine rather than one host;
- refuses a compiled binary or a program-written file anywhere in the source. A
  binary is built for one architecture and one OS, and chezmoi copies it
  unchanged to every machine; `BINARY_MAGIC` is the ELF and Mach-O magics and
  `GENERATED_NAMES` the filenames — `.DS_Store` and the like — that no source
  directory should carry;
- checks the Brewfile, skipping it when `brew` is absent. `mas` entries are left
  out of that check: verifying one runs `mas list`, which talks to the App Store
  and hangs until the harness's timeout when there is no network;
- asks Homebrew whether it still installs every formula and cask the Brewfile
  names. Homebrew disables what it can no longer install — an app that stopped
  passing Gatekeeper, an upstream that went away — and `brew bundle install`
  exits non-zero on it, which stops `01-install-packages` and with it the whole
  apply. This Mac is the last place that shows, because the package is installed
  here already and `brew bundle check` passes; the machine that finds out is the
  next fresh one. A disabled entry fails the harness, a deprecated one warns.
  Fixing it means dropping the entry from the Brewfile and uninstalling the
  package here, since `chezmoi-packages dump` writes back whatever is installed;
- checks the Brewfile against `.chezmoidata/packages.toml`. Every `brew "…"` and
  `uv "…"` entry must be claimed by a `[packages]` entry through its `brew`
  field, which is what stops a `brew bundle dump` on the Mac from silently
  widening the macOS/Linux gap. It also fails on a manifest entry naming a
  formula the Brewfile does not have, on an entry that installs nowhere on Linux
  and gives no reason, on a misspelled field name, and on two entries claiming
  the same `mise` tool, which would render a duplicate key into the generated
  mise config. These rules live in `Manifest.problems`
  (`dot_local/lib/python/chezpkg_manifest.py`), the same code `chezmoi-packages`
  reports from, so the harness and the command cannot disagree about what
  agreement means. It is pure text, so it runs on Linux too;
- lints this repo's Python with `ruff` (rules in `tests/pyproject.toml`): the
  harness, every module in `dot_local/lib/python/`, and every entry point in
  `dot_local/bin/`. Those sit outside `tests/` and the entry points have no `.py`
  extension, so they are passed by path with an explicit `--config`. The library
  modules are globbed rather than listed, so splitting one in two keeps it
  covered; a new entry point has to be added to `DEPLOYED_ENTRY_POINTS`;
- imports each deployed library (`caskupd`, `gitwt`, `linux_distros`,
  `mountnas`) and runs the four stdlib entry points' `--help` under every
  `python3` on the host — `chezmoi-packages` is excluded here and exercised
  through uv below, since uv supplies its interpreter — `which python3`, `/usr/bin/python3`, and the interpreter running the
  harness, deduplicated. `ruff` never executes anything, so this is what catches
  an import cycle, a stale call, or a construct too new for the oldest supported
  interpreter: 3.9, on both a fresh macOS and the RHEL rebuilds. `--help` makes
  argparse exit before any git command runs, so nothing is written. A host with
  no `python3` at all is a warning;
- runs `tests/mountnas.py`, the unit tests for what `mount-nas` decides. Note the
  name: the tests are `tests/mountnas.py`, the library they exercise is
  `dot_local/lib/python/mountnas.py`. They stub out the network and every
  subprocess, so no mount is started and no Keychain is read, and the harness is
  safe to run with the share mounted and away from home alike. Most of what they
  assert is a command not being run, since the point of `mount-nas` is to raise
  no dialog;
- runs `chezmoi-packages --help` through `uv run --script`, which is how that
  command really runs: its shebang is a PEP 723 script, so uv supplies both the
  interpreter and `tomlkit`. This proves the dependency block resolves and that
  `chezpkg` imports under the interpreter uv picks. A host without `uv` is a
  warning;
- prints a `chezmoi apply --dry-run` diff to review.

It ends with `All checks passed. Review the dry-run diff above, then push.` and
exit code 0, or `FAILED — fix the issues above before pushing to main.` and exit
code 1.

## `render-matrix.sh` — every profile, in seconds

```sh
bash tests/render-matrix.sh                 # every template
bash tests/render-matrix.sh dot_bashrc.tmpl # one or more source-relative paths
```

Needs `chezmoi`, and uses `shellcheck` and `fish` where they are installed. It
renders every template for all three profiles — darwin, linux with sudo, linux
without — and parses the result: `bash -n` and `shellcheck` for shell, `fish -n`
for fish. A template gated off for a profile renders empty, and chezmoi skips an
empty `run_` script, so empty is a pass.

chezmoi fills `.chezmoi.os` from the machine it is running on, so the OS cannot
be chosen through data. Each template is copied with `.chezmoi.os` rewritten to a
`.fakeos` data variable, which is supplied alongside `.sudo`; everything else
about the render is the real one.

That substitution is the limit of what it proves. It says the other OS's branch
renders and parses. It does not run a Linux chezmoi and knows nothing about that
machine's package names or its `osRelease` — `linux.py` answers those, in
containers, and is the authority. This one needs no Docker and takes seconds, so
it is the one to run while editing.

## `linux.py` — Docker matrix

```sh
python3 tests/linux.py          # render + lint every target
python3 tests/linux.py --full   # also run the real bootstrap in-container
```

Runs from any machine with Docker, macOS included. It crosses every distro in
`IMAGES` — Ubuntu, Fedora, and the RHEL-family rebuilds Rocky Linux and
AlmaLinux — with sudo and no-sudo, and spins up a throwaway
container per distro-and-sudo combination (`tests/docker/entrypoint.sh`). `--full` is the only flag:
there is no way to select one target or resume a run.

Besides rendering and linting, the entrypoint asks the package manager whether
every name the manifest targets at that distro resolves (`apt-cache show`,
`dnf info`), installing nothing. This is what makes the strict, one-transaction
install in the `01` bootstrap script safe, since a name that does not exist would
otherwise abort the whole bootstrap on a real machine. It runs on the sudo target
of each distro only: the names do not vary with the sudo flag, and the no-sudo
profile's mise names are exercised by `mise install` under `--full`.

A failure lists the offending names. The manifest is generated, so correct them
by re-running `chezmoi-packages add` with the right flags rather than editing
`.chezmoidata/packages.toml`:

```sh
chezmoi-packages add ripgrep --no-install --apt ripgrep --fedora ripgrep --mise ripgrep
```

`--full` on the sudo targets installs the full toolchain, TeX included: expect
several gigabytes and a long run.

`--full` also needs `GITHUB_TOKEN` in the environment. The no-sudo profile
installs its toolchain with mise, which resolves most tools from GitHub releases;
unauthenticated that is 60 API requests an hour for the whole host, which the
no-sudo profile across every image in `IMAGES` exhausts. A token needs no scopes — it only raises the rate
limit — so `gh auth token` is enough. `linux.py` forwards the variable into each
container when the environment has it. In fish:

```fish
set -x GITHUB_TOKEN (gh auth token)
python3 tests/linux.py --full
```

Without one, mise reports `mise WARN GitHub rate limit exceeded` followed by
`mise ERROR Failed to install tools`; the limit resets on the hour, and the whole
eight-target run has to start again.

Packages are edited with `chezmoi-packages`, a deployed command
(`dot_local/bin/executable_chezmoi-packages`) documented in the Packages section
of the top-level [README](../README.md). It shares this harness's distro matrix:
`IMAGES` comes from `dot_local/lib/python/linux_distros.py`, which `linux.py`
imports rather than spelling out, so adding a distro is one edit.

## `macos.py` — Lume VM matrix

```sh
python3 tests/macos.py               # render + lint the darwin scripts in a macOS VM
python3 tests/macos.py --only tahoe  # one image only
python3 tests/macos.py --keep        # reuse the VM between runs instead of recreating it
python3 tests/macos.py --full        # also run the real bootstrap in-guest
python3 tests/macos.py --build-base  # pull each base VM once; runs then clone it offline
```

The macOS analogue of `linux.py`. Docker cannot run macOS, so this uses
[Lume](https://cua.ai/docs/lume) — an MIT-licensed CLI over Apple's
Virtualization framework — to boot a throwaway VM per image in `IMAGES`, share
the repo read-only, and run `tests/lume/entrypoint.sh` over `lume ssh`. The
entrypoint fetches chezmoi, shellcheck and age as static arm64 binaries into
`~/.local/bin`, needing no package manager and no sudo, generates a fresh age
key, renders with `--exclude encrypted`, and lints the darwin bootstrap scripts.
`--full` additionally runs the real `chezmoi apply`, which is heavy: Homebrew
bundle, `defaults write`, dockutil, the launchd agent. Two things a person at a
keyboard would answer stand between that bootstrap and an unattended run, and
the entrypoint answers both inside the throwaway guest before the apply starts:

- administrator sudo. Homebrew's installer chowns `/opt/homebrew` and
  `02-setup-darwin` opens with `sudo -v`, and the image's `lume` user is an admin
  whose sudo wants the account password that `lume ssh` has no terminal to type
  at. The entrypoint authenticates once with it (`lume`, the trycua images'
  published default; `LUME_PASSWORD` overrides it) and installs a
  `/etc/sudoers.d` NOPASSWD rule.
- the login shell. `04-setup-fish` makes fish the login shell with `chsh`, which
  asks for the account password on that same absent terminal, and there is no way
  to answer it: `chsh` links Open Directory rather than PAM, so there is no PAM
  service to relax, and it takes no password on any flag or on stdin. What `04`
  compares is what Open Directory records, so the entrypoint records the answer
  first — `dscl . -create /Users/<user> UserShell /opt/homebrew/bin/fish` — and
  `04` then has nothing to prompt for. This is the one step of the bootstrap a
  `--full` run does not exercise: the check below says the login shell is fish,
  which it is, but the guest is what made it so.

The guest has no App Store account, so the App Store entries are skipped through
`HOMEBREW_BUNDLE_MAS_SKIP` — by id, since the names have spaces and that variable
is split on whitespace. What `01`'s App Store pass does on a machine that is
signed out is in `TODO.md`, unanswered: a VM cannot answer it, and this Mac is
signed in.

It then reports what the guest brings, so that a later failure has its cause
already on screen: the Xcode command-line tools, without which `setup-xcode-cli`
waits on a GUI installer; Rosetta 2, which that same script exits 1 without; and
whether the account is logged in to a GUI session, which `03-setup-dock` needs to
reach the Dock and `07-setup-nas` to bootstrap into `gui/<uid>`.

After the apply it asks the machine what the bootstrap produced, because a script
exiting 0 is not evidence that its work happened — `03-setup-dock` ends in an
`echo` that hides a `dockutil` failure, and 01's App Store half reports without
stopping:

| what is asked | what it proves |
| --- | --- |
| `brew bundle check` over the Brewfile without its `mas` lines | 01 installed every formula and cask |
| the login shell in Open Directory is the installed fish | the machine ends up with fish as its login shell, which the guest pre-set |
| a login fish prints nothing | every file it sources parses and every command it calls is installed |
| `bat --list-themes` names the theme bat's config selects | 05 built the cache from the deployed themes |
| `launchctl print gui/<uid>/xyz.botasal.mount-nas` | 07 loaded the agent |
| `colorize` and `wrap` are executable | 09 found a compiler and built the filters |
| `dockutil --list` names Ghostty | 03 reached the Dock |
| `chezmoi status` prints nothing | every target matches the source |

The run ends with a `--full summary`: the brew formula and cask counts, the
`chezmoi apply` exit code, and how many of those checks failed. A failed apply
exits with its own code and a clean apply with a failed check exits 1, so either
way `macos.py` ends `FAILED: tahoe`. A run that passes has every check `ok`,
`chezmoi apply: ok`, `checks: 0 failed`, and ends `All macOS targets passed.`

Two things a passing run does not cover, both named above: `04-setup-fish`'s
`chsh`, whose answer the entrypoint records beforehand, and the App Store half of
`01`, whose entries are skipped.

`lume ssh` hands over the remote command's output only when that command exits,
which for `--full` would be an hour with nothing on screen. So the guest tees
everything into a second shared directory, `~/Library/Logs/chezmoi-macos-tests`,
mounted read-write while the repo stays read-only, and the run prints that file
as the guest writes it. The same file is there to `tail -f` from another
terminal, and it outlives a dropped connection. When nothing has appeared for two
minutes the run says so, with the elapsed time and what the guest's processor is
on — a second `lume ssh` asks. Several steps are legitimately quiet:
`02-setup-darwin` rebuilds the LaunchServices database with `lsregister -kill
-r`, which prints nothing for minutes while it re-registers every application
just installed, and a large cask downloads before it writes anything. Naming the
busiest process is what tells those apart from a run waiting on something.

`<vm>.lume.log` beside it holds what lume itself said, which is what to read when
the guest log stays empty.

The heartbeat also says how much the guest's disk image has grown since the last
one, read from the host rather than asked of the guest. `brew` buffers its output
into chunks when it is not writing to a terminal, so a run installing gigabytes
prints nothing for minutes at a time; growth is what tells that apart from a run
that has stopped.

The guest boots into a logged-in GUI session, so an installer that opens a window
and waits for a click stops the bootstrap dead with nothing on stdout. `lume
attach <vm>` opens a viewer on that desktop, and a dialog sitting there is the
answer. A cask that cannot be installed without one is skipped the way the App
Store entries are, through `HOMEBREW_BUNDLE_CASK_SKIP`.

The in-guest run is given two hours, after which the harness asks the guest what
it is running, prints that, ends the ssh and fails the target. `lume ssh` has no
timeout of its own here — a bootstrap cannot be told how long it is allowed to
take — so without that a guest waiting on something that never arrives holds the
terminal for as long as it is left open. Two hours is roughly three times a
bootstrap on a host with memory to spare; a Mac whose memory is already spoken
for slows the guest down enough to matter, and `vm_stat` on the host is where
that shows.

A cask Homebrew has disabled stops all of this at `01`, since `brew bundle`
exits non-zero on it and the script treats that as fatal. `check.py` asks
Homebrew about every Brewfile entry, so that failure is a few seconds on this Mac
rather than an hour into a VM run.

Lume is the only host dependency. It ships its own `lume ssh` with the images'
default `lume`/`lume` credentials, so there is no ssh password plumbing:

```sh
/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"
```

Each run recreates the VM and deletes it afterwards, with a pre-run clear-out for
one an interrupted run left behind. That stops the VM before deleting it, and
removes the directory as well: `lume delete --force` unregisters a VM that is
still running but leaves its directory in place, and the next `lume clone` then
refuses the name with `Directory already exists`. The directory is only removed
once `lume ls` has stopped listing the VM, so nothing that lume still owns is
touched. It recreates by cloning a
`chezmoi-test-base-<image>` VM when one exists — a local copy-on-write, no
network — so once `--build-base` has pulled that base VM, every later run works
offline, and `lume prune` can then reclaim the layer cache. Run `--build-base`
again to refresh the base to a newer image. Without a base, a run falls back to
`lume pull`.

`macos.py` enables Lume's image layer cache (`lume config cache enable`; Lume
ships with it off) so a fallback `lume pull` re-streams the image only once; the
cache and the setting persist, and `lume prune` / `lume config cache disable`
undo them. `--keep` leaves the run VM stopped and reuses it next time, saving the
clone, the cold boot and — the expensive part — re-downloading every package,
at the cost of the throwaway guarantee. That is the flag to iterate with once a
run has reached the bootstrap: the packages stay installed, so a re-run is back
where it stopped in a couple of minutes. `01` is a `run_once_` script that
chezmoi records only on success, so a re-run runs it again. What `--keep` cannot
report is a clean machine, so the run that counts is a final one without it.

The guest raises `HOMEBREW_CURL_RETRIES` to 5. A guest behind Lume's NAT drops a
long download more often than the host does, and one cask that cannot be fetched
fails `brew bundle`, `01`, and with it everything after. Apple Silicon only;
the base VM disk, each clone, and the layer cache are large sparse files — budget
well over 50 GB free.

`IMAGES` at the top of `macos.py` holds Tahoe alone, and `--only` accepts only
what is in it. Tahoe is the only family packaged as Lume's native
`vnd.trycua.lume.disk.v1` layers; `macos-sequoia-*` tags ship their disks as
generic `application/vnd.oci.image.layer.v1.tar`, which Lume does not
reassemble — it logs `Skipping unsupported cached layer media type` for every
layer, finds `0 lz4 disk parts`, and then fails with the misleading
`Virtual machine not found: <name>`. Adding a Sequoia tag reproduces that.

This harness needs a GUI login session. `lume run` starts a VNC server, which
macOS's Local Network privacy gate blocks outside one: the crash is inside
Apple's Virtualization framework (`_VZVNCServer _setupVirtualMachineAccessor` →
`assertion_trap()`), and `lume get` then reports `ssh=no` for a guest whose sshd
is running and reachable from an ordinary shell. Run it from a terminal on the
machine's own desktop rather than from an automation context, and the published
image boots, has Remote Login enabled, and `lume ssh` connects with no
credentials.

## `nasprobe.py` — the NAS hostname

```sh
python3 tests/nasprobe.py
python3 tests/nasprobe.py --host other.example.com --port 445
```

The host and port in `mountnas.py` are the two facts nothing else checks: the
unit tests stub the network out, and a wrong hostname produces exactly the same
silence as being away from home. This sends an SMB2 NEGOTIATE and prints the
dialect the server picks:

```
nas.botasal.xyz:445 reached directly
  SMB 3.0.2 (dialect 0x0302), signing enabled
```

Anything else is reported with its reason: the name did not resolve, the port
refused the connection, or something that is not an SMB server answered.

Dialects are offered up to 3.0.2 rather than 3.1.1, because a 3.1.1 offer must
carry negotiate contexts and a server answers `STATUS_INVALID_PARAMETER` without
them — a valid SMB2 reply that reads as a failure.

It connects directly when it can and tunnels through the SOCKS5 proxy named in
`$ALL_PROXY` when a direct socket is refused, so it also works from a sandbox
that blocks raw sockets and DNS.

It is standalone rather than one of `check.py`'s checks so that the pre-push hook
passes away from home; a check that failed whenever the NAS was out of reach
would be switched off within a week.

## `pre-push` git hook

`tests/githooks/pre-push` runs `check.py` and blocks a push that updates
`refs/heads/main` when the harness fails. It only checks — it is separate from
`check.py`, which never touches git. `core.hooksPath` is a local git setting and
is not version-controlled, so enable it once per clone:

```sh
git config core.hooksPath tests/githooks
```

The hook runs `check.py` under the same interpreter git invoked it with, so on a
host whose `python3` is older than 3.11 it reports `pre-push: BLOCKED — harness
failed` for an interpreter mismatch rather than for anything in the change. Run
`python3 tests/check.py` directly to see which it is.

`git push --no-verify` skips the hook. That is the escape hatch for a host that
cannot run the harness, and it means the next machine to pull is the one that
finds out.
