# Backlog

Each item changes behaviour, so it is a decision rather than a correction.
Nothing here has been applied. Nothing here has been tested on a live machine.

## The NAS

### The share stops mounting whenever a negative DNS answer is cached

`dot_local/lib/python/mountnas.py`

Both Pi-holes answer `nas.botasal.xyz` authoritatively with `192.168.1.78` and a
TTL of 0. `botasal.xyz` is delegated publicly to Porkbun, and that zone has no
`nas` in it, so any query made while the Pi-holes are not the resolvers is
answered NXDOMAIN and macOS caches it.

The cached answer outlives the network change that brings the laptop home.
`Share.reachable()` calls `getaddrinfo`, which reads that cache rather than the
LAN resolvers, so it raises `socket.gaierror`; `sync()` records `AWAY` and
mounts nothing, silently, which is what the command is built to do when the NAS
is genuinely absent. `dig` answers correctly the whole time, because it queries
192.168.1.78 directly and never reads the cache, so every check short of
`getaddrinfo` says DNS is healthy.

How long macOS holds the entry is set by the negative-caching TTL in Porkbun's
SOA and has not been measured. What is established is that it survived the
return to the LAN, and that flushing the cache resolved the name at once:

```sh
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

The local record is not hand-maintained: an Ansible playbook renders
`/etc/dnsmasq.d/99-ansible-services.conf` on both resolvers from a service
registry, and the `nas` entry there carries `proxy: false`, which points the
name at delta7's own address. Editing Pi-hole directly is overwritten by the
next play, so any change to this record is made in that registry.

Closing it means the name resolving from both views, which is an A record for
`nas.botasal.xyz` pointing at `192.168.1.78` in the public zone at Porkbun. Away
from home the name then resolves to an address nothing answers on, the
connection to port 445 fails, and `sync()` records `AWAY` for the reason it is
meant to, with no negative answer ever cached. The cost is that the NAS's
address on the home network is published in public DNS.

The alternative is to keep the record local and flush the cache on the days it
happens, now that `mount-nas status` names the cause.

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

### Nothing exercises the App Store half of `01`

`run_once_after_install-01-install-packages-darwin.sh.tmpl`

The script installs the Brewfile in two passes and treats the App Store one as
non-fatal: `mas install` is expected to fail on a machine whose App Store has
never been signed in, and the script prints what to do about it. That branch has
never run anywhere. A VM has no App Store account and `tests/macos.py` skips the
`mas` entries for that reason, and this Mac is signed in, so the failure path the
script is written around is the one path never taken.

What `mas` does there is the open question. It has no subcommand that reports
whether an account is signed in -- `signout` exists and nothing else -- which is
why the script guesses. If it exits non-zero the script is right as written. If
it waits instead, an unattended apply never ends, and `chezmoi` records nothing,
so the next one starts at `01` again.

Answering it takes a Mac signed out of the App Store, and a `mas install` of one
entry from the Brewfile, timed. If it waits, bounding the pass is the fix:
`coreutils` is installed by the pass before it, so `gtimeout` is there, and
`tests/lume/entrypoint.sh` has the equivalent in plain bash for a machine where
it is not.

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

### MakeMKV is installed by hand or not at all

`private_dot_config/Brewfile`

Homebrew disabled the `makemkv` cask on 2026-09-01 — it no longer passes the
macOS Gatekeeper check — and a disabled cask installs nowhere, so `brew bundle`
exits non-zero on it and `run_once_after_install-01-install-packages-darwin.sh.tmpl`
fails with it. The entry is out of the Brewfile, which is what lets the bundle
finish; the app it installed is still on this Mac and is now declared nowhere.

`brew bundle dump` writes back whatever is installed, so `chezmoi-packages dump`
puts `cask "makemkv"` back and `check.py` fails on it again. Uninstalling the
cask here is what stops that, and it takes MakeMKV.app with it:

```sh
brew uninstall --cask makemkv
```

To have the repository install MakeMKV again, three routes, each hand-maintained
because the disable is permanent:

- A `run_onchange_` script that fetches the current DMG from
  `https://www.makemkv.com/download/` (`MakeMKV_v<version>_macos.dmg`), mounts
  it, copies `MakeMKV.app` to `/Applications`, and detaches it. The version is in
  the URL, so the script carries it and is bumped by hand. First launch needs
  approval under System Settings → Privacy & Security — the Gatekeeper failure
  that got the cask disabled is the one a user meets here.
- `brew install --cask` against the cask file from the commit before the disable,
  e.g. `brew install --cask
  https://raw.githubusercontent.com/Homebrew/homebrew-cask/<sha>/Casks/m/makemkv.rb`.
  Re-pin the sha whenever the vendor moves the download and the old URL 404s.
- Install it by hand when a disc needs ripping and leave the repository out of
  it, the same call already made for anylinuxfs.

The beta key MakeMKV needs while it is in beta rotates about monthly and is
posted on their forum; none of these routes tracks it.

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

### The repo-local reviewers restate the global ones

`.claude/agents/`, `.claude/skills/dotfiles-review/`, `dot_claude/agents/`,
`dot_claude/skills/deploy-review/`

`drift-checker`, `deploy-auditor` and `deploy-review` now exist globally,
carrying the method with no chezmoi in them. `.claude/` still holds
`dotfiles-drift-checker`, `dotfiles-deploy-auditor` and `dotfiles-review`, which
carry the same method plus this repository's specifics: the Brewfile against the
manifest, the three profiles, `tests/render-matrix.sh`.

An agent definition is a prompt, so a repo-local one cannot cite a global one
and have the text arrive -- which is why the method is written out twice, and
why an edit to either leaves the other behind.

The way out is to delete the three repo-local files and have whoever runs the
review dispatch the global agents with this repository's pairs and profiles in
the prompt. That is how they were dispatched in the session that wrote them, and
it worked. The cost is that the pairs and profiles then live in a prompt rather
than in a file, unless `.claude/skills/dotfiles-review/SKILL.md` keeps them and
names which global agent to hand them to.

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
