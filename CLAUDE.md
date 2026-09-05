# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this repo is

This is the **chezmoi source directory** for a personal dotfiles setup.
Files here are *source state*; chezmoi renders them into the *target state*
under `$HOME`. Never edit the deployed dotfiles under `$HOME` directly — edit
the source here and apply, or the next `chezmoi apply` will overwrite your
change.

The primary target is macOS (`darwin`); **Linux is also supported** in two
profiles selected at `chezmoi init` time by the `sudo` prompt (see
`.chezmoi.toml.tmpl`):

- **Linux + sudo** (Debian/Ubuntu/Pop!_OS, Fedora, and RHEL rebuilds like
  Rocky/AlmaLinux/CentOS) — the CLI toolchain is installed with the native
  package manager (apt or dnf, with EPEL/CRB enabled on RHEL rebuilds) plus each
  tool's official repo/installer for the gaps (`gh`, `starship`).
- **Linux + no-sudo** — the CLI toolchain comes from **mise** (rootless, under
  `~/.local`), configured in `private_dot_config/mise/config.toml`.

Everything is CLI/TUI-only on Linux; macOS-only GUI configs (aerospace,
linearmouse, leaderkey) and the `Brewfile` never deploy off darwin (see the
templated `.chezmoiignore`). **Changes for Linux must never break the macOS
render** — Linux logic lives in `{{ if eq .chezmoi.os "linux" }}` blocks that
render empty on darwin, and the two guarded fish additions are no-ops on macOS.

## Core workflow

```sh
chezmoi diff                 # preview what applying the source would change in $HOME
chezmoi apply -v             # render source -> $HOME (runs pending run_ scripts)
chezmoi status               # show files that differ between source and target
chezmoi cd                   # open a shell in this source directory
```

Two ways changes flow:

- **Source -> target**: edit a file here, then `chezmoi apply`.
- **Target -> source** (when you changed a live config by hand): `chezmoi
  re-add` (updates existing source files from their target) or `chezmoi add
  ~/path` (tracks a new file, auto-applying naming conventions).

There is no build/lint/test suite. "Testing" a change means `chezmoi diff` then
`chezmoi apply -v` on a real macOS machine.

## File naming conventions (chezmoi)

Source filenames encode target attributes — the prefixes are transformations,
not part of the name:

- `dot_foo` -> `.foo`
- `private_` -> target file gets `chmod 600` (e.g. `private_dot_ssh/` ->
  `~/.ssh`)
- `encrypted_` -> stored age-encrypted here, decrypted on apply
- `run_once_` -> script run once (tracked by content hash); `run_onchange_` ->
  re-run when its content changes
- `before_` / `after_` -> run before/after the file-application phase
- `.tmpl` -> rendered as a Go template

So `private_dot_config/private_fish/config.fish` is the source for
`~/.config/fish/config.fish`. When creating files, apply these prefixes
yourself rather than fighting chezmoi.

## Encryption (age)

Encrypted secrets use age (config in `.chezmoi.toml.tmpl`; identity at
`~/.config/chezmoi/key.txt`, recipient key inline). Encrypted files:
`key.txt.age` (the master key itself, bootstrapped by
`run_onchange_before_decrypt-private-key.sh.tmpl` and excluded from apply via
`.chezmoiignore`), `private_dot_config/encrypted_isyncrc.age`,
`encrypted_dot_notmuch-config.age`.

- Edit an encrypted file: `chezmoi edit ~/<target>` (chezmoi decrypts to a temp
  file and re-encrypts on save) — don't hand-edit the `.age` blob.
- IMAP/SMTP passwords are **not** in the repo; they live in the macOS Keychain
  (see the mail setup script).

## Bootstrap sequence (fresh machine)

On `chezmoi apply`, run scripts execute in prefix order:

1. `run_once_before_install-setup-xcode-cli.sh.tmpl` — (darwin) Xcode Command
   Line Tools + Rosetta 2
2. `run_onchange_before_decrypt-private-key.sh.tmpl` — decrypt the age key into
   `~/.config/chezmoi/key.txt`
3. `run_once_after_install-01-install-packages-darwin.sh.tmpl` — (darwin)
   install Homebrew, `brew bundle --file=~/.config/Brewfile`, rustup
3b. `-01-install-packages-linux.sh.tmpl` — (linux) sudo profile: native package
   manager chosen by distro *family* (via the shared `.chezmoitemplates/linux-target`)
   — apt on Debian/Ubuntu, dnf on Fedora, dnf + EPEL/CRB on RHEL rebuilds
   (Rocky/Alma/CentOS) — plus the `gh`/`starship` official repos/installers for
   the gaps; no-sudo profile: rootless mise + `mise install`. Both profiles
   install `python3`, which the `git-wt-*` commands need and which neither
   Ubuntu's nor Fedora's base image ships.
4. `-02-setup-darwin.sh.tmpl` — (darwin) extensive macOS `defaults write` tweaks
5. `-03-setup-dock.sh.tmpl` — (darwin) Dock layout via `dockutil`
6. `-04-setup-fish.sh.tmpl` — register fish as the login shell: `/etc/shells` +
   `chsh` on darwin and linux+sudo; `exec fish` from `~/.bashrc` on linux+no-sudo
7. `-05-setup-bat.sh.tmpl` — `bat cache --build`; loads Homebrew's env on macOS,
   adds `~/.local/bin` + mise shims on Linux, so bat is on PATH under bash
8. `-06-setup-mail.sh.tmpl` — (darwin) prints manual mail setup steps (Keychain
   passwords, Proton Bridge TLS certs)
9. `run_onchange_after_install-07-setup-nas.sh.tmpl` — (darwin) loads the
   `xyz.botasal.mount-nas` LaunchAgent and prints the one manual step, seeding
   the Keychain. It is `run_onchange_` and carries the plist's digest in a
   comment, because launchd caches a job's definition at bootstrap and an edited
   plist is only read on a fresh one.

OS-gating: darwin-only scripts (`xcode-cli`, `01-…-darwin`, `02`, `03`, `06`,
`07`) are wrapped so they render **empty** on Linux, and chezmoi skips empty `run_`
scripts; `04` branches per OS/profile. Editing an already-run `run_once_` script
re-runs it (hash changed); keep them idempotent.

## Packages

**`README.md` is the reference — read its Packages section before touching a
package list.** In short: `private_dot_config/Brewfile` is what macOS installs,
`.chezmoidata/packages.toml` maps each formula onto its name per Linux target,
and **a tool not in the system's package manager is not installed** (only `gh`
and `starship` are excepted, in the `01` script). A missing field in the manifest
means "not available on that target"; `mise` is a target too, because on the
no-sudo profile mise *is* the package manager. There is **one table**: an entry
naming no target at all is not installed on Linux, and its `note` says why —
that replaced a second `[skip]` table that said the same thing twice.

The two files are written by different hands, and that is the thing to keep
straight. The **Brewfile is derived**: `brew bundle dump` writes it from what
the Mac has installed — descriptions, taps, casks, Mac App Store apps and `uv`
tools included — so nothing else may edit it, and a line spliced in by hand is
gone at the next dump. The **manifest is authored**: it records a decision no
machine can be asked for.

Use `chezmoi-packages` (`search` / `add` / `remove` / `dump`) rather than hand
editing. `add` and `remove` drive **both** ends — install or uninstall, re-dump
the Brewfile, then edit the manifest — because a package that is only half
removed is exactly what the harness fails on; `--no-install`/`--no-uninstall`
edit the manifest alone. `dump` is the only path to the Brewfile and just runs
`brew bundle dump`, then reports what the manifest still owes. `search` asks each
distro's real repositories what the package is called there. It is a **deployed**
command (`dot_local/bin/executable_chezmoi-packages` -> `~/.local/bin`), not
harness tooling: it finds the two files through `chezmoi source-path`, so it runs
from anywhere, and editing it needs a `chezmoi apply` before the change is on
`PATH`. `tests/check.py` fails if a Brewfile `brew`/`uv` entry is unclaimed by
the manifest, if an entry installs nowhere and gives no reason, or if a field
name is misspelled; `tests/linux.py` fails if a name does not resolve in the
repository it claims.

The manifest is **generated**: `tomllib` reads it, and `tomlkit` writes it back
whole from the header in `chezpkg_manifest.py` and one table per entry. So every
edit rewrites the file and a comment added by hand does not survive — annotations
belong in `note`. Nothing is written until the render has been re-parsed and found
to hold exactly the entries that were asked for.

Writing TOML is the one thing the standard library cannot do, and Homebrew
packages no writer for it (the Linux targets all have `python3-tomlkit`), so the
command's shebang is a PEP 723 script run through **uv**, which supplies both
`tomlkit` and a >= 3.11 interpreter. That is why `chezpkg` may use 3.11 features
where `gitwt` may not, and why `tests/check.py` exercises this command through
`uv run --script` instead of under every `python3` on the host.

Two consumers read the manifest, neither keeping its own copy: the `01` script
(via `.chezmoitemplates/linux-packages`) and
`private_dot_config/mise/config.toml.tmpl`, which is **generated**. The distro
dispatch lives once, in `.chezmoitemplates/linux-target` (`apt`/`fedora`/`el`).

## Updating a machine

The fish `update` function (`private_fish/functions/update.fish.tmpl`) walks
whichever package managers it finds, skipping absent ones and reporting failures
at the end rather than stopping at the first: brew and mas on darwin; apt or dnf
plus the starship installer on linux+sudo; `mise self-update` on no-sudo; and on
every profile `rustup update`, `uv tool upgrade --all` and `mise upgrade`. It
deliberately does **not** run `chezmoi update`, since applying dotfiles can
re-run bootstrap scripts.

## App self-updates

Most casks ship the vendor's own updater — **29 of the 41 installed casks declare
`auto_updates true`** — so an app replaces itself behind Homebrew's back. The
Caskroom then describes a version that is no longer on disk, and the next
`brew upgrade --greedy` reinstalls, or walks back, an app that was already
current.

There is no general switch for this: Homebrew ships the vendor's binary as-is,
and its maintainers say so. What there is, is **Sparkle**, the update framework
most Mac apps embed. It reads its automatic-check settings from the app's *own*
user-defaults domain, where they beat the same keys in the bundle's
`Info.plist`. `cask-updates` writes those two keys —
`SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`, both false — for exactly
the apps Homebrew installed:

```sh
cask-updates status     # what self-updates, and what is already silent
cask-updates disable    # silence the Sparkle apps Homebrew owns (--dry-run works)
cask-updates enable     # undo it: the keys are deleted, not set true
```

`update` runs `disable` on every darwin run, so a cask installed since the last
one is caught without anyone remembering to.

Three things about it are load-bearing:

- **Nothing is discovered from a list.** The set is whatever `brew list --cask`
  says today, and whether an app can be silenced is read out of its bundle
  (`SUFeedURL`/`SUPublicEDKey`/`SUPublicDSAKeyFile`, or an embedded
  `Sparkle.framework` — both tests, because either alone misses cases). That is
  what keeps the maintenance at zero.
- **Apps installed by hand are never touched**, because nothing else would ever
  update them. Only apps Homebrew owns are fair game.
- **Nothing inside an app bundle is modified.** Deleting `Autoupdate.app` or
  `ksadmin` would break the code signature and be undone by the next upgrade;
  writing a preference is reversible and survives nothing but a `defaults
  delete`.

Coverage today is **17 silenced, 12 still self-updating**. Five are exempt on
purpose (`EXEMPT` in `caskupd_app.py`: adguard, little-snitch,
proton-mail-bridge, protonvpn, tor-browser — security tools whose own schedule
beats a weekly `brew upgrade`). Seven cannot be reached at all, and `status`
names them rather than pretending otherwise: `google-chrome` (Keystone),
`signal`/`claude`/`drawio` (Electron), `zoom`, `busycal`, `shottr`. Chasing
those per-vendor keys was considered and rejected — each is a line that rots on
someone else's schedule.

## Mounting the NAS

`nas.botasal.xyz` serves the share `Book2` over SMB, and it should be mounted
whenever the network allows and absent, without comment, when it does not. The
hard part is the silence: three separate things raise a dialog on macOS, so
`mount-nas` carries three guards.

```sh
mount-nas             # mount when reachable, unmount when not (what launchd runs)
mount-nas status      # reachability, Keychain, and where the share is
mount-nas mount       # mount now, saying why if it cannot (--dry-run works)
mount-nas unmount     # unmount now
```

- Nothing is attempted until TCP 445 answers, so the agent is a no-op away from
  home. Testing the port rather than the network name means Ethernet and VPN
  count as being home just as Wi-Fi does.
- `mount volume` raises an authentication sheet when the login Keychain holds no
  password for the server, so the Keychain is consulted first and a missing
  entry is a reason to do nothing rather than a reason to ask.
- A mount whose server has vanished produces interrupted-connection alerts until
  it is cleared, so an unreachable NAS that is still mounted is force unmounted.

`mount volume` is the AppleScript route rather than `mount_smbfs` because it
reads the login Keychain and mounts under `/Volumes` the way Finder does, so the
share behaves normally in the sidebar. Every command is named by absolute path,
since launchd hands a job a bare `PATH`.

The share is found in `mount(8)` by its device column, `//user@host/share`,
rather than by `/Volumes/Book2`. A leftover directory of that name makes macOS
mount at `/Volumes/Book2-1` instead, and a check that only looked at the
expected path would mount a second copy every five minutes.

The password lives in the login Keychain and nowhere in this repo. Seeding it is
the one manual step, and until it is done the agent mounts nothing and says
nothing:

```sh
security add-internet-password -r "smb " -s nas.botasal.xyz -a lfiolhais \
  -D "Network Password" \
  -T /System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthAgent \
  -U -w
```

`-w` goes last with no value so `security` prompts, rather than the password
reaching `ps` and the shell history. `-T` names NetAuthAgent because that is
what reads the item: `mount volume` hands the authentication to it, and an item
created by `security` is otherwise trusted only by `security` itself. A first
mount that raises a Keychain prompt is answered with Always Allow, which grants
the same access.

Connecting once through Finder writes an equivalent item, and the URL has to be
typed rather than picked out of the sidebar. The `srvr` attribute is whatever
string was used to connect -- an existing item on this machine is stored under
the NetBIOS name `DELTA7` -- and `has_password()` looks the item up by
`nas.botasal.xyz`. A mismatch fails closed: the agent mounts nothing and stays
silent, which is indistinguishable from being away without asking.

`mount-nas status` is what tells them apart, and it is the first thing to check
when the share is not appearing.

`Library/LaunchAgents/xyz.botasal.mount-nas.plist.tmpl` runs it: at load, on
every write to `/var/run/resolv.conf` (rewritten on every network transition,
which is what makes this fire on joining a network rather than polling for one),
and every 300 seconds as a backstop for wake-from-sleep. It must stay a user
agent — a `/Library/LaunchDaemons` job runs as root, which can read neither the
login Keychain nor mount into the login session. It appears under System
Settings -> General -> Login Items & Extensions as a background item and has to
stay enabled.

`sync` prints nothing while nothing is wrong, so `~/.local/state/mount-nas.log`
stays empty and a line in it is always worth reading.

autofs was the alternative and was rejected: it mounts lazily and handles
network comings and goings for free, but `automountd` runs as root and cannot
reach a login Keychain, so the password ends up in `/var/root/.nsmbrc`.

## Layout

- `private_dot_config/` — per-app configs: `aerc`, `aerospace`, `bat`, `gh`,
  `gh-dash`, `ghostty`, `khard`, `leaderkey`, `linearmouse`, `msmtp`, `nvim`,
  `private_fish/`, `starship.toml`, `vdirsyncer`, plus the `Brewfile` (what
  macOS installs) and `mise/config.toml.tmpl` (the Linux no-sudo toolchain,
  generated from `.chezmoidata/packages.toml`).
  `aerospace`/`linearmouse`/`leaderkey`/`Brewfile` are darwin-only and `mise` is
  linux-no-sudo-only, per the templated `.chezmoiignore`.
  `khard/work/exact_default/` holds one age-encrypted vCard per contact; the
  `exact_` prefix is load-bearing — see *Contacts* below. vdirsyncer's `status/`
  is deliberately **not** tracked.
- `private_dot_config/private_fish/` — fish shell: `config.fish.tmpl` sources
  `exports.fish`, `aliases.fish`, `greet.fish`; uses vi keybindings; inits fzf
  and starship. It's a template only so the mise activation (which would make the
  shell prefer mise's binaries) is gated to the **no-sudo Linux** profile; macOS
  and sudo-Linux render without it. Add functions under `functions/`, one
  function per file named after it (fish autoloads by filename) — e.g.
  `khard-rm.fish` / `khard-track.fish`, the contact helpers described under
  *Contacts* below.
- `dot_local/share/mail/` — Maildir store (`pm`, `ist`, `icloud`) plus notmuch
  state.
- `dot_local/bin/` — user commands, deployed `0755` via the `executable_` prefix:
  `git-wt-clone` (clone a repo as a bare clone plus per-ref worktrees, into a
  folder you may name), `git-wt-add` (check a branch/tag/hash out into its own
  folder), `chezmoi-packages` (maintain the two package files — see *Packages*
  above), `cask-updates` (stop cask apps updating themselves — see *App
  self-updates* above), and `mount-nas` (keep the NAS share mounted while it is
  reachable — see *Mounting the NAS* above). The `git-` prefix means git
  dispatches the two worktree commands as subcommands too (`git wt-add …`).
  `chezmoi-packages` is the one command that edits **this repo** rather than the
  machine, so it discovers the source directory with `chezmoi source-path`
  instead of deriving it from `__file__`. `cask-updates` and `mount-nas` are
  macOS-only and chezmoi-ignored off darwin.
- `Library/LaunchAgents/` — `xyz.botasal.mount-nas.plist.tmpl`, the only
  LaunchAgent here. A template because `ProgramArguments` needs the home
  directory; no `dot_` prefix, because `~/Library` is not hidden.
- `dot_local/lib/python/` — the libraries the commands share, plus
  `linux_distros.py`: `IMAGES` and `TARGET_OF`, the Linux target matrix, read by
  both `chezpkg_search` and `tests/linux.py` so that adding a distro is one edit.
  It is deployed rather than kept in `tests/` precisely because
  `chezmoi-packages` runs from `~/.local/bin`, where `tests/` does not exist.

  Four families, each a facade over modules that import strictly **downwards**,
  which is what keeps them free of cycles. **The entry points import the facade
  and nothing else**, so any split can change without touching them.

  `gitwt`, behind the two `git-wt-*` commands:

  | module | holds | imports |
  | --- | --- | --- |
  | `gitwt_git.py` | constants, `GitWtError`, `git()` | nothing local |
  | `gitwt_refkind.py` | `RefKind` (what a ref names) | `gitwt_git` |
  | `gitwt_repo.py` | `Repo` (layout discovery, clone, fetch) | `gitwt_git` |
  | `gitwt_plan.py` | `Plan` (folder name + `worktree add` argv) | the three above |
  | `gitwt_worktree.py` | `Worktree` (create, or reuse in place) | all of the above |
  | `gitwt.py` | `__all__`, nothing else | all of the above |

  `chezpkg`, behind `chezmoi-packages`:

  | module | holds | imports |
  | --- | --- | --- |
  | `chezpkg_run.py` | `PackagesError`, `run()`, `maybe()`, `have()` | nothing local |
  | `chezpkg_source.py` | `Source` (the source dir and the two file paths) | `chezpkg_run` |
  | `chezpkg_brew.py` | `Entry`, `Brewfile` (parse, dump, install, uninstall) | run, source |
  | `chezpkg_manifest.py` | `Manifest` (read, save, problems) | run, source, brew |
  | `chezpkg_search.py` | `Match`, `Search` (ask every platform, **return** it) | run, `linux_distros` |
  | `chezpkg.py` | `__all__`, nothing else | all of the above |

  `caskupd`, behind `cask-updates`:

  | module | holds | imports |
  | --- | --- | --- |
  | `caskupd_app.py` | `App` (a cask's app: bundle id, updater kind), `EXEMPT` | `chezpkg_run` |
  | `caskupd_sparkle.py` | `Sparkle` (the two keys: read, write, delete) | `chezpkg_run` |
  | `caskupd.py` | `__all__`, nothing else | both above |

  `mountnas.py`, behind `mount-nas`, is a family of one: `Share` (its URL, its
  device column, whether the NAS answers, where it is mounted, whether the
  Keychain has its password), `Outcome`, and `sync()` over them. It is both
  facade and implementation, because the whole surface is a single dataclass;
  the entry point still imports from `mountnas` and nothing else, so splitting it
  later changes nothing there.

  `caskupd` and `mountnas` are the cross-family imports: `chezpkg_run` is generic
  process plumbing, so it is shared rather than copied — which is why that one
  module must stay stdlib-only and 3.9-clean even though the rest of `chezpkg`
  need not be.

  `gitwt` is standard library only and Python 3.9-compatible: that floor comes
  from both OSes — a fresh Mac has Apple's 3.9 until Homebrew's lands, and the
  RHEL rebuilds ship 3.9 as well. `caskupd` and `mountnas` share that floor for
  the same reason. `chezpkg` is **3.11+** instead, because uv supplies its interpreter
  (see *Packages* above); its one dependency, `tomlkit`, is imported under a
  guard so that merely importing the library — as `tests/check.py` does, under a
  plain `python3` — needs nothing but the stdlib. `tests/check.py` lints every
  module with ruff, imports `caskupd`/`gitwt`/`linux_distros`/`mountnas` under
  each interpreter it finds (ruff alone cannot see an import cycle), runs the
  `mount-nas` unit tests, and runs `chezmoi-packages --help` through
  `uv run --script`.
- `private_dot_ssh/`, `private_dot_gitconfig`, `dot_bashrc` — top-level
  dotfiles.

`~/.local/bin` is already on `PATH` on every profile: macOS via `fish_user_paths`
in `exports.fish`, Linux via `fish_add_path` in `config.fish.tmpl`.

## Email subsystem

The most interconnected part. Sync/read pipeline: **mbsync/isync**
(`encrypted_isyncrc.age`) pulls mail into `~/.local/share/mail` -> **notmuch**
(`encrypted_dot_notmuch-config.age`) indexes it -> **aerc** reads it ->
**msmtp** sends -> **khard**/**vdirsyncer** handle contacts/CardDAV. Proton
Mail is reached through Proton Mail Bridge (TLS certs exported into
`~/.config`). After credential/config changes: `mbsync -a && notmuch new`.

## Contacts

khard's address book is `work`, one age-encrypted vCard per contact under
`private_dot_config/khard/work/exact_default/` ->
`~/.config/khard/work/default/<uid>.vcf`. **chezmoi is the transport between
machines**, not CardDAV — vdirsyncer is dormant here, and its `status/`
directory is machine-local bookkeeping that is chezmoi-ignored (restoring one
machine's status on another makes vdirsyncer disagree with itself about what has
already been deleted).

The `exact_` prefix is what makes **deletions propagate**. Without it
`chezmoi apply` only writes the entries it knows about and silently leaves a
target file whose source entry has been deleted, so removing a contact on one
machine never reached the others. `exact_` declares the target directory to
contain *exactly* the source entries, so chezmoi deletes the strays.

That cuts both ways, and it is the one thing to remember here:

> A contact created with `khard new` has no source entry yet, so the next
> `chezmoi apply` **deletes it**. Run `khard-track` (or
> `chezmoi add ~/.config/khard/work/default`) after adding or editing a contact.

Two fish helpers cover the lifecycle:

- `khard-rm` — fzf multi-select over `khard list --parsable`, confirm, then
  `khard remove` each and `chezmoi forget` their vcf files. It resolves every
  uid through `khard filename` first and skips anything that does not match
  exactly one card, because khard's `remove` takes free-text search terms and
  has no `--uid` flag. Supports `--dry-run`.
- `khard-track` — `chezmoi add` the collection, to be run after `khard new`.

Note `chezmoi re-add` **cannot** express a deletion: it only re-adds files that
still exist ("all entries that are not files are ignored"). `chezmoi forget` is
the verb that drops an entry from the source state.

## Testing (human-run — do NOT let an AI run this)

Other machines pull `main` via `chezmoi update`, so a broken `main` breaks
them. Before pushing to `main`, a human runs the safety harness:

```sh
python3 tests/check.py
```

It renders the whole source with `chezmoi archive` (proving templates + age
decryption + ignores work), lints the `run_*` bootstrap scripts (`bash -n`,
shellcheck), checks the Brewfile and its agreement with
`.chezmoidata/packages.toml`, lints this repo's Python with ruff, imports every
deployed library under every `python3` on the host, runs the `mount-nas` unit
tests, and prints a `chezmoi apply --dry-run` diff to review. It performs **no** destructive
actions and never runs the `run_*` scripts. `check.py` is OS-aware: scripts
gated off for the current OS render empty and are skipped, so it runs on both
macOS and Linux. The `tests/` directory is chezmoi-ignored (never deployed to
`$HOME`).

To validate the **Linux** targets from any machine (macOS included), a Docker
driver renders + lints all four `distro × sudo` combinations in throwaway
containers (no host changes, no real age key):

```sh
python3 tests/linux.py          # render + lint ubuntu/fedora/rocky/alma × sudo/no-sudo
python3 tests/linux.py --full   # also run the real apt/dnf + mise bootstrap in-container
```

The default run also asks each distro's package manager whether every name the
manifest targets at it resolves, without installing anything — that is what keeps
the strict one-transaction install in `01` safe, and what confirms a name you
added is real. `--full` installs the whole toolchain, TeX included, so budget
gigabytes and a long wait.

The macOS analogue is `tests/macos.py`, which does the same in throwaway **Lume**
VMs (Docker can't run macOS; Lume is the MIT-licensed CLI over Apple's
Virtualization framework, Apple Silicon only). It needs only `lume`
(`/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"`; `lume ssh`
handles guest access, so there is no ssh password plumbing):

```sh
python3 tests/macos.py               # render + lint the darwin scripts in a macOS VM
python3 tests/macos.py --only tahoe  # one image only (each image is a ~20-90 GB pull)
python3 tests/macos.py --full        # also run the real bootstrap (heavy: brew, defaults, dock)
```

A `pre-push` git hook enforces this on pushes to `main`. Enable it once per clone:

```sh
git config core.hooksPath tests/githooks
```

`tests/nasprobe.py` is the one test that talks to something real. It sends an
SMB2 NEGOTIATE to the host named in `mountnas.py` and prints the dialect the
server picks, so a name that has stopped pointing at a file server says so
instead of looking like an evening away from home:

```sh
python3 tests/nasprobe.py
```

It is standalone and deliberately **not** part of `check.py`, because the
pre-push hook has to pass away from home. It connects directly when it can and
tunnels through the SOCKS5 proxy in `$ALL_PROXY` when a direct socket is
refused, which is what lets it run inside a sandbox.

See `tests/README.md` for full documentation of the harness and the hook
(behavior, bypassing with `--no-verify`, and the per-clone caveat).

**AI agents (including Claude Code) must never run `tests/check.py` or `chezmoi
apply` — applying dotfiles has real side effects (chsh, defaults write, brew,
dockutil). Testing and applying are human-only steps.**

Python in this repo — the harness and the deployed `git-wt-*` commands under
`dot_local/` — must pass the ruff ruleset in `tests/pyproject.toml`
(`ruff check` + `ruff format`). The deployed
ones live outside `tests/`, so `check.py` passes them to ruff by path with an
explicit `--config`; the library modules are globbed from `dot_local/lib/python/`,
so splitting one in two keeps it covered.
