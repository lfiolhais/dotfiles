# dotfiles

macOS is the primary target. Linux is supported in two profiles, chosen by the
`sudo` prompt at `chezmoi init` time: **with sudo**, where apt or dnf installs
everything, and **without sudo**, where [mise](https://mise.jdx.dev) installs a
rootless toolchain under `~/.local`.

## Handy Scripts and Tools

### Fish Shell

* `update` => updates the machine afterwards, walking whichever package
  managers it finds (brew and mas, apt or dnf, mise, rustup, uv).
* `get_contact` => searches a contact in khard's database through fzf.
* `khard-rm` => deletes contacts in khard. Will pop an fzf window and allow you
  to select the contacts to delete.
* `khard-track` => updates chezmoi's khard's state. Runs `chezmoi add
  ~/.config/khard/work/default`.

### Git

* `executable_git-wt-clone` => git subcommand to clone a repository as a
  worktree. Can be used as `git wt-clone <URL>`. Will automatically set up the
  references correctly to upstream.

* `executable_git-wt-add` => git subcommand to add a worktree to a repository.
  Can be used as `git wt-add <BRANCH|REF|TAG>`. Will create a branch
  automatically if it doesn't exist.

## Packages

The packages installed by the dotfiles reside in two files:

| file | holds |
| --- | --- |
| `private_dot_config/Brewfile` | what macOS installs — formulae, casks, Mac App Store apps |
| `.chezmoidata/packages.toml` | what each Linux target calls the same tool, or why it is not installed there |

The goal is to always keep both files in sync.

To avoid overcomplicating the dotfiles, we ignore tool's that aren't natively
supported by the distro's package manager. This is done to avoid keeping track
of the multiple repos tools live and their "recommended way" of installing
them. There are two exceptions: `gh` (from GitHub's own apt/dnf repository) and
`starship` (from its installer), because neither is in any base repository and
starship is the shell prompt.

The Linux packages are kept in `.chezmoidata/packages.toml` with the following
syntax:

```toml
[packages.<NAME>]
brew = "<HOMEBREW_NAME>"
fedora = "<DNF_NAME>"
mise = "<MISE_NAME>"
apt = "<APT_NAME>"
el = "<RHEL_NAME>"
note = "Explain why this package is omitted in a Linux target."
```

If a target isn't present within the TOML block, the binary won't be
installed by the target. Packages that are always skipped by Linux
targets are kept in the `skip` block at the end of the document.
Skipped packages are encoded as:
```toml
[skip]
<BIN_NAME> = "<REASON_FOR_SKIP>"
```

## Testing

There is no build. "Testing" a change means `chezmoi diff`, then the harness:
`tests/check.py` on the host, `tests/linux.py` for the Linux targets in Docker,
`tests/macos.py` for macOS in a Lume VM. See [tests/README.md](tests/README.md),
which also covers the `pre-push` hook that runs `check.py` before a push to
`main`:

```sh
git config core.hooksPath tests/githooks
```
