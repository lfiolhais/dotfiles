# dotfiles

macOS is the primary target. Linux is supported in two profiles, chosen by the
`sudo` prompt at `chezmoi init` time: **with sudo**, where apt or dnf installs
everything, and **without sudo**, where [mise](https://mise.jdx.dev) installs a
rootless toolchain under `~/.local`.

## Handy Scripts and Tools

### Fish Shell

* `update` => updates the machine afterwards, walking whichever package
  managers it finds (brew and mas, apt or dnf, mise, rustup, uv), then silences
  any newly installed app's own updater with `cask-updates` on macOS.
* `get_contact` => searches a contact in khard's database through fzf.
* `khard-rm` => deletes contacts in khard. Will pop an fzf window and allow you
  to select the contacts to delete.
* `khard-track` => updates chezmoi's khard's state. Runs `chezmoi add
  ~/.config/khard/work/default`.

### Git

* `executable_git-wt-clone` => git subcommand to clone a repository as a bare
  clone plus per-ref worktrees. Can be used as `git wt-clone <URL> [DIRECTORY]`;
  without a directory the folder is named after the repository. The worktree for
  the default branch is created straight away, tracking `origin`.

* `executable_git-wt-add` => git subcommand to add a worktree to a repository.
  Can be used as `git wt-add <BRANCH|REF|TAG>`. Will create a branch
  automatically if it doesn't exist. A branch that already exists on `origin`
  tracks it; a tag or commit is checked out detached; a brand-new branch is left
  with no upstream, so `git push` (with `push.autoSetupRemote`) publishes it as
  `origin/<branch>` rather than refusing because the branch it forked from is
  named something else.

### Packages

* `chezmoi-packages` => adds, removes and looks up the packages these dotfiles
  install, keeping the Brewfile and the Linux manifest in sync. Finds the source
  directory through `chezmoi source-path`, so it runs from anywhere. See
  [Packages](#packages) below.

* `cask-updates` => stops the apps Homebrew installed from updating themselves,
  so `brew` stays the only thing that moves their versions. macOS only; run by
  `update` on every macOS run. See
  [Keeping Homebrew in charge of app versions](#keeping-homebrew-in-charge-of-app-versions)
  below.

### NAS

* `mount-nas` => mounts the `Book2` share from `nas.botasal.xyz` whenever the
  NAS is reachable, clears the mount when it stops answering, and does nothing
  at all otherwise. macOS only; a LaunchAgent runs it on every network change.
  See [Mounting the NAS](#mounting-the-nas) below.

## Packages

The packages installed by the dotfiles reside in two files:

| file | holds |
| --- | --- |
| `private_dot_config/Brewfile` | what macOS installs — formulae, casks, Mac App Store apps |
| `.chezmoidata/packages.toml` | what each Linux target calls the same tool, or why it is not installed there |

The goal is to always keep both files in sync. They are not the same kind of
file, though, and that decides who writes them:

- the **Brewfile is derived** — `brew bundle dump` writes it from what the Mac
  actually has installed, descriptions and taps and casks and Mac App Store apps
  included. Nothing else should edit it; the next dump would undo the edit
  anyway.
- the **manifest is authored** — it records a decision (what Linux calls this,
  or why Linux does without it) that no machine can be asked for.

To avoid overcomplicating the dotfiles, we ignore tool's that aren't natively
supported by the distro's package manager. This is done to avoid keeping track
of the multiple repos tools live and their "recommended way" of installing
them. There are two exceptions: `gh` (from GitHub's own apt/dnf repository) and
`starship` (from its installer), because neither is in any base repository and
starship is the shell prompt.

The Linux packages are kept in `.chezmoidata/packages.toml`, one entry per tool:

```toml
[packages.<NAME>]
brew = "<HOMEBREW_NAME>"
apt = "<APT_NAME>"
fedora = "<DNF_NAME>"
el = "<RHEL_NAME>"
mise = "<MISE_NAME>"
note = "Anything surprising about the above."
```

A target that isn't named doesn't install the tool.

Both files are handled with `chezmoi-packages`, a deployed command under
`~/.local/bin`.

| command       | description                                                               |
| ---           | ---                                                                       |
| `search NAME` | ask every platform's real repositories what a tool is called there        |
| `add NAME`    | install it, re-dump the Brewfile, and write its `[packages]` entry        |
| `remove NAME` | uninstall it, re-dump the Brewfile, and drop its entry                    |
| `dump`        | refresh the Brewfile from this Mac, then say what the manifest still owes |

`add` and `remove` drive both ends on purpose: a package that is only half
removed — gone from the manifest but still installed, still in the Brewfile — is
exactly what `tests/check.py` fails on. Use `--no-install` / `--no-uninstall` to
edit the manifest alone (the tool is already there, or this is not a Mac).

The manifest is **generated**: every edit rewrites it from the header in
`chezpkg_manifest.py` and one table per entry, so a comment written into it by
hand will not survive. Annotations belong in `note`. Writing TOML is the one
thing the standard library cannot do and Homebrew packages no writer for, so the
command's shebang runs it through `uv`, which fetches `tomlkit` (~6 ms warm) and
supplies the interpreter.

### Adding a package

Don't guess at names — ask:

```sh
chezmoi-packages search ripgrep
```

That queries Homebrew and mise on this machine and each distro's real
repositories in throwaway containers, prints what every platform calls the tool,
and then prints the command to run:

```sh
chezmoi-packages add ripgrep --apt ripgrep --fedora ripgrep --el ripgrep --mise ripgrep
```

which installs it with Homebrew, re-dumps the Brewfile, and records the entry.
`--brew` names the formula when it differs from the tool (a tap-qualified name);
`--no-brew` records a Linux-only tool that macOS never installs. Then verify,
from the source directory (`chezmoi cd`):

```sh
python3 tests/check.py    # the two files still agree
python3 tests/linux.py    # every name really resolves in the repo it claims
```

`tests/linux.py` is the one that catches a wrong name: it asks apt and dnf
whether each package exists, without installing anything. If a distro turns out
not to have the tool, drop that field and re-run.

### Adding a cask

A cask is not a manifest entry. `.chezmoidata/packages.toml` accounts for
`brew` and `uv` entries only — the CLI tools the Linux profiles mirror — so
`tests/check.py` never asks a cask to be claimed, and `chezmoi-packages add`
(which always writes an entry) is the wrong verb for one. Two steps:

```sh
brew install --cask ghostty
chezmoi-packages dump      # the only sanctioned path to the Brewfile
python3 tests/check.py
```

Removing one *is* covered: `chezmoi-packages remove ghostty` finds the
`cask "ghostty"` line, uninstalls it, and re-dumps. If the new app embeds
Sparkle it will be silenced by the next `update` run — `cask-updates disable`
does it immediately (see *Keeping Homebrew in charge of app versions* below).

### Removing a package, or not installing one

```sh
chezmoi-packages remove gurk                          # off the Mac, the Brewfile, and the manifest
chezmoi-packages add dockutil --note "drives the macOS Dock"   # macOS keeps it, Linux never gets it
```

`remove` uninstalls by whatever route the Brewfile used — `brew uninstall` for a
formula or a cask, `uv tool uninstall` for a uv tool, both when the Brewfile
lists both — then re-dumps and drops the entry. Every `brew`/`uv` entry in the
Brewfile must be claimed by a manifest entry, and `tests/check.py` fails
otherwise; that is what stops a `brew bundle dump` on the Mac from quietly
widening the gap between the two files.

### Looking names up by hand

`search` is a convenience, not the only route:

```sh
brew search --formula NAME
apt-cache search --names-only NAME     # Debian/Ubuntu
dnf repoquery --qf '%{name}' '*NAME*'  # Fedora/RHEL
mise registry | grep NAME
```

For cross-distro lookups without a container, [pkgs.org](https://pkgs.org) and
[repology.org](https://repology.org) show every distro's name for a project side
by side.

## Keeping Homebrew in charge of app versions

Most casks ship the vendor's own updater — **29 of the 41 installed casks
declare `auto_updates true`** — so an app quietly replaces itself and the
Caskroom ends up describing a version that is no longer on disk. The next
`brew upgrade --greedy` then reinstalls it, or walks it *backwards* when the
vendor's updater got there first.

Homebrew has no switch for this; it ships the vendor's binary as-is. What works
is Sparkle, the update framework most Mac apps embed: it takes its
automatic-check settings from the app's own user-defaults domain, where they
beat the same keys inside the bundle. `cask-updates` writes them.

```sh
cask-updates status     # what self-updates, and what is already silent
cask-updates disable    # silence the Sparkle apps Homebrew owns (--dry-run works)
cask-updates enable     # undo it
```

`update` runs `disable` on every macOS run, so a cask installed since the last
one is caught automatically. Nothing inside an app bundle is touched, so no code
signature is disturbed and `enable` puts every app back exactly as it was found
— the keys are deleted, not set true.

What it covers, honestly:

| | count | |
| --- | --- | --- |
| silenced | 17 | every Sparkle app Homebrew owns |
| exempt | 5 | adguard, little-snitch, proton-mail-bridge, protonvpn, tor-browser |
| beyond reach | 7 | google-chrome, signal, claude, drawio, zoom, busycal, shottr |

The exempt five are a deliberate choice: security tools ship fixes on their own
schedule, and the gap until the next `update` is real exposure for a firewall, a
VPN, or a hardened browser. Edit `EXEMPT` in
`dot_local/lib/python/caskupd_app.py` to change your mind.

The other seven update through Keystone, Electron or their own installer, none
of which expose a preference key worth chasing. `status` lists them by name
rather than quietly implying they are handled; `brew upgrade --greedy` still
owns their versions whenever it wins the race.

Apps installed by hand are never touched — Homebrew does not know about them, so
nothing else would ever update them.

## Mounting the NAS

`nas.botasal.xyz` serves the share `Book2` over SMB. It should be mounted
whenever the network allows and absent, without comment, when it does not — no
authentication sheet, no connection-failed alert, and no "the server connection
was interrupted" dialog after leaving the house.

```sh
mount-nas             # mount when reachable, unmount when not (what launchd runs)
mount-nas status      # reachability, Keychain, and where the share is
mount-nas mount       # mount now, saying why if it cannot (--dry-run works)
mount-nas unmount     # unmount now
```

Staying quiet takes three guards, because three separate things raise a dialog:

* Nothing is attempted until TCP 445 on the NAS answers, so away from home the
  whole thing is a no-op. Testing the port rather than the network name means
  Ethernet and VPN count as being home just as Wi-Fi does.
* `mount volume` raises an authentication sheet when the login Keychain holds no
  password for the server, so the Keychain is consulted first and a missing
  entry is a reason to do nothing rather than a reason to ask.
* A mount whose server has vanished produces interrupted-connection alerts until
  it is cleared, so an unreachable NAS that is still mounted is force unmounted.

### The one manual step

The password lives in the login Keychain and nowhere in this repository. Until
it is seeded the agent mounts nothing and says nothing:

```sh
security add-internet-password -r "smb " -s nas.botasal.xyz -a lfiolhais \
  -D "Network Password" \
  -T /System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthAgent \
  -U -w
```

Then `mount-nas status`, which should report the password present.

`-w` comes last with no value so `security` prompts for the password instead of
taking it from the command line, where it would reach `ps` and the shell
history. `-T` names NetAuthAgent because that is what actually reads the item:
`mount volume` hands the authentication to it, and an item created by `security`
is otherwise trusted only by `security`. Should the first mount raise a Keychain
prompt anyway, Always Allow grants the same access permanently.

Connecting once through Finder -> Go -> Connect to Server ->
`smb://nas.botasal.xyz/Book2` writes an equivalent item. Type that URL rather
than picking the NAS out of the sidebar: the item records whatever name was used
to connect, `mount-nas` looks it up by `nas.botasal.xyz`, and a mismatch means
the agent finds no password, mounts nothing, and says nothing about it.

`mount-nas status` is what distinguishes that from an ordinary evening away, so
it is the first thing to run when the share is not appearing.

### What runs it

`~/Library/LaunchAgents/xyz.botasal.mount-nas.plist` runs `mount-nas` at login,
on every write to `/var/run/resolv.conf` — which macOS rewrites on every network
transition, so the agent fires on joining a network rather than polling for one
— and every 300 seconds as a backstop for wake-from-sleep. The `07` bootstrap
script loads it, and reloads it whenever the plist changes.

It appears under System Settings -> General -> Login Items & Extensions as a
background item and has to stay enabled. It is a user agent rather than a
`/Library/LaunchDaemons` job because a root daemon can read neither the login
Keychain nor mount into the login session.

`mount-nas` prints nothing while nothing is wrong, so `~/.local/state/mount-nas.log`
stays empty and a line in it is always worth reading.

### Checking the NAS itself

A wrong hostname produces exactly the same silence as being away from home.
`tests/nasprobe.py` tells the two apart by asking the server what it is:

```sh
python3 tests/nasprobe.py
```

It prints the SMB dialect the server negotiates, and fails with a reason when
the name does not resolve, the port is closed, or something that is not an SMB
server answers.

## Testing

There is no build. "Testing" a change means `chezmoi diff`, then the harness:
`tests/check.py` on the host, `tests/linux.py` for the Linux targets in Docker,
`tests/macos.py` for macOS in a Lume VM. See [tests/README.md](tests/README.md),
which also covers the `pre-push` hook that runs `check.py` before a push to
`main`:

```sh
git config core.hooksPath tests/githooks
```
