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
| `private_dot_ssh/`     | `~/.ssh`                     | owner only: `0700` on a directory, `0600` on a file |
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
equivalent — `command` because fish, the shell this repository installs and
makes the login shell, wraps `brew` to block a bare `brew install`. The
bootstrap installs everything else, including Homebrew. What it cannot supply
has to exist first:

- The passphrase for `key.txt.age`. It unlocks the mail configs, contacts and
  SSH keys, is in neither this repository nor anything it deploys, and cannot
  be recovered from either — it has to be brought to the machine. The
  passphrase prompt below covers installing without it.
- An administrator account: Homebrew's installer, `/etc/shells` and the root
  settings in `02-setup-darwin` all go through sudo.
- For the Mac App Store apps, an Apple ID signed in to App Store.app. The
  sign-in can happen later; "What the first apply changes" says what the
  bootstrap does until then.

### One command

```sh
~/.local/bin/chezmoi init --apply lfiolhais/dotfiles
```

`init` clones the repository into `~/.local/share/chezmoi`, which is the source
directory and the only copy to edit. `--apply` then renders it into `$HOME` and
runs the bootstrap scripts. `lfiolhais/dotfiles` is this repository's GitHub
path, cloned anonymously over HTTPS; a fork installs by its own path. Add
`--ssh` to clone over SSH instead — it needs a key GitHub already accepts, and
a machine that has never applied this repository holds none of its keys, so a
blank machine's first clone is HTTPS.

Prompts interrupt it:

- On Linux, `Do you have sudo on this machine`. The answer selects the profile
  and is remembered, so a later `chezmoi init` does not ask again. Changing it
  afterwards means editing `~/.config/chezmoi/chezmoi.toml` to read

  ```toml
  [data]
      sudo = true
  ```

  and then `chezmoi apply -v`, because the answer decides the package manager,
  how fish becomes the login shell, and whether `~/.config/mise` is deployed at
  all. Nothing uninstalls what the previous profile installed, so those packages
  stay until they are removed by hand.
- A passphrase for `key.txt.age`. Encrypted files here are age blobs — age is
  the encryption tool chezmoi is configured to call — and that file holds the
  key that decrypts all of them. The passphrase is in neither this repository
  nor anything it deploys, and cannot be recovered from either. Without it,
  `chezmoi apply --exclude=encrypted,scripts`
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
| (the files themselves)       | writes every managed file, and sets `~/.local/share/nvim` and its `site` directory to `0700` |
| `01-install-packages-darwin` | updates or installs Homebrew, then the whole Brewfile — the list of everything macOS installs — then Rust's stable toolchain |
| `01-install-packages-linux`  | installs the toolchain with apt or dnf, or with a rootless mise, plus `starship` (the shell prompt), `gh` (GitHub's CLI) and `acli` (Atlassian's Jira CLI) from outside the distribution |
| `02-setup-darwin` | rewrites preferences across the Dock, Finder, Safari, trackpad, keyboard, screenshots and Software Update, then kills the affected apps to reload them |
| `03-setup-dock`              | appends the apps it names to the Dock, leaving existing items in place     |
| `04-setup-fish`              | adds fish to `/etc/shells` and makes it the login shell with `chsh`        |
| `05-setup-bat`               | builds bat's theme cache                                                   |
| `06-setup-mail`              | prints the manual mail steps; changes nothing                              |
| `07-setup-nas`               | writes `/etc/resolver/botasal.xyz`, loads the NAS LaunchAgent, prints its one manual step |
| `08-setup-ssh`               | puts each deployed key's passphrase in the login Keychain; asks for it     |
| `09-build-aerc-filters`      | compiles aerc's `colorize` and `wrap` filters from their C sources         |

Each script named above is the tail of a filename at the top of the source
directory — `03-setup-dock` is `run_once_after_install-03-setup-dock.sh.tmpl` —
and `ls run_*` there lists every one. chezmoi writes the files between the
scripts named `before` and the ones named `after`.

Managing the docket plugin, under [Jira and reviews](#jira-and-reviews), puts
`~/.local/share/nvim` and `~/.local/share/nvim/site` under chezmoi, which sets
their mode. Both source directories carry the `private_` prefix, so a fresh
machine gets the same `0700` neovim would have given them, and on a machine
where something else made them `0755` the apply changes them to `0700`.
`chezmoi diff ~/.local/share/nvim` prints what this machine's apply changes
there.

`09` needs a C compiler. macOS has `cc` from the Xcode command-line tools, and
on Linux `.chezmoidata/packages.toml`, the file that names each tool's package
on each distro, installs `gcc`. The no-sudo profile installs packages with mise,
which carries no compiler, so the filters stay unbuilt there and aerc renders
plain text and calendar parts unhighlighted. The script says so and exits 0
rather than failing the apply.

The whole Brewfile is installed, which takes a while — `grep -c '^brew ' ~/.config/Brewfile`
and the same for `^cask ` and `^mas ` say how much there is. Everything but the
App Store is installed first, and a failure there does stop the apply, because
the rest of the bootstrap needs those packages.

The App Store part is installed by `mas`, a command-line client for the Mac App
Store, and it needs the App Store app itself already signed in — open
App Store.app and sign in there, which `mas` cannot do. On a machine that never
has, `mas` waits for a sign-in rather than failing, so
`01-install-packages-darwin` gives that pass an hour. Reaching that ceiling
prints the same thing a failure does: the command that finishes the install once
the App Store is signed in. Neither stops the apply, because nothing later
depends on those apps.

On macOS and Linux with sudo the login shell changes for the account being set
up, and `chsh -s /bin/zsh` puts it back. Without sudo the login shell is left
alone and `~/.bashrc` starts fish instead, which is what `dot_bashrc.tmpl`
renders on that profile.

`04-setup-fish` and `08-setup-ssh` both stop and wait: the first for the account
password, which `sudo` and `chsh` each ask for, and the second for each key's
passphrase. `07-setup-nas` asks for it too, on a machine whose
`/etc/resolver/botasal.xyz` is missing or out of date, and says so first. An
apply with no terminal skips the passphrases and prints the command to run
later.

Scripts that do not apply to the current OS render empty, and chezmoi skips
empty scripts, so the darwin-only entries above simply do not exist on Linux.

### Confirming it worked

```sh
chezmoi status      # prints nothing when the target matches the source
chezmoi doctor      # chezmoi's own environment check
```

`doctor` prints one row per check, first column `ok`, `info`, `warning`,
`skipped` or `failed`. The `failed` rows are the ones to fix; `warning` rows —
a dirty source tree, say — accompany normal use.

`exec fish` starts the new shell without logging out.

On a machine that will push this repository, turn on the hook that keeps a
broken `main` from reaching the other machines — `core.hooksPath` is a local
git setting, so this is once per clone, from the source directory
(`chezmoi cd`):

```sh
git config core.hooksPath tests/githooks
```

### When a bootstrap script fails

A `run_once_` script is recorded as done, by its content hash, only when it
exits 0. Most of these set `-eu`, so they fail loudly and the next apply retries
them on its own. `01-install-packages-darwin` sets no `-e` — it has two halves
that fail for different reasons — and instead checks `brew bundle` itself: it
exits non-zero when anything but the App Store failed, so that case is retried
too, and reports an App Store failure without stopping the apply.

`02`, `03`, `06` and the decrypt script set no `-e` and are not checked, so a
command that fails inside one of them leaves the script exiting 0 and recorded.
`setup-xcode-cli` is the same apart from two failure points — the tools-install
timeout and a failed Rosetta install — each of which exits 1, stops the apply,
and is not recorded, so the next apply retries it. Clearing the record is what
re-runs one:

```sh
chezmoi state delete-bucket --bucket=scriptState   # forget every run_once_ hash
chezmoi apply -v                                   # run them all again
```

That re-runs every `run_once_` script, so they are written to be safe to repeat.
`03-setup-dock` drives dockutil, a command-line Dock editor from the Brewfile,
whose `--add` refuses an app the Dock already has — so a re-run adds nothing
and leaves the Dock in the order it was.
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
mise, rustup (the Rust toolchain manager) and uv (the installer for the
Brewfile's Python tools) — skipping the ones that are absent and listing
failures at the end rather than stopping at the first. It deliberately leaves `chezmoi update`
alone, because applying dotfiles can re-run bootstrap scripts.

## Commands

These deploy to `~/.local/bin`, which is on `PATH` on every profile.

The `git wt-*` commands manage worktrees. A worktree is a second checkout of a
repository in a folder of its own, and one clone can hold several, each on its
own branch, tag or commit. `git wt-clone` makes a bare clone, one with no
checkout of its own, in `.bare`, and puts each worktree in a folder beside it.

| command                    | what it does                                              |
| ---                        | ---                                                       |
| `git wt-clone <URL> [DIR]` | clone a repository as a bare clone plus per-ref worktrees |
| `git wt-add <REF>`         | check a branch, tag or commit out into its own folder     |
| `git wt-ls`                | list the clone's worktrees and what each holds            |
| `git wt-rm <REF>`          | remove a ref's worktree and its merged local branch       |
| `chezmoi-packages`         | maintain the Brewfile and the Linux manifest together     |
| `cask-updates`             | stop Homebrew's apps updating themselves (macOS)          |
| `mount-nas`                | keep the NAS share mounted while it is reachable (macOS)  |

`git-wt-clone` names the folder after the repository when no directory is given,
and creates the default branch's worktree straight away, tracking `origin`.
`git-wt-add` creates a branch that does not exist yet, confirming first when
run at a terminal — a typo'd ref would otherwise silently become a branch and
a folder. A branch already on `origin` tracks it; a tag or commit is checked
out detached; a brand-new branch is left with no upstream, so `git push` with
`push.autoSetupRemote` publishes it as `origin/<branch>` rather than refusing
because the branch it forked from has a different name.

`git-wt-rm` is `git-wt-add`'s counterpart and takes the same argument, the
ref: the folder is found by the same flattening, so `git wt-rm feature/foo`
removes `feature-foo/`. Two of git's own refusals guard it — `git worktree
remove` refuses uncommitted work, which `-f` discards, and the branch goes
through `git branch -d`, which refuses an unmerged one; the refusal is printed
with the `git branch -D` that overrides it, and `--keep-branch` keeps the
branch entirely. `git-wt-ls` prints one line per worktree — the folder, the
branch it holds or `detached`, and a `*` on the one the shell is in.

The fish functions live in `~/.config/fish/functions`, one function per file,
named after the function. `functions -v <name>` prints what each one is for.
The ones that come up:

| function        | what it does                                                          |
| ---             | ---                                                                   |
| `update`        | update every package on the machine, whatever installed it            |
| `chezmoi-sync`  | pull this machine's configuration back into the source state          |
| `brew`          | Homebrew, with the subcommands that desync the Brewfile blocked       |
| `mas`           | the App Store, with the same subcommands blocked                      |
| `khard`         | the khard address book (see [Contacts](#contacts)), recording every contact it writes in the source state |
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
- `mas install`, `get`, `purchase`, `lucky` and `uninstall` are refused for the
  same reason: the Brewfile records App Store apps too. There is no
  `chezmoi-packages` verb for them, so the route is `command mas …` and then
  `chezmoi-packages dump`, which is also what records an app installed through
  the App Store itself. `set -x
  DOTFILES_MAS_UNGUARDED 1` turns the guard off for a whole shell. `mas
  upgrade`, `outdated` and every query go straight through.
- `khard new`, `edit`, `add-email`, `merge`, `copy`, `move` and `modify` re-add
  the address book afterwards, encrypted. `set -x DOTFILES_KHARD_UNTRACKED 1`
  turns that off, and the card then lasts until the next `chezmoi apply`
  deletes it — see [Contacts](#contacts).
- `zip` puts `-x '*/.git/*' '.git/*'` after the archive name, which is the only
  place zip reads a pattern as an exclude rather than as the archive to write.
  The first catches a repository nested under what is being archived, the
  second the one at the top when the archive is made from inside a checkout.
  `.gitignore`, `.gitmodules` and `.github/` are archived.

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

These files decide what is installed, and they are written by different hands:

| file                          | holds                                                          |
| ---                           | ---                                                            |
| `private_dot_config/Brewfile` | what macOS installs — formulae, Homebrew's command-line packages; casks, its app packages; and Mac App Store apps |
| `.chezmoidata/packages.toml`  | the manifest: what each Linux target calls the same tool, or why it has none |
| `.chezmoidata/acli.toml`      | the `acli` release the no-sudo profile installs, and the digests that verify it — the one file in that directory edited by hand |

`private_dot_config/mise/config.toml.tmpl` is written from the manifest and
never by hand: it renders the manifest's `mise` names
into the config mise reads on the no-sudo Linux profile. An edit to
`~/.config/mise/config.toml` on that machine is replaced at the next apply, so a
version or a tool changes in the manifest.

The Brewfile is derived. `brew bundle dump` writes it from what the Mac has
installed — descriptions, taps (the third-party formula repositories Homebrew
has added), casks and Mac App Store apps included — so an edit made by hand is
gone at the next dump. The manifest is authored: it records a decision — what
Linux calls this tool, or why Linux does without it — that no machine can be
asked for.

A tool the distro's own package manager does not carry is not installed on
Linux, which keeps the dotfiles clear of tracking where each project publishes
its packages and what it considers the recommended way to install them. `gh`,
`acli` and `starship` are the exceptions. Fedora packages `gh` itself; Debian,
Ubuntu and the RHEL rebuilds take it from GitHub's own repository. `starship`
comes from its installer everywhere, because no base repository has it and it
is the shell prompt.

`acli`, Atlassian's command-line client for Jira, comes from the Brewfile on
macOS, through Atlassian's `atlassian/acli` tap, and from Atlassian's own apt
and rpm repositories on the `sudo` profiles. Atlassian packages it for no
rootless installer, so the no-`sudo` profile takes a pinned release tarball,
which `01-install-packages-linux` checks against its sha256 digest before
extracting it into `~/.local/bin`.

The pin is `.chezmoidata/acli.toml`, written by hand. It holds:

- `version`: the release the no-`sudo` profile installs.
- `sha256.amd64` and `sha256.arm64`: that release's digest for each
  architecture, checked before anything is extracted.

Both come from the `acli` formula in the `atlassian/acli` tap, where Atlassian
publishes a digest for each architecture. `brew cat atlassian/acli/acli` —
the tap's name, then the formula's — prints that formula on a machine with
Homebrew, and `github.com/atlassian/homebrew-acli` holds it for one without.
Atlassian publishes no digest for an unpinned `latest`, which is why a version
is pinned at all.

Moving to a newer release is an edit to the version and to each digest, then
an apply:

```sh
chezmoi cd
$EDITOR .chezmoidata/acli.toml
chezmoi apply -v
```

The pin is rendered into `01-install-packages-linux`, so the edit changes the
script, and a `run_once_` script whose content changed runs again at the next
apply. `acli --version` then prints `acli version <version>`, where
`<version>` is the `version` value in `.chezmoidata/acli.toml`. The `update`
fish function reports when the installed `acli` is not the pinned one — a
binary replaced since the last apply, say — and prints this, which runs
`01-install-packages-linux` again; an apply with the pin unchanged does not:

```fish
chezmoi execute-template --file (chezmoi source-path)/run_once_after_install-01-install-packages-linux.sh.tmpl | bash
```

One manifest entry per tool:

```toml
[packages.<NAME>]
brew = "<HOMEBREW_NAME>"
apt = "<APT_NAME>"        # Debian, Ubuntu, Pop!_OS
fedora = "<DNF_NAME>"     # Fedora
el = "<RHEL_NAME>"        # RHEL rebuilds: Rocky, AlmaLinux, CentOS Stream
mise = "<MISE_NAME>"      # the no-sudo profile, where mise is the package manager
mise_exe = "<EXE_NAME>"   # the binary mise installs, when it differs from the tool
repo = "official"         # the 01 script installs it from its own repository; the reason goes in note
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

Uninstalling is what keeps something out, because the Brewfile is a dump of the
machine: deleting a line by hand lasts until the next `chezmoi-packages dump`
puts it back.

### Apps this repository does not install

A rebuild installs these by hand, because no package manager on the machine
carries them:

| app | where it comes from | why |
| --- | --- | --- |
| MakeMKV | [makemkv.com](https://www.makemkv.com/download/) | Homebrew's `makemkv` cask is disabled, and `brew bundle` exits non-zero on a disabled cask, which fails `01` and stops the apply |

MakeMKV needs a registration key while it is in beta. The key expires and a
current one is posted on the MakeMKV forum, so a fresh install asks for it
again.

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
it was found — the keys `disable` wrote are deleted rather than set true, and a
value set by hand in an app's own preferences is left in place.

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

Apps that update through Keystone (Google's updater), an Electron app's
built-in updater, or their own installer expose no preference key worth
chasing. `status` lists them by name, and
`brew upgrade --greedy` owns their versions whenever it wins the race.

## Mounting the NAS

`nas.botasal.xyz` serves the share `Book2` over SMB. It is mounted whenever the
network allows and absent, without comment, when it does not — no authentication
sheet, no connection-failed alert, and no "the server connection was
interrupted" dialog after leaving the house.

```sh
mount-nas             # flush, mount when reachable, unmount when not (launchd)
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
mount raises alerts until it is cleared. The two read differently, so an eject
that reports `unmounted, the NAS stopped answering` is saying the NAS went away
under the mount; a plain eject reports `unmounted`.

A pass writes outstanding data back before it decides anything, whenever it
finds the share mounted and the NAS answering. macOS gives launchd no sleep
trigger, so nothing runs at the moment a lid closes; what a pass on every
network change and every 300 seconds gives instead is a bound on how much of the
share is unwritten by the time the network goes away. A NAS that has already
stopped answering is not flushed, because there is nowhere left to write to.

`mount-nas flush` covers the writes made since the last pass, and is the thing
to run by hand after writing to the share and before shutting the laptop.

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
change `-a lfiolhais` above and the line in
`dot_local/lib/python/mountnas.py` that reads

```python
USER = "lfiolhais"
```

together, because the lookup matches on both. `mount-nas` runs the deployed
copy, so the edit takes effect only after an apply:

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
autofs is out for the same reason: it would mount lazily and handle the network
coming and going for free, but `automountd` runs as root, so the password would
have to live in `/var/root/.nsmbrc`.

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

### Why the zone has its own resolver file

`/etc/resolver/botasal.xyz` names delta7 and stardestroyer, so every lookup of a
name in that zone goes to them from this Mac and nowhere else:

```
nameserver 192.168.1.78
nameserver 192.168.1.73
```

`07-setup-nas` writes it, and `scutil --dns` lists it among the resolvers macOS
is using.

Without it the zone is reachable two ways and they disagree. The Pi-holes serve
`nas.botasal.xyz`; the public `botasal.xyz`, delegated to Porkbun, carries none
of its names, so a query made anywhere else is answered NXDOMAIN. macOS caches
that for as long as the public zone's SOA allows — `dig botasal.xyz SOA`
prints that in its last field — and the laptop arrives home holding an answer
saying the NAS does not exist. With the file in place there is no public path to
answer: at home the Pi-holes do, and away from home the query times out, which
leaves nothing behind to serve on arrival.

Every name in the zone is on the home network, so the file covers all of them
rather than the NAS alone: away from home each one fails, and fails without
leaving a cached denial that outlasts the trip. The failure takes longer than a
public NXDOMAIN, since it waits out the resolver timeout.

### When the share is not appearing

`mount-nas status` separates the causes, since being away from home and being
misconfigured look identical from the Finder. Its first line is the verdict, and
the lines indented under it are why:

| status line | cause | fix |
| --- | --- | --- |
| `does not resolve` | `/etc/resolver/botasal.xyz` missing, or an answer cached before it was written | check that file, then flush the cache, below |
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

`dig nas.botasal.xyz` reads no cache, so it keeps answering while `getaddrinfo`
— what `mount-nas` and everything else on the machine call — does not. Trust
`dscacheutil -q host -a name nas.botasal.xyz` over `dig` here: it goes through
the same cache the rest of the system does.

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

### When the NAS refuses the account

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
setting says they agree. (PAM — Pluggable Authentication Modules — is the
system's login machinery.) `chage -l lfiolhais` settles which happened, since its
`Last password change` moves whenever the sync really runs, even where the
password it sets is the one already there.

The Keychain item still holds the old password after any of this, so re-run the
`security add-internet-password` command above; its `-U` updates the item in
place rather than refusing because one exists.


## Contacts

Contacts live in khard, a terminal address book that stores one vCard per
person in a directory. The address book here is called `work`: one
age-encrypted vCard per contact, in
`private_dot_config/khard/work/exact_default/` here and
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
than khard. `set -x DOTFILES_KHARD_UNTRACKED 1` turns the wrapper off; since
the source directory is `exact_`, a card written with it set reaches no other
machine and is deleted here at the next `chezmoi apply`.

Because each file is named after a uid and encrypted, `git status` and
`chezmoi status` name contacts in a way nobody can read. `khard-status` decrypts
each card and reports it by name, in three groups: on this machine and not in
the source, in the source and not on this machine, and different between the
two.

```sh
khard-status              # what differs, by contact name
khard-status -a work      # -a names the address book; `work` is the default
```

The source directory carries the `exact_` prefix, so `chezmoi apply` makes
`~/.config/khard/work/default` hold exactly the cards the source holds. That is
what carries a deletion from one machine to the others — and it is also what
deletes a card that was never recorded. Run `khard-status` before applying on a
machine that has been away from the source for a while, and `khard-track`
anything it lists under "on this machine, not in the source".

`khard-rm` deletes contacts and drops them from the source state in one step. It
opens an fzf picker, multi-select with TAB and confirm with ENTER:

```sh
khard-rm [-a|--addressbook NAME] [-n|--dry-run] [-N|--no-forget] [search terms...]
```

The picker lists each contact by name and by every email address on the card,
because two people share a name often enough that the name alone picks the wrong
one.

It resolves every uid through `khard filename` first and skips anything that
does not match exactly one card, because khard's `remove` takes free-text search
terms and has no `--uid` flag. `--dry-run` lists the selection and stops;
`--no-forget` deletes the contacts but leaves the source state alone.

A selection can include a card the source state has no entry for — one another
machine already dropped and whose commit has reached this source directory, or
one written here with `DOTFILES_KHARD_UNTRACKED` set. `chezmoi forget` takes
every path or none, so `khard-rm` asks `chezmoi managed` which cards have an
entry and forgets only those; the rest are deleted from this machine and named
in the output.

Deletions reach other machines when the source directory is committed and
pushed. Those machines pick them up with `chezmoi update`, which pulls and
applies — and so may re-run bootstrap scripts whose content has changed.

## Email

Four programs divide the job: mbsync pulls mail into `~/.local/share/mail`,
notmuch indexes it for searching, aerc is the terminal mail reader, and msmtp
sends. All four come from the Brewfile and the manifest, and mbsync is what the
isync package installs. The isync and notmuch configs are age-encrypted here;
passwords are not in this repository at all. On macOS they live in the login
Keychain, on Linux in `pass`, the GnuPG-backed password store.

`06-setup-mail` prints the steps for the current OS during the bootstrap —
the commands that seed the passwords included — and changes nothing itself, so
it can be re-read at any time from the source directory:

```sh
chezmoi cd
chezmoi execute-template < run_once_after_install-06-setup-mail.sh.tmpl
```

Proton Mail is reached through Proton Mail Bridge, whose TLS certificates are
exported from its Settings -> Advanced pane into `~/.config`. After any
credential or config change:

```sh
mbsync -a && notmuch new
```

## Editing

neovim is the editor, and `private_dot_config/nvim/init.lua`, deployed as
`~/.config/nvim/init.lua`, is the whole of its configuration: options,
keymaps, and the plugins with their settings. `<leader>`, the key most of its
keymaps start with, is the space bar.

The plugins are declared in one `vim.pack.add` call at the top of that file.
`vim.pack` is neovim's own plugin manager, so there is no separate one to
install or learn. It needs neovim 0.12 or newer; `nvim --version` prints which
is installed. The first start after an apply asks once to confirm installing
the plugins, then clones each with git into
`~/.local/share/nvim/site/pack/core/opt/`. A plugin added to that call is
installed at the next start. Updating them happens inside neovim:

```vim
:lua vim.pack.update()
```

That opens a tab listing what each update brings; `:write` there applies them
and `:quit` discards them. The `update` fish function leaves neovim's plugins
alone.

| plugin | what it is for |
| --- | --- |
| catppuccin | the colour scheme, `catppuccin-mocha` |
| mini.nvim | the file explorer (`<leader>e`), the file, grep and buffer pickers (`<leader>f`, `<leader>s`, `<leader>b`), completion, notifications, marks beside the lines changed since the last commit, and small editing helpers: surround, align, and trailing whitespace removed on save |
| vim-bufkill | `<leader>bd` closes a buffer and keeps its window |
| nvim-treesitter | parses each file for highlighting; the `install` call below the plugin list names the languages |
| nvim-treesitter-context | keeps the enclosing function or block in view at the top of the window |
| auto-session | saves the open files and window layout per directory, and restores them when neovim starts there |
| vim-fugitive | git from inside the editor, `<leader>g` |
| diffview.nvim | side-by-side diffs, `<leader>gdo` to open and `<leader>gdc` to close |
| octo.nvim | GitHub issues and pull requests, `<leader>oi` and `<leader>op` |
| plenary.nvim | a Lua library octo.nvim is built on |
| nvim-web-devicons | the file-type icons octo.nvim and the status line show |
| gitlinker.nvim | `<leader>gl` copies the web address of the current line, `<leader>gb` its blame page |
| lualine.nvim | the status line |
| vim-highlightedyank | briefly highlights what was just yanked |
| nvim-lspconfig | the language-server definitions the `vim.lsp.enable` calls start |
| conform.nvim | formatter settings: ruff, the Python linter and formatter, for Python, and the options of verible, the SystemVerilog formatter; no key runs it, `:lua require('conform').format()` does |

docket, the plugin for Jira tickets, merge requests and pull requests under
[Jira and reviews](#jira-and-reviews), is not in that list, because its files
are in this repository rather than in one of the repositories `vim.pack`
clones. neovim loads every plugin in a `pack/*/start/` folder under
`~/.local/share/nvim/site` when it starts; the plugins `vim.pack` clones sit
under `pack/core/opt/`, and each loads when the `vim.pack.add` call names it. This repository deploys docket
from `dot_local/share/private_nvim/private_site/pack/docket/start/docket/` to
`~/.local/share/nvim/site/pack/docket/start/docket/`, so it loads with nothing
to declare; `init.lua` carries its `setup` call, and beside auto-session's
setup the hook that keeps docket's buffers off a saved session's buffer list
and the `shada` entry that keeps them out of neovim's record of marks and
recent files; `:help docket-setup-sessions` describes both. An apply is what
updates it. Its reference is `:help docket`, and changing it starts at the
plugin's own
[README.md](dot_local/share/private_nvim/private_site/pack/docket/start/docket/README.md).

neovim writes files beside what this repository tracks, and none of them is
tracked, because nothing a program writes is (see
[Adding to this repository](#adding-to-this-repository)):

- `~/.config/nvim/nvim-pack-lock.json`, the revision of each plugin, which
  `vim.pack` rewrites at every install and update. Each machine installs every
  plugin at its newest revision and moves on when `vim.pack.update()` is run
  there.
- `~/.local/share/nvim/sessions/`, where auto-session keeps one session per
  directory, naming that machine's files and window layout.
- `doc/tags` in docket's folder, the index behind `:help docket`, which
  docket writes when neovim starts and the help file is newer than it.

`chezmoi-sync` lists the lock file and `tags` among the untracked files at
every run, because each sits in a directory that holds a tracked file.
Neither is to be added.

## Jira and reviews

docket is a neovim plugin this repository deploys. It brings a clone's Jira
tickets into the editor, beside its merge requests on GitLab or its pull
requests on GitHub, whichever hosts the clone's `origin` remote. `:help
docket` is the reference for each of its modes, and changing docket starts at
the plugin's own
[README.md](dot_local/share/private_nvim/private_site/pack/docket/start/docket/README.md).

It reaches each service through that service's own command-line client:
`acli`, Atlassian's command-line client for Jira; `glab`, GitLab's; and `gh`,
GitHub's, with a pull request itself opening in octo.nvim. The bootstrap
installs them. `acli` and `gh` are among the tools the Linux profiles take from
outside the distribution, and [Packages](#packages) says where each profile
gets them, including the release of `acli` that `.chezmoidata/acli.toml` pins
for the no-`sudo` profile. `glab` comes from the Brewfile on macOS and from
mise on the no-`sudo` profile; the `sudo` profiles install none, because
`glab`'s manifest entry names no distro package. tmux is installed on macOS
and on the `sudo` profiles, and the no-`sudo` profile uses whatever tmux the
machine already has.

### Signing in

Each service needs an account that already exists: one on a Jira Cloud site,
on a GitLab host, or on GitHub. Signing in connects the local client to that
account and creates nothing.

Each client is signed in once per machine, after the first apply, from inside
neovim. Only the ones in use need it:

```vim
:Docket login jira
:Docket login glab
:Docket login gh
```

Run inside a clone, `:Docket login` with no name signs in Jira and the client
the clone's `origin` remote points at. Each asks for what its client needs
besides the token — the Jira site, as `example.atlassian.net`, and the
account's email, or the GitLab or GitHub host — then prints the page where a
token is minted and offers to open it, then asks for the token without
echoing it:

| client | token page |
| --- | --- |
| `acli` | `https://id.atlassian.com/manage-profile/security/api-tokens` |
| `glab` | `https://<host>/-/user_settings/personal_access_tokens` |
| `gh` | `https://<host>/settings/tokens` |

Minting the token is the one step that needs a browser. docket stores no
credential: each client keeps its own token, as `:help docket-auth` says. So
there is no token to put in a secret store and nothing to restore after a
rebuild beyond running `:Docket login` again, and a `gh` login serves
octo.nvim too. A shell exporting `GH_TOKEN`, `GITHUB_TOKEN` or `GITLAB_TOKEN`
is already signed in for that client.

```vim
:checkhealth docket
```

run from inside a clone, confirms it: under `docket: backends`, each client
the clone uses reads `jira: signed in`, `glab: signed in` or
`gh: signed in`, followed by the client's own status output. A client no
configured section needs there, such as `gh` in a clone on GitLab, reads
`gh: no configured section needs it here; not checked`, and is not run.
`:help docket-health` covers the other lines.

### Binding a repository to its Jira projects

The dash shows a repository's tickets once the clone is bound to its Jira
projects. From any folder of the clone:

```sh
acli jira project list --paginate            # every project the account can see, with its key
git config --add dotfiles.jira.project PAY   # the key; repeat for each further project
git config dotfiles.jira.epic PAY-10         # optional: only that epic's children
```

In a clone made with `git wt-clone` the values land in `.bare/config`, and in
a plain clone in `.git/config`; either way every worktree of the clone reads
them, worktrees made later included, so they are set once per clone. They
live in the clone rather than in this repository, so a fresh clone needs
them again. `git config --get-all dotfiles.jira.project` prints the projects
bound, and `git config --get dotfiles.jira.epic` the epic. The epic narrows
every Jira section of the dash to that epic's children, and set alone it
binds the clone to the epic's project; `git config --unset
dotfiles.jira.epic` clears it. An unbound clone shows only the account's own
tickets, from every project, and refuses to build a worktree for one, since
the ticket could belong to another repository. Binding by a complete query
instead, and marking a repository as having no Jira, are under `:help
docket-binding`.

`:Docket` inside the clone, or `<leader>dd`, then opens the dash, and
`:help docket` covers everything done from there.

## Sign-off on RISC-V commits

RISC-V projects require a Developer Certificate of Origin sign-off, and their
CI rejects a commit that carries no `Signed-off-by` trailer.
`format.signOff` in `~/.gitconfig` puts one on `git format-patch` output, which
covers a patch sent to a mailing list; a commit that goes out as a pull request
is not format-patch output and carries nothing.

A `prepare-commit-msg` hook adds the trailer. git runs that hook for every
commit whatever wrote the message, so `-m`, `--amend` and an editor commit are
covered alike, an amend on a message that already has the trailer leaves one,
and a sign-off joins an existing trailer block rather than starting a second
one. Merge messages are left as git wrote them.

The hook is turned on per remote rather than globally, because `core.hooksPath`
replaces `.git/hooks` wherever it applies and would otherwise disable every
other repository's hooks. Three files do it:

| file | holds |
| --- | --- |
| `~/.gitconfig` | the `includeIf hasconfig:remote.*.url` patterns that pick the clones |
| `~/.config/git/dco.inc` | the `core.hooksPath` those patterns turn on |
| `~/.config/git/hooks-dco/prepare-commit-msg` | the hook itself |

Whether a clone matched:

```sh
git config --show-origin --get core.hooksPath
```

It names `dco.inc` where the conditional matched and prints nothing where it did
not. A clone that sets `core.hooksPath` in its own `.git/config` — this
repository does, for `tests/githooks` — keeps that setting and gets no sign-off.

Another project that wants the trailer takes a pattern pair at the end of
`private_dot_gitconfig.tmpl`, one for the https remote and one for ssh, because
the conditional matches the URL as written:

```ini
[includeIf "hasconfig:remote.*.url:https://github.com/example/**"]
	path = ~/.config/git/dco.inc
[includeIf "hasconfig:remote.*.url:git@github.com:example/**"]
	path = ~/.config/git/dco.inc
```

`hasconfig:remote.*.url` needs git 2.36; `git --version` says whether this
machine's qualifies.

## Adding to this repository

`chezmoi add ~/path` applies the naming prefixes to a file that already exists
on the machine. A file written here first gets them by hand: `dot_` for a name
starting with a dot, `private_` for one only its owner may read, `executable_`
for one that deploys as `0755`, `encrypted_` for an age blob, `exact_` for a
directory that is to hold exactly what the source holds, and `.tmpl` for a file
chezmoi renders rather than copies.

A file naming a path, an option or a flag that only one OS has is a template
gated on `.chezmoi.os`, so the other one renders without it. `UseKeychain` in
the ssh config, `/opt/homebrew`, and a home directory that is not under
`/Users` are the ones that keep coming back.

A new fish function is one file per function under
`private_dot_config/private_fish/functions/`, named after the function, because
fish autoloads by filename.

A new command goes in `dot_local/bin/` with the `executable_` prefix, and the
Python it is built on in `dot_local/lib/python/`. Each group of modules there
has one that re-exports the rest, and that name is the command's only import.
Adding the command to `DEPLOYED_ENTRY_POINTS` in `tests/check.py` is what runs
its `--help` under every `python3` on the host and puts it under ruff.

Python here passes `ruff check` and `ruff format` with the config in
`tests/pyproject.toml`, which also enforces Google-style docstrings —
`Args:`/`Returns:` sections on every public function. The deployed libraries
stay Python 3.9-clean and standard-library-only, because a fresh Mac and the
RHEL rebuilds ship 3.9 — except `chezpkg`, which uv runs on an interpreter it
supplies. `tests/check.py` imports each library under every `python3` on the
host, which is what catches a construct ruff cannot see. The same checks run
from the `pre-push` hook, and by hand:

```sh
ruff check --config tests/pyproject.toml dot_local/lib/python dot_local/bin tests/*.py
ruff format --check --config tests/pyproject.toml dot_local/lib/python dot_local/bin tests/*.py
```

Nothing a program writes is tracked — a compiled filter, a cache, an editor's
state. Track what it is built from and build it in a `run_onchange_` script.
`tests/check.py` fails on a compiled binary or a program-written name anywhere
in the source.

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
runs `check.py` before any push to `main`; enabling it is part of installing,
and the command is under "Confirming it worked".

[tests/README.md](tests/README.md) documents the harness and the hook in full.
