# dotfiles

This repository is a [chezmoi](https://www.chezmoi.io) source directory. The
files here are not the files that run: chezmoi renders them into `$HOME`,
applying the naming conventions below on the way. The rendered copy under
`$HOME` is overwritten on every apply, so a change made there is lost — edit the
file here and apply it.

Source filenames encode what happens to the target, which is why nothing here
looks like a dotfile:

| source                 | target                       | meaning                                            |
| ---                    | ---                          | ---                                                |
| `dot_foo`              | `~/.foo`                     | a leading dot                                      |
| `private_dot_ssh/`     | `~/.ssh`                     | target is `chmod 600`                              |
| `encrypted_x.age`      | `~/x`                        | age-encrypted here, decrypted on apply             |
| `exact_foo/`           | `~/foo`                      | target holds exactly these entries, strays deleted |
| `executable_mount-nas` | `~/.local/bin/mount-nas`     | target is `0755`                                   |
| `config.fish.tmpl`     | `~/.config/fish/config.fish` | rendered as a Go template                          |
| `run_once_…`           | —                            | script run once, tracked by content hash           |
| `run_onchange_…`       | —                            | script re-run when its own content changes         |

macOS is the primary target. Linux is supported in two profiles, chosen by a
prompt the first time chezmoi initialises the machine: with sudo, where apt or
dnf installs the toolchain, and without sudo, where
[mise](https://mise.jdx.dev) installs a rootless one under `~/.local`.
Everything is CLI-only on Linux; the macOS GUI configs and the Brewfile never
deploy there.

## Installing on a new machine

### chezmoi first

chezmoi renders the repository, so it has to exist before anything else. It
installs itself without a package manager:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin
```

On a Mac that already has Homebrew, `command brew install chezmoi` is
equivalent — `command` because the fish this repository deploys blocks a bare
`brew install`. There are no other prerequisites — the bootstrap installs everything else, including
Homebrew.

### One command

```sh
~/.local/bin/chezmoi init --apply lfiolhais/dotfiles
```

`init` clones the repository into `~/.local/share/chezmoi`, which is the source
directory and the only copy to edit. `--apply` then renders it into `$HOME` and
runs the bootstrap scripts. Add `--ssh` to clone over SSH rather than HTTPS.

Prompts interrupt it:

- On Linux, `Do you have sudo on this machine`. The answer selects the profile
  and is remembered, so a later `chezmoi init` does not ask again. Changing it
  afterwards means editing `[data] sudo` in `~/.config/chezmoi/chezmoi.toml`
  and then `chezmoi apply -v`, because the answer decides the package manager,
  how fish becomes the login shell, and whether `~/.config/mise` is deployed at
  all. Nothing uninstalls what the previous profile installed, so those packages
  stay until they are removed by hand.
- A passphrase for `key.txt.age`, which holds the age key that decrypts
  everything else. The passphrase is not in this repository and cannot be
  recovered from it. Without it, `chezmoi apply --exclude=encrypted,scripts`
  renders every unencrypted file and leaves mail, contacts and the bootstrap
  alone.

On macOS the sudo password is asked for once, at the start of `02-setup-darwin`,
which is after the whole Brewfile has installed — so the long unattended stretch
comes first and the prompt after it. `02` writes settings that need root, and
refreshes the timestamp every 60 seconds so it does not lapse mid-run.

### What the first apply changes

The bootstrap rebuilds a machine, and on a Mac already in use it is not a
reversible operation. In order:

| script                       | effect                                                                     |
| ---                          | ---                                                                        |
| `setup-xcode-cli`            | installs Xcode Command Line Tools and Rosetta 2                            |
| `decrypt-private-key`        | writes `~/.config/chezmoi/key.txt`                                         |
| `01-install-packages-darwin` | updates or installs Homebrew, then the whole Brewfile, then Rust's stable toolchain |
| `01-install-packages-linux`  | apt/dnf and the `gh`/`starship` repos, or a rootless mise                  |
| `02-setup-darwin` | rewrites preferences across the Dock, Finder, Safari, trackpad, keyboard, screenshots and Software Update, then kills the affected apps to reload them |
| `03-setup-dock`              | appends the apps it names to the Dock, leaving existing items in place     |
| `04-setup-fish`              | adds fish to `/etc/shells` and makes it the login shell with `chsh`        |
| `05-setup-bat`               | builds bat's theme cache                                                   |
| `06-setup-mail`              | prints the manual mail steps; changes nothing                              |
| `07-setup-nas`               | loads the NAS LaunchAgent and prints its one manual step                   |
| `08-setup-ssh`               | puts each deployed key's passphrase in the login Keychain; asks for it     |
| `09-build-aerc-filters`      | compiles aerc's `colorize` and `wrap` filters from their C sources         |

The whole Brewfile is installed, which takes a while — `grep -c '^brew ' ~/.config/Brewfile`
and the same for `^cask ` and `^mas ` say how much there is. The App Store part
needs the App Store already signed in; `mas` cannot sign in, so those entries
fail one by one and `01-install-packages-darwin` says so at the end without
stopping the apply. Everything else is installed first and a failure there does
stop it, because the rest of the bootstrap needs those packages.

On macOS and Linux with sudo the login shell changes for the account being set
up, and `chsh -s /bin/zsh` puts it back. Without sudo the login shell is left
alone and `~/.bashrc` starts fish instead, which is what `dot_bashrc.tmpl`
renders on that profile.

`04-setup-fish` and `08-setup-ssh` both stop and wait: the first for the account
password, which `sudo` and `chsh` each ask for, and the second for each key's
passphrase. An apply with no terminal skips the passphrases and prints the
command to run later.

Scripts that do not apply to the current OS render empty, and chezmoi skips
empty scripts, so the darwin-only entries above simply do not exist on Linux.

### Confirming it worked

```sh
chezmoi status      # prints nothing when the target matches the source
chezmoi doctor      # chezmoi's own environment check
```

`exec fish` starts the new shell without logging out.

### When a bootstrap script fails

A `run_once_` script is recorded as done, by its content hash, only when it
exits 0. Most of these set `-eu`, so they fail loudly and the next apply retries
them on its own. `01-install-packages-darwin` sets no `-e` — it has two halves
that fail for different reasons — and instead checks `brew bundle` itself: it
exits non-zero when anything but the App Store failed, so that case is retried
too, and reports an App Store failure without stopping the apply.

`02`, `03`, `06`, `setup-xcode-cli` and the decrypt script set no `-e` and are
not checked, so a command that fails inside one of them leaves the script exiting
0 and recorded. Clearing the record is what re-runs one:

```sh
chezmoi state delete-bucket --bucket=scriptState   # forget every run_once_ hash
chezmoi apply -v                                   # run them all again
```

That re-runs every `run_once_` script, so they are written to be safe to repeat.
Editing a script also re-runs it, but reverting the edit restores the original
hash and it does not run again — the state bucket is the reliable route.

`chezmoi state dump` shows what is currently recorded.

A failure decrypting the age key leaves a `~/.config/chezmoi/key.txt` that
exists but is unusable, and the existence check in the decrypt script then skips
it silently while every encrypted file fails to render. Delete the file and
apply again:

```sh
rm ~/.config/chezmoi/key.txt
chezmoi apply -v
```

## Everyday use

```sh
chezmoi diff        # what applying the source would change in $HOME
chezmoi apply -v    # render source -> $HOME, running any pending run_ scripts
chezmoi status      # files that differ between source and target
chezmoi cd          # a shell in the source directory
```

Changes flow both ways. Editing a file here and running `chezmoi apply` is the
normal direction. For a config changed by hand under `$HOME`, `chezmoi re-add`
pulls it back into the source, and `chezmoi add ~/path` starts tracking a new
file with the naming conventions applied.

`chezmoi re-add` only updates source files whose target still exists, so it
cannot express a deletion. `chezmoi forget <path>` is what drops an entry from
the source state. It also never overwrites a template, so a file whose source
ends in `.tmpl` has to be edited here by hand.

`chezmoi-sync` does the re-add and then names both of the things it could not
do — the templates, and the untracked files sitting beside tracked ones. See
[Commands](#commands).

Encrypted files are edited through chezmoi, which decrypts to a temporary file
and re-encrypts on save:

```sh
chezmoi edit ~/.notmuch-config      # not the .age blob in the source directory
```

`update` walks every package manager on the machine — brew and mas, apt or dnf,
mise, rustup, uv — skipping the ones that are absent and listing failures at the
end rather than stopping at the first. It deliberately leaves `chezmoi update`
alone, because applying dotfiles can re-run bootstrap scripts.

## Commands

These deploy to `~/.local/bin`, which is on `PATH` on every profile.

| command                    | what it does                                              |
| ---                        | ---                                                       |
| `git wt-clone <URL> [DIR]` | clone a repository as a bare clone plus per-ref worktrees |
| `git wt-add <REF>`         | check a branch, tag or commit out into its own folder     |
| `chezmoi-packages`         | maintain the Brewfile and the Linux manifest together     |
| `cask-updates`             | stop Homebrew's apps updating themselves (macOS)          |
| `mount-nas`                | keep the NAS share mounted while it is reachable (macOS)  |

`git-wt-clone` names the folder after the repository when no directory is given,
and creates the default branch's worktree straight away, tracking `origin`.
`git-wt-add` creates a branch that does not exist yet. A branch already on
`origin` tracks it; a tag or commit is checked out detached; a brand-new branch
is left with no upstream, so `git push` with `push.autoSetupRemote` publishes it
as `origin/<branch>` rather than refusing because the branch it forked from has
a different name.

The fish functions live in `~/.config/fish/functions`, one function per file,
named after the function. `functions -v <name>` prints what each one is for;
these are the ones worth knowing about:

| function        | what it does                                                          |
| ---             | ---                                                                   |
| `update`        | update every package on the machine, whatever installed it            |
| `chezmoi-sync`  | pull this machine's configuration back into the source state          |
| `brew`          | Homebrew, with the subcommands that desync the Brewfile blocked       |
| `khard`         | khard, recording every contact it writes in the source state          |
| `khard-status`  | which contacts differ between this machine and the source, by name    |
| `khard-rm`      | delete contacts and drop them from the source state                   |
| `khard-track`   | record a contact by hand (see [Contacts](#contacts))                  |
| `get_contact`   | pick a contact out of khard with fzf                                  |
| `zip`           | zip, never storing a `.git` directory                                 |

Some of those wrap a command rather than adding one, because the machine and
the source state come apart silently otherwise:

- `brew install`, `uninstall`, `reinstall`, `remove`, `tap` and `untap` are
  refused, because they change which packages exist without recording it and the
  next `chezmoi-packages dump` on another machine then removes them everywhere.
  `chezmoi-packages add`/`remove` do both halves. `command brew …` bypasses the
  guard for one command, and `set -x DOTFILES_BREW_UNGUARDED 1` for a whole
  shell — the message says both when it refuses. `brew update`, `upgrade`,
  `cleanup`, `bundle` and every query go straight through.
- `khard new`, `edit`, `add-email`, `merge`, `copy`, `move` and `modify` re-add
  the address book afterwards. `set -x DOTFILES_KHARD_UNTRACKED 1` turns that
  off for a change meant to stay on one machine.
- `zip` puts `-x '*.git*'` after the archive name, which is the only place zip
  reads it as an exclude rather than as the archive to write.

`chezmoi-sync` is the one to run after editing configuration in place. It
re-adds every managed file, then reports the two things a re-add cannot do:
files whose source is a template, which chezmoi never overwrites and which have
to be edited here instead, and files sitting inside a managed directory that
nothing tracks — the ones that disappear at the next reinstall.

```sh
chezmoi-sync            # re-add, then report what is left
chezmoi-sync --dry-run  # report only
chezmoi-sync --all      # list every untracked file rather than a few per directory
```

## Packages

Two files decide what is installed, and they are written by different hands:

| file                          | holds                                                          |
| ---                           | ---                                                            |
| `private_dot_config/Brewfile` | what macOS installs — formulae, casks, Mac App Store apps      |
| `.chezmoidata/packages.toml`  | what each Linux target calls the same tool, or why it has none |

The Brewfile is derived. `brew bundle dump` writes it from what the Mac has
installed, descriptions and taps and casks and Mac App Store apps included, so
an edit made by hand is gone at the next dump. The manifest is authored: it
records a decision — what Linux calls this tool, or why Linux does without it —
that no machine can be asked for.

A tool the distro's own package manager does not carry is not installed on
Linux, which keeps the dotfiles clear of tracking where each project publishes
its packages and what it considers the recommended way to install them. `gh` and
`starship` are the two exceptions. Fedora packages `gh` itself; Debian, Ubuntu
and the RHEL rebuilds take it from GitHub's own repository. `starship` comes
from its installer everywhere, because no base repository has it and it is the
shell prompt.

One manifest entry per tool:

```toml
[packages.<NAME>]
brew = "<HOMEBREW_NAME>"
apt = "<APT_NAME>"        # Debian, Ubuntu, Pop!_OS
fedora = "<DNF_NAME>"     # Fedora
el = "<RHEL_NAME>"        # RHEL rebuilds: Rocky, AlmaLinux, CentOS Stream
mise = "<MISE_NAME>"      # the no-sudo profile, where mise is the package manager
mise_exe = "<EXE_NAME>"   # the binary mise installs, when it differs from the tool
repo = "<REASON>"         # installed from its own repository by the 01 script
note = "Anything surprising about the above."
```

A tool is installed on the targets its entry names. An entry naming none of
`apt`, `fedora`, `el` or `mise` installs nowhere on Linux, and `note` is where
it says why — that is the whole mechanism for skipping a tool, and `tests/check.py`
fails on an entry that installs nowhere and gives no reason. It also fails on a
misspelled field name, so the list above is the complete set.

The manifest is generated: every edit rewrites the file whole, so a comment
added by hand does not survive. Annotations belong in `note`.

`chezmoi-packages` maintains both files:

| command       | description                                                               |
| ---           | ---                                                                       |
| `search NAME` | ask every platform's real repositories what a tool is called there        |
| `add NAME`    | install it, re-dump the Brewfile, and write its `[packages]` entry        |
| `remove NAME` | uninstall it, re-dump the Brewfile, and drop its entry                    |
| `dump`        | refresh the Brewfile from this Mac, then say what the manifest still owes |

`add` and `remove` drive both ends on purpose: a package that is only half
removed — gone from the manifest but still installed and still in the Brewfile —
is what `tests/check.py` fails on. `--no-install` and `--no-uninstall` edit the
manifest alone, for a tool that is already present or a machine that is not a
Mac.

`dump`, `add` and `remove` all rewrite the Brewfile from what this Mac currently
has. On a machine whose Brewfile install did not finish, that writes the shorter
list out over the full one. `git diff private_dot_config/Brewfile` shows what
changed, and `git restore private_dot_config/Brewfile` puts it back.

### Adding a package

Ask what each platform calls the tool:

```sh
chezmoi-packages search ripgrep
```

That queries Homebrew and mise on this machine, and each distro's repositories
in throwaway Docker containers. With no `docker` on PATH it reports `docker is
not available; only brew and mise will be searched` and still suggests a command
— one with no distro fields, which looks exactly like a tool no distro packages.

The check is for the command, not the daemon, so a Docker that is installed but
not running says nothing at all and returns the same empty distro fields. Start
Docker and confirm with `docker info`, which fails while the daemon is down,
before trusting an answer that names no distro package.

The output ends with the command to run:

```sh
chezmoi-packages add ripgrep --apt ripgrep --fedora ripgrep --el ripgrep --mise ripgrep
```

which installs it with Homebrew, re-dumps the Brewfile, and records the entry.
`--brew` names the formula when it differs from the tool, for a tap-qualified
name; `--no-brew` records a Linux-only tool that macOS never installs. Then
verify from the source directory (`chezmoi cd`):

```sh
python3 tests/check.py    # the two files still agree
python3 tests/linux.py    # every name resolves in the repository it claims
```

`tests/linux.py` is the one that catches a wrong name: it asks apt and dnf
whether each package exists, installing nothing. When a distro turns out not to
have the tool, remove that target from the entry — the manifest is generated, so
re-run `chezmoi-packages add` with the remaining flags rather than editing the
file:

```sh
chezmoi-packages add ripgrep --no-install --apt ripgrep --fedora ripgrep --mise ripgrep
```

### Adding a cask

A cask is not a manifest entry. The manifest accounts for `brew` and `uv`
entries only — the CLI tools the Linux profiles mirror — so `tests/check.py`
never asks a cask to be claimed, and `chezmoi-packages add` always writes an
entry, which makes it the wrong verb here. The `brew` function blocks
`install`, so reaching brew itself takes `command`:

```sh
command brew install --cask ghostty
chezmoi-packages dump      # the only sanctioned path to the Brewfile
python3 tests/check.py
```

Removing one is covered: `chezmoi-packages remove ghostty` finds the
`cask "ghostty"` line, uninstalls it, and re-dumps. An app that embeds Sparkle
is silenced by the next `update` run, or immediately with `cask-updates disable`
(see [Keeping Homebrew in charge of app versions](#keeping-homebrew-in-charge-of-app-versions)).

### Removing a package, or not installing one

```sh
chezmoi-packages remove gurk                                   # off the Mac, the Brewfile, and the manifest
chezmoi-packages add dockutil --note "drives the macOS Dock"   # macOS keeps it, Linux never gets it
```

`remove` uninstalls by whatever route the Brewfile used — `brew uninstall` for a
formula or a cask, `uv tool uninstall` for a uv tool, both when the Brewfile
lists both — then re-dumps and drops the entry. Every `brew` and `uv` entry in
the Brewfile must be claimed by a manifest entry, which is what stops a
`brew bundle dump` on the Mac from quietly widening the gap between the two
files.

### Looking names up by hand

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

Most casks ship the vendor's own updater, so an app replaces itself and the
Caskroom ends up describing a version that is no longer on disk. The next
`brew upgrade --greedy` then reinstalls it, or walks it backwards when the
vendor's updater got there first.

Homebrew has no switch for this; it ships the vendor's binary as-is. What works
is Sparkle, the update framework most Mac apps embed: it takes its
automatic-check settings from the app's own user-defaults domain, where they
beat the same keys inside the bundle. `cask-updates` writes them.

```sh
cask-updates status     # what self-updates, what is silenced, and what cannot be reached
cask-updates disable    # silence the Sparkle apps Homebrew owns (--dry-run works)
cask-updates enable     # undo it
```

`status` is the current tally; no count is recorded here, because installing one
cask would falsify it. It reads the set from `brew list --cask` and decides each
app by looking inside its bundle for Sparkle, so a cask installed since the last
run needs no list to be updated anywhere.

`update` runs `disable` on every macOS run. Nothing inside an app bundle is
touched, so no code signature is disturbed, and `enable` puts every app back as
it was found — the keys are deleted rather than set true.

Apps installed by hand are never touched. Homebrew does not know about them, so
nothing else would update them.

Casks exempt by name — adguard, little-snitch, proton-mail-bridge,
protonvpn, tor-browser — because a firewall, a VPN and a hardened browser ship
fixes on their own schedule, and the gap until the next `update` is real
exposure. `status` prints them with the reason. To change that list, edit
`EXEMPT` in `dot_local/lib/python/caskupd_app.py` from the source directory and
apply:

```sh
chezmoi cd
$EDITOR dot_local/lib/python/caskupd_app.py
chezmoi apply -v
```

Apps that update through Keystone, Electron or their own installer expose no
preference key worth chasing. `status` lists them by name, and
`brew upgrade --greedy` owns their versions whenever it wins the race.

## Mounting the NAS

`nas.botasal.xyz` serves the share `Book2` over SMB. It is mounted whenever the
network allows and absent, without comment, when it does not — no authentication
sheet, no connection-failed alert, and no "the server connection was
interrupted" dialog after leaving the house.

```sh
mount-nas             # mount when reachable, unmount when not (what launchd runs)
mount-nas status      # reachability, Keychain, and where the share is
mount-nas mount       # mount now, saying why if it cannot (--dry-run works)
mount-nas flush       # write outstanding data back to every mounted volume
mount-nas unmount     # flush, then unmount; refuses while a file is open
mount-nas unmount -f  # tear it down anyway, discarding what has not been written
```

`unmount` is deliberately not forced. A plain unmount refuses while something
still has the share open, and that refusal is what stands between a mounted
share and silently discarded data — `--force` is how to override it, and it says
so when it refuses. A share whose server has already stopped answering is forced
whatever was asked, because there is nothing left to write back to and the stale
mount raises alerts until it is cleared.

Staying quiet takes a guard for each thing that raises a dialog:

- Nothing is attempted until TCP 445 on the NAS answers, so away from home the
  whole thing is a no-op. Testing the port rather than the network name means
  Ethernet and VPN count as being home just as Wi-Fi does.
- `mount volume` raises an authentication sheet when the login Keychain holds no
  password for the server, so the Keychain is consulted first and a missing
  entry is a reason to do nothing rather than a reason to ask.
- A mount whose server has vanished produces interrupted-connection alerts until
  it is cleared, so an unreachable NAS that is still mounted is force unmounted.
  That is the one case where forcing loses nothing.

The share is found in `mount(8)` by its device column, `//user@host/share`,
rather than by `/Volumes/Book2`. A leftover directory of that name makes macOS
mount at `/Volumes/Book2-1` instead, and a check that looked only at the
expected path would mount a second copy every five minutes.

### Seeding the password

The password lives in the login Keychain and nowhere in this repository. Until
it is there the agent mounts nothing and says nothing:

```sh
security add-internet-password -r "smb " -s nas.botasal.xyz -a lfiolhais \
  -D "Network Password" \
  -T /System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthAgent \
  -U -w
```

The trailing space in `-r "smb "` is deliberate: Keychain protocol codes are
four characters, and `smb` is three. `-w` comes last with no value so `security`
prompts, rather than the password reaching `ps` and the shell history. `-T`
names NetAuthAgent because that is what reads the item — `mount volume` hands
the authentication to it, and an item created by `security` is otherwise trusted
only by `security`. Should the first mount raise a Keychain prompt anyway,
Always Allow grants the same access permanently.

The account name is this machine's; on a NAS account with a different user,
change `-a lfiolhais` and `USER` in `dot_local/lib/python/mountnas.py` together,
because the lookup matches on both. `mount-nas` runs the deployed copy, so the
edit takes effect only after an apply:

```sh
chezmoi cd
$EDITOR dot_local/lib/python/mountnas.py
exit
chezmoi apply -v
```

Confirm it with `mount-nas status`, which prints one line per share:

```
Book2: nas.botasal.xyz reachable, password in Keychain, mounted at /Volumes/Book2
```

The Keychain is only reported on the reachable branch, so away from the NAS this
says `not reachable` and tells nothing about the password. Confirm the seeding
from home.

Connecting once through Finder -> Go -> Connect to Server ->
`smb://nas.botasal.xyz/Book2` writes an equivalent item. Type that URL rather
than picking the NAS out of the sidebar: the item records whatever name was used
to connect, `mount-nas` looks it up by `nas.botasal.xyz`, and a mismatch means
the agent finds no password, mounts nothing, and says nothing about it. To see
which name an existing item is filed under:

```sh
security find-internet-password -s nas.botasal.xyz    # what mount-nas looks for
security find-internet-password -s DELTA7             # the NetBIOS name Finder may have used
```

`security delete-internet-password -s DELTA7` removes one filed under the wrong
name, after which the block above seeds the right one.

### What runs it

`~/Library/LaunchAgents/xyz.botasal.mount-nas.plist` runs `mount-nas` at login,
on every write to `/var/run/resolv.conf` or
`/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist` — which macOS
rewrites on every network transition, so the agent fires on joining a network
rather than polling for one — and every 300 seconds as a backstop for
wake-from-sleep.

It is a user agent rather than a `/Library/LaunchDaemons` job because a root
daemon can read neither the login Keychain nor mount into the login session.

It appears under System Settings -> General -> Login Items & Extensions as a
background item, and mounts nothing while it is switched off there. To check and
to load it again:

```sh
launchctl print gui/$(id -u)/xyz.botasal.mount-nas
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/xyz.botasal.mount-nas.plist
```

launchd caches a job's definition when it is bootstrapped, so an edited plist is
read only on a fresh one. The `07-setup-nas` script carries the plist's digest
and reloads the agent whenever it changes, which is why that script is
`run_onchange_` rather than `run_once_`.

`mount-nas` prints nothing while nothing is wrong, so
`~/.local/state/mount-nas.log` stays empty and a line in it is always worth
reading.

### When the share is not appearing

`mount-nas status` separates the causes, since being away from home and being
misconfigured look identical from the Finder. Its first line is the verdict, and
the lines indented under it are why:

| status line | cause | fix |
| --- | --- | --- |
| `does not resolve` | a cached NXDOMAIN, or a resolver that does not serve the name | flush the DNS cache, below |
| `did not answer … within` | away from home, or the NAS is off | nothing, or check the NAS |
| `it does answer within` | the link is slower than the seconds a pass allows | the agent cannot mount over this link; mount by hand with `mount-nas mount` |
| `cannot reach … Connection refused` | the machine answers, its SMB service does not | turn file sharing back on at the NAS |
| `cannot reach …` with any other reason | no route to that address from here | check the network, and the address on the line below |
| `no password in the Keychain for …` | never seeded, or filed under another name | seed it, above |
| `reachable, password in Keychain, not mounted` | the agent is not loaded | `launchctl bootstrap`, below |
| `not reachable, mounted at …` | the NAS vanished while mounted | `mount-nas unmount` |

Whenever the name still resolves, `status` also prints the addresses it resolves
to. A name pointing at some other machine fails exactly like a NAS that is
switched off, and the address is what tells the two apart.

The `does not resolve` line has one cause that looks like perfectly healthy DNS.
`nas.botasal.xyz` is a record the Pi-holes serve and the public `botasal.xyz`
zone does not carry, so any query made while the Pi-holes are not the resolvers
-- away from home, or before they answer at login -- is answered NXDOMAIN, and
macOS caches that. The cached answer outlives the return home, so `mount-nas`
cannot resolve the name on a network where the record is being served.

`dig nas.botasal.xyz` keeps working throughout, because it queries the Pi-hole
directly and never reads that cache. DNS therefore looks healthy while
`getaddrinfo`, which is what `mount-nas` and everything else on the machine
call, fails. Trust `dscacheutil -q host -a name nas.botasal.xyz` over `dig`
here: it goes through the same cache the rest of the system does.

Clearing it takes both commands, and `sudo` asks for the account password:

```sh
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

`mount-nas status` reports `reachable` immediately afterwards, with no wait for
anything to expire.

A name that resolves and a port that answers is still not proof of a file
server. `tests/nasprobe.py` asks the server what it is:

```sh
python3 tests/nasprobe.py
```

It prints the SMB dialect the server negotiates, and fails with a reason when
the name does not resolve, the port is closed, or something that is not an SMB
server answers.

`mount-nas mount` can fail with `execution error: User canceled. (-128)` while
`status` reports the NAS reachable with the password in the Keychain. The mount
raises a dialog whenever NetAuthAgent cannot finish authenticating on its own,
and a mount run from a script has nobody to answer that dialog, so it is
cancelled and the cancellation is what comes back. The same error arrives
whether the Keychain item could not be read or the NAS refused the password it
held, so the error alone does not say which.

`smbutil view` settles it, authenticating from the terminal with a typed
password so that neither the Keychain item nor AppleScript is in the way:

```sh
smbutil view //lfiolhais@nas.botasal.xyz
```

A list of shares means the credentials are good and the fault is in how the
Keychain item is filed. `security find-internet-password -s nas.botasal.xyz`
prints it, and `srvr`, `acct`, and a `ptcl` of `smb ` are what NetAuthAgent
matches on. `server rejected the authentication: Authentication error` means the
NAS refused the account, and nothing on this machine will change that.

A Linux NAS serves SMB with Samba, which keeps its own password database
separate from the Unix account. SMB authentication is challenge-response and
needs an NT hash, which cannot be derived from the Unix password hash, so the
two stores are independent and drift apart in either direction: `passwd` never
touches the Samba one, and `smbpasswd` reaches the Unix one only where the sync
below is working.

On the NAS, `pdbedit -L -v lfiolhais` says whether the Samba account exists and
whether its flags carry a `D` for disabled, `smbpasswd -a lfiolhais` sets its
password, and `smbpasswd -e lfiolhais` enables a disabled one. All three need
root and stop for a `sudo` password. `smbpasswd` prompts for the new password
twice, never asks for the old one, and prints nothing at all when it succeeds;
the `Password last set` line in `pdbedit -L -v lfiolhais` carries the new date
and is what confirms it.

`testparm -s --parameter-name="unix password sync"` reports whether `smbpasswd`
is configured to change the Unix login password to match. A `Yes` is a
configuration rather than a result: the change is handed to PAM where
`pam password change = Yes`, and to the `passwd program` chat otherwise, and it
stays silent when either fails, leaving the two passwords different while the
setting says they agree. `chage -l lfiolhais` settles which happened, since its
`Last password change` moves whenever the sync really runs, even where the
password it sets is the one already there.

The Keychain item still holds the old password after any of this, so re-run the
`security add-internet-password` command above; its `-U` updates the item in
place rather than refusing because one exists.

autofs would mount lazily and handle the network coming and going for free, but
`automountd` runs as root and cannot reach a login Keychain, so the password
would have to live in `/var/root/.nsmbrc`.

## Contacts

khard's address book is `work`: one age-encrypted vCard per contact, in
`private_dot_config/khard/work/default/` here and
`~/.config/khard/work/default/<uid>.vcf` on the machine. chezmoi is what carries
contacts between machines — vdirsyncer is not part of this setup, and CardDAV is
not used.

A card written by `khard new` has no entry in the source, so it exists on that
one machine and nowhere else. `khard` is wrapped in a fish function that re-adds
the address book after every subcommand that writes a card, so the ordinary case
needs nothing:

```sh
khard new                 # create a contact; the wrapper records it
chezmoi diff              # the new .vcf appears as an addition
```

`khard-track` is the same step by hand, for a card written by something other
than khard. `set -x DOTFILES_KHARD_UNTRACKED 1` turns the wrapper off for a
change meant to stay on one machine.

Because each file is named after a uid and encrypted, `git status` and
`chezmoi status` name contacts in a way nobody can read. `khard-status` decrypts
each card and reports it by name, in three groups: on this machine and not in
the source, in the source and not on this machine, and different between the
two.

```sh
khard-status              # what differs, by contact name
khard-status -a work      # -a names the address book; `work` is the default
```

A contact dropped from the source is not deleted from a machine that already has
it — the source directory is not `exact_`. `TODO.md` has the trade-off and what
restoring `exact_` would mean.

`khard-rm` deletes contacts and drops them from the source state in one step. It
opens an fzf picker, multi-select with TAB and confirm with ENTER:

```sh
khard-rm [-a|--addressbook NAME] [-n|--dry-run] [-N|--no-forget] [search terms...]
```

It resolves every uid through `khard filename` first and skips anything that
does not match exactly one card, because khard's `remove` takes free-text search
terms and has no `--uid` flag. `--dry-run` lists the selection and stops;
`--no-forget` deletes the contacts but leaves the source state alone.

Deletions reach other machines when the source directory is committed and
pushed. Those machines pick them up with `chezmoi update`, which pulls and
applies — and so may re-run bootstrap scripts whose content has changed.

## Email

mbsync pulls mail into `~/.local/share/mail`, notmuch indexes it, aerc reads it
and msmtp sends it. The isync and notmuch configs are age-encrypted here;
passwords are not in this repository at all. On macOS they live in the login
Keychain, on Linux in `pass`.

`06-setup-mail` prints the steps for the current OS during the bootstrap and
changes nothing itself, so it can be read at any time:

```sh
chezmoi execute-template < run_once_after_install-06-setup-mail.sh.tmpl
```

Proton Mail is reached through Proton Mail Bridge, whose TLS certificates are
exported from its Settings -> Advanced pane into `~/.config`. After any
credential or config change:

```sh
mbsync -a && notmuch new
```

## Testing

There is no build. Testing a change means `chezmoi diff`, then the harness:
`tests/render-matrix.sh` first because it takes seconds, then `tests/check.py`
on this host, `tests/linux.py` for the Linux targets in Docker, and
`tests/macos.py` for macOS in a Lume VM. None of them touches this machine:
`linux.py` works in a container and `macos.py` in a VM, and only those two run
the bootstrap scripts at all, under `--full`, inside the throwaway guest.

`tests/render-matrix.sh` renders every template for all three profiles and
parses the result — shell with `bash -n` and `shellcheck`, fish with `fish -n`.
It needs no Docker, which is what makes it the one to run while editing; its
header says what that render can and cannot prove.

`tests/check.py` runs on this host and is the only one that exercises the real
age key; [tests/README.md](tests/README.md) lists what it needs installed.

Other machines pull `main`, so a broken `main` breaks them. A `pre-push` hook
runs `check.py` before any push to `main`; `core.hooksPath` is a local git
setting, so enable it once per clone:

```sh
git config core.hooksPath tests/githooks
```

[tests/README.md](tests/README.md) documents the harness and the hook in full.
