# docket

docket brings Jira tickets, GitLab merge requests and GitHub pull requests
into neovim, the editor the work is written in. Jira is Atlassian's issue
tracker; a merge request and a pull request are each a code review over a
branch, on GitLab and on GitHub. `:help docket` says what each mode does for
the person using it and is the reference for all of it; this file is where
working on docket starts.

docket is deployed by the dotfiles repository `lfiolhais/dotfiles` — a
source directory for chezmoi, the dotfile manager that copies the
repository's files into the home directory — and has no install path of its
own. This folder sits inside that repository, and "the repository's
`README.md`" below is the `README.md` at its root. `chezmoi source-path`
prints the root on a machine chezmoi has initialised, and `git rev-parse
--show-toplevel` prints it from any folder of a clone.

docket reaches each service through that service's own command-line client
and stores nothing of its own: `acli`, Atlassian's client, for Jira; `glab`,
GitLab's; and `gh`, GitHub's, with a pull request itself opening in
octo.nvim, the GitHub plugin the editor configuration installs.

## What has to exist first

The first apply of the repository runs bootstrap scripts that install the
editor and the clients; "What the first apply changes" in the repository's
`README.md` lists them. The launcher, named twice below, is what `w` and `R`
on the dash run: a git worktree for the ticket or the merge request, and two
tmux windows in it, `:help docket-work`. Each row prints something when it is
in place:

| needed | prints | supplied by |
| --- | --- | --- |
| neovim 0.12 or newer | `nvim --version` | the bootstrap scripts; "Editing" in the repository's `README.md` says why 0.12 |
| `acli`, `glab`, `gh`, and `tmux`, the terminal multiplexer, for the launcher's windows | `command -v acli glab gh tmux` | the bootstrap scripts; "Jira and reviews" in the repository's `README.md` says where each profile gets them |
| `git wt-add`, which the launcher runs, and `git wt-clone`, which makes the clone layout it needs | `command -v git-wt-clone git-wt-add` | `dot_local/bin/` in the repository |
| octo.nvim and diffview.nvim, where a pull request and a review's diff open | `:lua print(vim.fn.exists(":Octo") == 2, vim.fn.exists(":DiffviewOpen") == 2)` prints `true true` | the `vim.pack.add` call in `private_dot_config/nvim/init.lua`; "Editing" in the repository's `README.md` |
| an account on each service in use: a Jira Cloud site, which is a Jira instance at `https://<name>.atlassian.net` run by the organisation whose tickets these are; a GitLab host; GitHub | `:checkhealth docket`, under `docket: backends`; Jira wherever a section names it, and a GitLab host or GitHub when run inside a clone whose `origin` is on it, or wherever a section's `adapter` is `glab` or `gh`; otherwise `glab` and `gh` read `no configured section needs it here; not checked` | the person; signing in is "Signing in" in the repository's `README.md` |

Everything else docket runs on is neovim's own. Away from tmux the launcher
opens a tab of the running editor instead of the two windows, `:help
docket-work`. A plain clone works for everything but the launcher, which
needs a clone made by `git wt-clone`.

## The first command

`:Docket` exists once docket is on neovim's package path: an apply of the
repository puts it there ("Editing here, never in the deployed copy" below),
and "Trying a change from the source tree" runs it from this folder without
one. In an editor with neither, `:Docket` answers `E492: Not an editor
command: Docket`.

Sign each client in once per machine, from inside neovim, as "Signing in" in
the repository's `README.md` walks it:

```vim
:Docket login jira
```

Then, from any folder of a clone bound to its Jira projects ("Binding a
repository to its Jira projects" in the same file), the dash:

```vim
:Docket
```

It opens in the current window and lists the clone's tickets and reviews in
sections; `:help docket-dash` reads it. An unbound clone opens the dash too,
with one Jira section, titled `(unbound)` after its name, holding the
account's own tickets from every project and the binding command; `:help
docket-binding`. `<leader>` is the key `vim.g.mapleader` holds (`:help
mapleader`), which `private_dot_config/nvim/init.lua` in the repository sets
to the space bar, so `<leader>dd` is the same command.

## What is not undone

These reach a service or the machine, and no docket command reverses them:

- `:Docket login <backend>` signs the client in, and the token goes where
  `:help docket-auth` says. The client's own `gh auth logout`, `glab auth
  logout` or `acli jira auth logout` removes it.
- `:w` in an item buffer posts every region that changed to the ticket or
  the merge request, `:help docket-save`; `<leader>dt` and `<leader>da` change
  its state and assignee the moment a choice is made, `:help docket-state`;
  `:w` in a new ticket's draft creates the ticket, `:help :Docket-create`.
- `:Docket review submit` posts the held comments and the verdict, and
  `:Docket review resolve` resolves a thread at once, `:help
  docket-review-submit` and `:help docket-review-verbs`. A comment held with
  `:Docket review comment` is in the editor alone until then.
- `w` and `R` on the dash, `<leader>dw` in an item buffer, and `<leader>dR`
  in a merge request's buffer make a worktree and, inside tmux, two windows;
  away from tmux, a tab of the running editor. Removing either is under
  "Removing an environment" in `:help docket-work`.

## Working on docket

### The folder

```text
plugin/docket.lua        what neovim runs at startup: the command, the map, the autocommands
lua/docket/*.lua         the modules, each `require("docket.<name>")`
lua/docket/adapters/     one module per backend, and the registry in init.lua
doc/docket.txt           the reference behind :help docket
ARCHITECTURE.md          how the modules fit, for changing them
```

`doc/tags`, the index behind `:help docket`, is written by neovim beside
`docket.txt` when docket's `setup{}` runs and the help file is newer than
the index. It is never tracked; "Editing" in the repository's `README.md`
lists it among the files a program writes.

### How neovim finds and loads it

The plugin is a neovim package: a folder under `pack/*/start/` of a
directory on `'packpath'`, and `~/.local/share/nvim/site` is one. At startup
neovim searches every `pack/*/start/*` folder for runtime files and sources
the files in its `plugin/` folder, without listing the folder in
`'runtimepath'`, so `:set rtp?` does not show it and nothing in the
configuration declares it (`:help packages`, `:help runtime-search-path`,
`:help load-plugins`). This prints the copy neovim loaded:

```vim
:lua print(vim.api.nvim_get_runtime_file("lua/docket/init.lua", false)[1])
```

`plugin/docket.lua` declares the `:Docket` command, the `<leader>dd` map and
the autocommands that route `:e` and `:w` in a `docket://` buffer, and calls
`require` only inside their bodies, so startup loads no docket module:
`require('docket').setup {}` in the configuration loads `init`, `config` and
`highlight`, and the first `:Docket` loads the rest. "The shape of the
plugin" in `ARCHITECTURE.md` says what a module is and what `require` does
with one. This shows both states:

```vim
:lua print(vim.inspect(vim.tbl_filter(function(k) return k:match("^docket") end, vim.tbl_keys(package.loaded))))
```

### Editing here, never in the deployed copy

`chezmoi apply` copies this folder over the deployed copy, the one the print
under "How neovim finds and loads it" names, so an edit made there lasts
until the next apply. The edit goes here, and an apply carries it over;
"Everyday use" in the repository's `README.md` covers applying, and
`chezmoi diff` shows what one would change.

### Trying a change from the source tree

The source copy runs without an apply. The editor below is isolated from the
machine's neovim: its configuration, sessions, cache and log go to throwaway
directories, and `'packpath'` gets the source tree's `private_site` folder
first, so its `pack/docket/start/docket` is the copy that loads; with
`XDG_DATA_HOME` pointed away, the deployed copy is on no path at all. The
clients are not isolated: `acli`, `glab` and `gh` are the machine's own,
signed in as they are, so a login or a `:w` in an item buffer here reaches
the real account as it would from the deployed copy. The source tree supplies
the plugin alone, so every row of "What has to exist first" still has to
hold on the machine.

The lines below read alike in bash and in fish 3.4 or newer, which reads
`$(...)` as bash does; `fish --version` prints which is installed:

```sh
mkdir -p /tmp/docket-try/{config,data,state,cache}
env XDG_CONFIG_HOME=/tmp/docket-try/config XDG_DATA_HOME=/tmp/docket-try/data \
    XDG_STATE_HOME=/tmp/docket-try/state XDG_CACHE_HOME=/tmp/docket-try/cache \
    nvim --cmd "set packpath^=$(chezmoi source-path)/dot_local/share/private_nvim/private_site"
```

Inside that editor, the print from the section above answers with a path
under the source tree, ending in
`private_site/pack/docket/start/docket/lua/docket/init.lua`, and `:Docket`
runs the source. The same check without an interactive session:

```sh
env XDG_CONFIG_HOME=/tmp/docket-try/config XDG_DATA_HOME=/tmp/docket-try/data \
    XDG_STATE_HOME=/tmp/docket-try/state XDG_CACHE_HOME=/tmp/docket-try/cache \
    nvim --headless --cmd "set packpath^=$(chezmoi source-path)/dot_local/share/private_nvim/private_site" \
    -c 'lua print(vim.api.nvim_get_runtime_file("lua/docket/init.lua", false)[1])' \
    -c 'lua print(vim.fn.exists(":Docket"))' -c q
```

It prints the source path and then `2`, the value `exists()` gives a command
that is defined. The dash's cached rows land under
`/tmp/docket-try/cache/docket`, and `rm -rf /tmp/docket-try` ends it. A
module keeps the code it had when the editor first required it, and every
module that required it holds that same table, so a change made while this
editor is open is picked up by quitting it and starting it again.

Do not call `require('docket').setup {}` in this editor: it writes `doc/tags`
into the source tree, and `tests/check.py` refuses a `tags` file anywhere in
the source. The throwaway configuration holds no `init.lua`, so `setup{}`
does not run there: the `Docket*` highlight groups are undefined, and `:help
docket` answers `E149: No help for docket`, because `setup{}` is what writes
the help index. A `doc/tags` written by mistake comes out with:

```sh
rm "$(chezmoi source-path)/dot_local/share/private_nvim/private_site/pack/docket/start/docket/doc/tags"
```

To read the help text as edited, index a copy instead:

```sh
mkdir -p /tmp/docket-try/help/doc
cp "$(chezmoi source-path)/dot_local/share/private_nvim/private_site/pack/docket/start/docket/doc/docket.txt" /tmp/docket-try/help/doc/
nvim --headless -u NONE -c 'helptags /tmp/docket-try/help/doc' -c q
nvim -u NONE --cmd 'set rtp^=/tmp/docket-try/help' -c 'help docket'
```

### Running the gate and the suite

The repository's harness parses every Lua file and runs docket's test suite
among its checks; "`check.py` — host harness" in `tests/README.md` says what
else it covers and what it needs installed. The gate and the suite also run
on their own, in seconds and with `nvim` alone installed, which is why they
are spelled out here. Both take absolute paths, so they run from any
directory.

The gate compiles each file without running it, so a syntax error is caught
before the suite loads anything:

```sh
find "$(chezmoi source-path)/dot_local/share/private_nvim/private_site/pack/docket/start/docket" \
     "$(chezmoi source-path)/private_dot_config/nvim" -name '*.lua' -print0 \
  | sort -z | xargs -0 nvim -u NONE -l "$(chezmoi source-path)/tests/luagate.lua"
```

It prints nothing and exits 0 when every file parses; a file that does not
is reported with the parser's own message, as `<path>:<line>: <reason>`, and
the exit code is 1.

The suite runs under `nvim -l`, neovim's script mode, because the modules
call into `vim.*`:

```sh
nvim -u NONE -l "$(chezmoi source-path)/tests/docket.lua"
```

It prints `ok    <name>` for each test as it passes, ends with
`<passed>/<total> passed` and exits 0; a failing test prints `FAIL  <name>`
with the assertion's message indented under it, and the exit code is 1. A run
takes about ten seconds. No client, git or tmux runs, and a test that reaches
one without a stand-in fails rather than running it; "The suite" in
`ARCHITECTURE.md` says how. The suite tests this source tree whether or not
docket is deployed on the machine: it takes any installed copy off the
runtime path and `'packpath'` before it loads a module, and its last test
fails when a docket module was read from anywhere else.

### Where to read next

1. `:help docket`, in the deployed editor: what each mode does as the person
   using it sees it. `ARCHITECTURE.md` cites its tags rather than restating
   them.
2. `ARCHITECTURE.md`, from "The shape of the plugin": the modules, the rule
   that orders them, and each mode traced from the command to the client
   call.
3. `ARCHITECTURE.md`, under "Adding to docket": the walked procedure for a
   new adapter, command or dash section.
4. `lua/docket/commands.lua`: every mode starts in `M.run` there, and the
   function it dispatches to names the module to open next.
