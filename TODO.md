# TODO

Defects in the `docket` work on the `docket` branch. None blocks the rest of it; each
item below carries its own remedy, or says why none is settled yet.

`docket` is a neovim plugin for Jira tickets, GitLab merge requests and GitHub pull
requests: the dash, one buffer listing what is outstanding; an item read and commented
on in a buffer; any of them turned into a git worktree with two named tmux windows; and
a merge request reviewed as a diff.

## Record the mode the apply sets on ~/.local/share/nvim

Managing the package puts `~/.local/share/nvim` and `~/.local/share/nvim/site` under
chezmoi, which applies a mode to both. Both source directories carry chezmoi's
`private_` attribute, so the apply makes them 0700 rather than the default 0755 —
0700 is what neovim gives the directories it creates for itself, so managing them
changes nothing a fresh machine would have had. `chezmoi diff ~/.local/share/nvim`
prints the mode this machine's apply changes.

`README.md`'s "What the first apply changes" gains a row saying the apply sets both
directories to 0700.

## Describe state colours by category in the help file

`doc/docket.txt` says the state groups are read off the state's name, under the
`hl-DocketState*` tags. `highlight.state_group` colours a Jira state by its status
category, the `category` a Jira row and item carry from `statusCategory.key`, and a
review's state by the client's fixed state words, so those entries change with the help
file's rewrite in phase 9.

## Split the acli documentation so it can be read

Every fact `README.md` gained about `acli` is correct and the section cannot be read.

The `01-install-packages-linux` cell of the bootstrap table carries two em-dash
asides, a semicolon and a trailing subordinate clause. A table cell is a label: it
says what the script installs and nothing about how — apt or dnf, or a rootless mise,
plus starship, `gh` and `acli` from outside the distribution.

The `acli` paragraph below it states nine things without a break: what `acli` is, the
route on each profile, the digest check, the file the pin lives in, that it is
hand-written, where the digests come from, why none exists for an unpinned release,
how to move to a newer one, and what the `update` function reports. Each belongs; the
paragraph does not. Split it into what `acli` is and where each profile gets it, the
pin and its digests as a labelled list, and upgrading as its own paragraph carrying
the edit and the command.

## Name the deployed Python that no check reads

`check_coverage` fails on `dot_claude/skills/sandboxed-ssh/executable_socks-proxy.py`:
"deployed python3 that no check reads". It has been tracked since `3d4cb47`, the
baseline commit, and `tests/check.py` has never named it, so the harness has reported
this on every host that runs it. It is unrelated to `docket`.

Either it is a deployed command, or it is not and it moves out of a directory that
deploys.

If it is, the list to name it in is `DEPLOYED_ENTRY_POINTS`, which `DEPLOYED_PYTHON` is
built from along with the `dot_local/lib/python` glob — `DEPLOYED_PYTHON` itself is
derived and cannot be added to. Naming it there puts it under ruff and runs it under
every `python3` on the host, which means it also has to pass the 3.9 floor and the ruff
configuration in `tests/pyproject.toml`. Note that `DEPLOYED_ENTRY_POINTS` holds only
`dot_local/bin` commands today, so this would be the first entry from anywhere else.
