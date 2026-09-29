# How docket is built

This document is for changing the code. `README.md` beside it says what
docket is, what it runs on and how to run the source; `:help docket` says
what each mode does for the person using it, and this document cites its
tags rather than restating them. The modules are Lua, run by the LuaJIT
interpreter inside neovim, so the language is Lua 5.1 with neovim's `vim`
table added. Each construct the code leans on is named where it first
matters, with a reference: the Lua 5.1 manual at
<https://www.lua.org/manual/5.1/manual.html>, LuaJIT at <https://luajit.org/>,
and neovim's own help, whose `:help` tags are also pages under
<https://neovim.io/doc/user/>. `:help lua-guide` is neovim's introduction to
writing Lua in the editor. The shell commands in this document run from the
plugin's folder, which
`cd "$(chezmoi source-path)/dot_local/share/private_nvim/private_site/pack/docket/start/docket"`
reaches from anywhere; the one that reads `tests/docket.lua`, at the
repository's root, spells that path in full.

## The shape of the plugin

A table is Lua's one structured value: it holds named fields and numbered
entries alike, so it serves as a record, a list and a dictionary (`:help
lua-table`; the manual's section 2.2,
<https://www.lua.org/manual/5.1/manual.html#2.2>). Every file under
`lua/docket/` is a module: it builds a table, conventionally `M`, puts its
functions and constants on it, and returns it. `require` runs the file the
first time that module is asked for and caches the table in
`package.loaded`, so every requirer shares one table and a module's local
variables are state for the whole editor session (`:help lua-module-load`;
the manual's section 5.3, <https://www.lua.org/manual/5.1/manual.html#5.3>).
The same caching means an editor keeps the code a module had when first
required; `README.md`, under "Trying a change from the source tree", says
what that costs while editing. A function declared `local` inside a file is
private to it; a function on
`M` is the module's interface, and each carries a `---` comment saying what
it takes and returns.

The modules import strictly downwards: each requires only modules above it
in the table below, which is what keeps the graph free of cycles and lets the
leaf modules be tested with nothing but themselves. The adapters are the one
place a module is reached by name at run time: `adapters/init.lua`, the
registry, loads `docket.adapters.<name>` under `pcall(require, ...)` the
first time it is asked for that name, so no module above it lists the
adapter modules, and a client this machine lacks costs nothing at startup.
`pcall` calls a function and returns whether it raised and what, instead of
raising through the caller (`:help pcall()`; the manual at
<https://www.lua.org/manual/5.1/manual.html#pdf-pcall>).

Each module opens with a comment saying what it holds and what it imports.
The imports column below is read off the `require` calls, and this prints
them for a check after a change:

```sh
grep -o 'require("docket[^"]*")' lua/docket/*.lua lua/docket/adapters/*.lua | sort -u
```

| module | holds | imports |
| --- | --- | --- |
| `config.lua` | the defaults: the dash's sections, the cache directory, each kind of process's timeout; `configure()` for `setup{}` | nothing local |
| `row.lua` | `SOURCES`, the backend names in dash order; the one row shape every adapter normalises to, `fork` among its fields, and its ordering | nothing local |
| `item.lua` | an item's header fields, body and comments; `regions()`, the ownership half of whether a region may be written; `parse_time()` and `ago()` | nothing local |
| `adf.lua` | Atlassian Document Format, Jira's body tree: `render()` to lines, `serialise()` from text to the minimal tree a write sends, `editable()` for whether a tree survives that | nothing local |
| `diff.lua` | `plan()`, the region compare that decides which calls a save makes | nothing local |
| `flight.lua` | one request in flight per key and the rule for joining it | nothing local |
| `highlight.lua` | the `Docket*` groups, what each links to, and `state_group()` | nothing local |
| `render.lua` | an item to buffer lines, with the range each region occupies | `adf`, `item` |
| `spawn.lua` | the only process spawn: `run()` with a callback, `wait()` blocking, and the timeout that ends a command's whole process group | `config` |
| `repo.lua` | the clone in hand: its root, its Jira binding and the query assembly, the review client its `origin` names and the project path, the paths its other remotes name and `same_project()`, the compare without case, its worktrees | `config`, `spawn` |
| `env.lua` | the launcher: the branch and window-name rules, `git wt-add`, the two tmux windows or an editor tab, and `teardown()` | `config`, `repo`, `spawn` |
| `adapters/init.lua` | the adapter contract, the capability set and `verify()`, all under "The adapter contract" below, and the registry `get()` | `row` |
| `adapters/jira.lua` | Jira over `acli`: each region written back as a document through `adf`; states, assigning, creating a work item | `adapters`, `adf`, `flight`, `item`, `row`, `spawn` |
| `adapters/glab.lua` | GitLab over `glab`, the review calls included; a row's `fork` from the merge request's two project ids | `adapters`, `config`, `flight`, `item`, `row`, `spawn` |
| `adapters/gh.lua` | GitHub over `gh`: rows, with `fork` from `isCrossRepository`, and the handoff of an item to octo.nvim | `env`, `flight`, `row`, `spawn` |
| `cache.lua` | the dash's rows on disk under a format number, their age, and one request per key through `flight` | `config`, `flight`, `row` |
| `auth.lua` | the login flow; `ready()`, the blocking state check every mode makes first, and `check()`, its callback form for the dash | `adapters`, `cache`, `config`, `spawn` |
| `complete.lua` | the `omnifunc` an item buffer names: the trigger rule and the adapter's candidates | `adapters` |
| `review.lua` | the review mode: the diff in diffview.nvim, the discussions drawn at their lines, the comments held until a submit, the compose windows | `adapters`, `auth`, `config`, `flight`, `highlight`, `spawn` |
| `list.lua` | the dash buffer: its sections, one state check per backend, the row under the cursor | `auth`, `cache`, `config`, `flight`, `highlight`, `item`, `repo` |
| `buffer.lua` | the item buffer: its read path, its region marks, `compose()` for a new comment, and its write path | `adapters`, `auth`, `cache`, `diff`, `highlight`, `item`, `render`, `repo`; `complete` under `pcall`, so an item buffer works without it |
| `commands.lua` | what `:Docket` dispatches to, every keymap, the dash's refusals of a row through `foreign()` and `refused_fork()`, a new ticket's draft, the review's verbs | `adapters`, `auth`, `buffer`, `cache`, `config`, `env`, `list`, `repo`, `review`, `row` |
| `init.lua`, required as `docket` | `setup()`: the options, the highlight groups, the help tags; `help_files()`, the one lookup of the help file and its tags | `config`, `highlight` |
| `health.lua` | `:checkhealth docket` | `adapters`, `auth`, `config`, `docket`, `row` |

`plugin/docket.lua`, outside `lua/`, is what neovim sources at startup. It
declares the `:Docket` command, the `<leader>dd` map and the autocommands,
and requires `docket.commands` or `docket.buffer` only inside a callback, so
startup loads no module; `README.md`, under "How neovim finds and loads it",
shows the two states. The item buffer's other `<leader>d` keys are set on
the buffer itself, by `commands.attach()`, `attach_dash()` and
`attach_review()`.

## Processes

Every client call, every git command and every tmux command goes through
`spawn.run(argv, opts, on_done)` or `spawn.wait(argv, opts)`, so the argument
list, the timeout, the closed standard input, the added environment and the
exit-code check are written once. `argv` is a list and no shell is involved,
so nothing is quoted; `spawn.shell_line(argv)` is for a message that shows a
command to paste at a prompt.

Both are built on `vim.system()`, neovim's process spawn (`:help
vim.system()`), with these settings:

- `env = spawn.ENV`, merged over the editor's environment because
  `clear_env` is not set. It holds `NO_COLOR` and `CLICOLOR=0`, which keep
  escape sequences out of output that is parsed, and `GH_NO_UPDATE_NOTIFIER`
  and `GH_PROMPT_DISABLED`, which keep `gh` from printing an update notice
  into that output or stopping to ask a question. The editor's own
  environment stays, because tmux needs `$TMUX` to find the session, git
  needs `SSH_AUTH_SOCK` for the remote, and glab's keyring on Linux needs
  `DBUS_SESSION_BUS_ADDRESS`.
- `stdin` is the string a caller gives, written to the child and then closed
  — a token, a note's body — and otherwise `false`, which opens no pipe, so
  a client that stops to ask a question reads end-of-file and fails with its
  own message instead of holding the editor.
- `detach = true`, which starts the command in a session of its own and so
  makes it the leader of a process group that every process it forks joins.
- No timeout of its own. `vim.system` answers once the output pipes close,
  and its timeout signals only the process it started, so a command that
  exits while a child it forked holds the pipes — a client's update check,
  the `git fetch` that `git wt-add` streams — would hold the answer for as
  long as that child lived. `run()` and `wait()` keep the timeout themselves
  on a libuv timer, and at the timeout `kill_group()` sends SIGTERM to the
  whole group, by the negative process id, and SIGKILL to whatever is left
  once `spawn.GRACE` milliseconds have passed. SIGTERM goes first because git
  removes its lock files on it and `git worktree add` removes a half-made
  worktree, which SIGKILL would leave for the next command to trip over.
  The caller is answered at the timeout, with `timed_out` set, and whatever
  `vim.system` answers later is dropped.

The timeout is `opts.timeout`, or the `client` entry of
`config.options.timeouts`; `:help docket-setup-timeouts` names each entry's
purpose. libuv is the event library neovim runs on, reached as `vim.uv`
(`:help vim.uv`, `:help lua-loop`); `uv.new_timer()` and `uv.kill()` are what
the timeout uses.

The result every caller reads is one table: `ok`, which is true only when
the exit code was zero and no signal ended the process, since `vim.system`
reports a process a signal ended with code 0 and the signal's number; `code`;
`signal`; `stdout` and `stderr` as text; `timed_out` and the `timeout`
allowed; `argv`; and `unstarted` when no process ran because the working
directory does not exist. An executable that is not on the path never
starts either, and comes back as code `spawn.MISSING`, 127, which is how an
adapter's state check reports a client that is not installed. `spawn.message
(result)` turns a failed result into the line a mode reports, with the
client's own stderr under it, and `spawn.decode(result)` parses the JSON a
client printed, with JSON `null` decoded to `nil` rather than `vim.NIL` so a
missing field reads as absent everywhere (`:help vim.json.decode()`;
`:help vim.NIL`). `nil` is Lua's one value for absence, and indexing a table
for a key it lacks gives `nil` rather than an error (`:help lua-nil`; the
manual's section 2.2, <https://www.lua.org/manual/5.1/manual.html#2.2>).

### The main loop and fast events

`on_done` is a callback: a function handed to `run()` and called later, once,
with the result. In Lua a function keeps the local variables of the function
that made it, which is what lets `run()`'s `answer` see `answered` and
`timer` after `run()` has returned; such a function is a closure (`:help
lua-closure`; the manual's section 2.6,
<https://www.lua.org/manual/5.1/manual.html#2.6>). Every closure in this
plugin that answers a process, a dashboard section or a save is built that
way, over the variables of the call that started the work.

A `run()` callback arrives in a fast-event context: the point in the event
loop where libuv delivers an answer, and where most of `vim.api`, all of
`vim.fn`, every buffer change and every prompt raise `E5560` (`:help
lua-loop-callbacks`, `:help api-fast`). `vim.schedule(fn)` queues `fn` for
the main loop, where everything is allowed (`:help vim.schedule()`), and
`vim.in_fast_event()` says which context is running. The rule the code
follows: an adapter's callback touches only the adapter's own tables and
hands the answer on; the modules that own buffers — `list`, `buffer`,
`commands`, `review` — wrap the body of every adapter callback in
`vim.schedule`, and the check that the buffer or the dashboard is still the
one the work was started for runs inside that scheduled body, since the
editor may have moved on meanwhile. `flight.lua` reports an error it has no
caller for through a scheduled `vim.notify` for the same reason. `run()`
answers on the caller's own context instead when the executable or the
working directory is absent, which is why every caller treats a synchronous
answer as possible; and `gh.item()` schedules the octo.nvim handoff itself,
because it runs an editor command.

`wait()` is for the callers that cannot yield: the omnifunc, which neovim
calls for an answer; every git and tmux step of the launcher, each needing
the previous one's output; and the blocking state check a mode makes at
entry. It holds the editor until the process exits or the timeout kills it,
through `vim.wait()` with `fast_only` set, so only fast events run meanwhile
and no scheduled callback changes a buffer under the caller (`:help
vim.wait()`). Calling it from a fast-event context is itself `E5560`, which
is why the blocking checks run from a user command or a keymap and never
from a callback.

## One request per key

`flight.lua` is the rule for a second caller arriving while a request is
still out: it joins the request in flight instead of starting another, and
gets the same answer. `flight.new{ refusal, accept }` makes one join for one
site, and `grep -rn 'flight.new' lua/` lists the sites — the cache's row
requests, the dash's state checks, each adapter's `whoami()`, Jira's
creates, and a review's read, submit and thread resolves. The object has
methods, `requests:join(...)`, through a metatable whose `__index` is the
method table; a metatable is how Lua gives a table behaviour it does not have
itself, and `a:b(x)` is `a.b(a, x)` (`:help lua-metatable`; the manual's
section 2.8, <https://www.lua.org/manual/5.1/manual.html#2.8>).

The rule, which the module's opening comment states in full: a generation
per key, moved on by `invalidate(key)`; a join only while the request in
flight is on the key's current generation; a settle that runs once and
answers every waiter that joined that request and nobody else; `accept`
called with the answer before any waiter sees it, which is where the cache
writes its rows; a refusal, `refusal` or its result for the key, in place of
an answer that lands after its key moved on; and a `pcall` around the request
and around each waiter, so one that raises answers the rest with the error
instead of leaving them waiting for ever. `invalidate_all()` moves on every
key with a request out, and `pending(key)` says whether a join would join
one.

The ordering it guards against is reached in practice because `spawn.wait`
and every prompt pump the event loop: a section's request started before a
login answers during the login, and a request started before a write can
land after the write dropped its key. A stale answer is then refused, and
the section says so and asks again on the next refresh.

## The login before every mode

Every mode asks its adapter whether its client has an account signed in
before it asks for anything else, and a mode never prompts: it reports
`auth.LOGIN_COMMAND`, `:Docket login <backend>`, and stops. The reason is
the split between the main loop and fast events described above. A prompt
— `vim.fn.input`, `vim.fn.inputsecret`,
`vim.fn.confirm` — runs on the main loop alone, and every client answer
arrives in a fast event, so the login is a command of its own, `:Docket
login`, where the prompts are safe and the flow is one straight line.

`auth.ready(name)` is the blocking check: `adapters.get(name)`, then the
adapter's `auth_status()` with no callback, which runs the client through
`spawn.wait`, then `verdict()`, which answers the adapter or the message a
mode reports — the login command, or `the client is not installed`, since a
login cannot fix that. `auth.check(name, on_done, cwd)` is the same check
with a callback, for the dash, whose first paint waits for no host; it counts
logins per backend and refuses an answer that lands after a login for the
same backend ran, since that answer describes the account before it.

`auth.login(name, opts)` is where a breakpoint goes for anything about
signing in. It checks the state and leaves a backend already signed in alone
unless `opts.force`, which the command's bang carries as `:Docket! login`;
takes each field the adapter's `auth_fields()` names from `setup{}` or from
`vim.fn.input`; prints the adapter's `token_url()` into the message history
and offers to open it through `vim.ui.open`; reads the token with
`vim.fn.inputsecret`; runs the adapter's `auth_login(token, fields)`, which
writes the token to the client's standard input; clears the cache, since its
keys carry no account; and reports what the state check prints afterwards.
`:help :Docket-login` is the reference for what the person sees, and `:help
docket-auth` for where the token goes.

## The modes, end to end

Each mode below is traced from the command to the client call, naming the
functions where a breakpoint goes. Every one starts in `commands.run`, which
`plugin/docket.lua` binds `:Docket` to.

### The dash

`commands.dash()` finds the clone with `repo.root(vim.fn.getcwd())`, one
`git rev-parse --git-common-dir` through `spawn.wait`, and hands it to
`list.open(found)`.

`list.assemble(found)` decides the sections: `repo.remote_url` and
`repo.adapter_for` pick the review client from `origin`'s host,
`repo.binding` reads the clone's Jira binding out of git config, and
`repo.sections(binding, config.options.sections, review)` turns the
configured list into the sections shown, filling `<projects>` through
`repo.jql` or replacing a section by one line saying why it cannot run.
`list.buffer()` makes or reuses the one `docket-dash://` buffer. Each
section's state gets a cache key from `cache.key(adapter, query, scope)` and
whatever `cache.read(key)` holds, so the buffer shows cached rows the moment
it opens, with their age. Then `list.refresh(buf)`.

`refresh()` moves the state's `round` on, invalidates every state check in
flight, marks each section `checking`, paints, and for each section calls
the file-local `check()`: a `flight` join on the backend's name around
`auth.check(name, later, state.root)`, so every section of one backend joins
one check, and one that answers before returning is settled from a scheduled
callback so the other sections have joined by then. A backend signed in
leads to the file-local `fetch()`: `cache.fetch(key, request, on_done)`,
whose request is the adapter's `rows(section, deliver)` with the clone's
root as the section's `cwd`, and whose answer is painted inside
`vim.schedule` only while `current(buf, state, round)` still holds — the
buffer is the dash, holds that state, and no refresh has started since.

`list.lines(state, now)` is the pure part: the buffer's lines from a state,
with the row on each line in `at`, the highlight of each run, and each
section's header line. `list.render(buf)` sets the lines and the highlights,
as extmarks in `list.NS`, and puts each window's cursor back on the row it
was on. `commands.attach_dash(buf)` sets the keys: `<CR>` runs
`commands.open_row`, which opens a ticket or a merge request from the clone
the dash shows, as `w` builds its environment from that clone, and hands a
pull request to octo.nvim as `Octo <address>`, the row's URL, which names
the repository and its host; octo.nvim's README, at
<https://github.com/pwntester/octo.nvim>, documents that form for github.com
and Enterprise addresses, and `gh.item()`'s comment says what is unverified
against the release installed and the `:Octo` line that settles it. `w` and
`R` run `work_row` and `review_row`; `r` runs `list.refresh`.
`list.row_at(buf, lnum)` is how a key finds its row.

A section naming `glab` or `gh` as its adapter runs in every clone, and `-R
acme/payments` or `--repo acme/tools` in its query lists that project's rows
in this clone's dash, where `!482` is this project's merge request of that
number. So `open_row`, `work_row` and `review_row` each start in the
file-local `foreign()`: the project the row's address names, through the
adapter's `project_of()`, is compared through `repo.same_project()`, without
case, with the path `origin` names and then with the path of every other
remote, so a fork's clone whose `upstream` lists the row keeps it; a row of
another project is refused with what the key does in a clone of that project
and, from `repo.set_url_remedy()`, the `git remote set-url origin` line for
a clone whose `origin` spells this project another way than the address
does, since the compare cannot tell the two apart. A ticket names its
project itself and is not held to it, and `<CR>` exempts a pull request row,
since octo.nvim is handed its address. A row from a fork is a refusal of its
own, `refused_fork()`, made by `w` and `R` alone and traced under "Working
on an item" below. `:help docket-dash` is what the person sees.

### Reading and commenting on an item

`commands.item(id)` asks `commands.source_of(id)` which adapter the
identifier's shape belongs to — `M.KEY`, `M.MR` and `M.PR` are the shapes —
and calls the file-local `open_item(source, id, cwd, url)`, with no `cwd`
and no `url`, which a dash row alone supplies: `auth.ready(source, cwd)`,
then either `buffer.hand_off` for an adapter whose `handoff` names another
plugin, given `{ id, url }` when a row carried an address and the identifier
alone otherwise, which is how a pull request reaches octo.nvim, or
`buffer.open(source, id, nil, adapter, cwd)`.

`buffer.open` names the buffer `docket://<source>/<id>`, or
`docket://<source>/<project>/<id>` for a source in `buffer.BY_PROJECT`, whose
identifiers are numbered within a project: `repo.project(cwd)` reads the
path off the clone's `origin`, in the case that URL spells it, so `!482`
opened from clones of two projects is two buffers. `buffer.named(name)`
finds the buffer to reuse, and under `'fileignorecase'`, the editor's
default on macOS, it matches names without case as the editor does (`:help
'fileignorecase'`), so two clones whose origins spell one project's path in
two cases open one buffer; with the option off they are two. It then runs
the file-local `read`, which `buffer.read` also fronts for `:e`: the state
check when no adapter was handed in, made in the clone the buffer's
reference names, the adapter's `item(asked, on_done)`, and, scheduled,
`buffer.populate(buf, it)`. A read whose answer names a project other than
the buffer's name, compared through `repo.same_project()` and so without
case, is refused with nothing filled, so a merge request of another project
never lands under this one's name. `populate` runs `render.render(it)` for
the lines and the region ranges, sets the lines with undo off, marks each
region, and stores the snapshot in the buffer variable `vim.b[buf].docket`;
the section on the item buffer's regions below says what is in it. The
`FileType` autocommand in
`plugin/docket.lua` runs `commands.attach(buf)`, which sets `gx`,
`<leader>dw`, `<leader>dc`, `<leader>dt` and `<leader>da` on the buffer.

`:w` reaches `buffer.write(buf)` through the `BufWriteCmd` autocommand,
because the buffer's `'buftype'` is `acwrite`, which routes a write of a name
that is no file to that event (`:help BufWriteCmd`, `:help 'buftype'`).
`write` plans through `buffer.plan(buf)`: `buffer.current(buf)` reads what
each region holds now off its marks, and `diff.plan(snapshot, current,
frame)` decides the calls, the regions skipped as empty and the refusals,
with the whole save refused when anything is. When a call replaces a body or
a comment, the file-local `check(job)` reads the item again and
`conflicts(job, fresh)` compares each field about to be replaced with what
was loaded; then `dispatch(job)` sends the calls one at a time through
`job.adapter[call.kind]` — `body_update`, `comment_update` or
`comment_create`, the capability names `diff.lua` gives the calls —
`after_calls` drops the item's cached rows and reads the item again, and
`conclude` either populates the buffer afresh or, when a call failed or
text was typed meanwhile, moves the snapshot on with `settle_in_place`.
`:help docket-save` is the reference for every message this produces.

`<leader>dc` is `commands.comment` over `buffer.compose(buf)`, which opens a
region under the identifier `diff.NEW` at the end of the buffer for the next
`:w` to post. `<leader>dt` is `commands.transition`: the adapter's
`states()`, a picker through `vim.ui.select` (`:help vim.ui.select()`), then
`state_set()`, and on success the file-local `applied()`, which drops the
cached rows and reads the buffer again. `<leader>da` is `commands.assign`,
the same shape over `item()` and `assign()`. Each of them checks the adapter
declares the capability through `adapters.can` first and otherwise says which
call it lacks, in one line. `:Docket create` is `commands.create` and
`commands.draft`, a `docket-new://` buffer whose `:w` runs
`commands.save_draft` → `commands.parse_draft` → the adapter's
`item_create`, then `reopen` puts the new item's buffer in the draft's
place; `:help :Docket-create`.

### Working on an item

`commands.work(buf)` from an item buffer and `commands.work_row(buf)` from
the dash both end in `commands.launch(opts)`, which draws a line saying what
is being prepared, because the steps that follow hold the editor, and calls
`env.launch(opts)`. Before that, `work_row` and `review_row` each refuse, in
this order: a row of another project, through `foreign()`; in `review_row`,
a ticket, since a review is of a merge request; a merge request or pull
request row with no branch; and a row from a fork, through the file-local
`refused_fork(r, root)`. `work_row` reads the clone's binding through
`dash_clone()` between `foreign()` and the branch check, because a ticket's
launch needs it, and `review_row` reads it after `refused_fork()`.

`refused_fork()` starts from `row.fork`, which each review adapter's
`rows()` sets and `row.new` keeps only when it is `true`, so a ticket and a
merge request or pull request within its own project carry none and pass.
For a row carrying it, the project its address names, through the adapter's
`project_of()`, is compared with `origin`'s, from `repo.project(root)`,
through `repo.same_project()`. The row is refused when the two name one
project, since the clone is then of the target and the branch is in some
fork, never on `origin`; and when either side is missing — an address that
names no project, or an `origin` that names none — since nothing then says
the clone is a fork. It passes when both are known and differ: `foreign()`
has already kept such a row because another remote, `upstream`, names its
project, so `origin` is itself a fork and holds the branch of every merge
request made from it, and `env.remote_has_branch`'s question to `origin`
decides. What that leaves through is a row of another fork on a branch
`origin` also has, and the function's comment says so. The refusal is
`from_fork(r)`'s one line, naming the row and its branch; `:help
docket-work` shows it, and the launcher's own refusal, which a row not
marked meets in its place.

The mark is set where the rows are built. `glab.rows()` sets `fork` through
the file-local `forked(mr)`: true when the merge request's
`source_project_id` and `target_project_id` are both numbers and differ, nil
when either is missing, so a list lacking the fields marks nothing. Both
fields come from GitLab's REST reference and neither has been printed from
the instance, which `forked()`'s comment marks as unverified, with the `glab
mr list -F json | jq` line that prints them. `gh.rows()` sets it from
`isCrossRepository`, kept only when `gh` printed `true`; `gh.ROW_FIELDS`'
comment records the release whose `pr list --json` field list has it, and
`gh pr list --json` with no value prints the installed release's. What is
unverified on GitHub is which repository `gh pr list` lists in a clone `gh
repo fork --clone` made, which decides whether a fork's clone's rows pass
`foreign()` at all; `repo.remotes`' comment names `gh repo set-default
--view` as what shows it. `:help docket-backends` lists both under what has
not been run against a real instance. The dash paints cached rows first, so
the mark has to come back off disk, and the cache section below says what
keeps a file written before the field existed from being read as current.

The launcher section below traces `env.launch`. `commands.describe` turns
what it returns into the report, warning included. `:help docket-work` is
the reference.

### Reviewing a merge request

`commands.review(args, bang)` dispatches `:Docket review <id>` to
`commands.review_open(id)` and `:Docket review <verb>` to
`commands.review_verb(verb, words, force)`. `review_open` checks the adapter
declares every capability in `review.NEEDS` before anything reaches a client,
and calls `review.open(source, id)`, which is traced in the review mode
section below; on success it makes the autocommands that key each buffer of
the review's tab through `commands.key_review_tab` and take the keys off
again through `commands.unkey_reviews`. `review_verb` calls `review.comment`,
`review.reply`, `review.resolve`, `review.submit(verdict)` or
`review.abandon`. `R` on the dash is `commands.review_row`, the launcher
with `nvim -c 'Docket review <id>'` as the editor command. `:help
docket-review` is the reference.

## The adapter contract

An adapter is a module under `lua/docket/adapters/` returning a table of
calls, named in `row.SOURCES` and loaded by `adapters.get(name)`. The
contract is written once, above `M.REQUIRED` in `adapters/init.lua`, with
each call's signature and what its callback is given, and it is not
restated here; the outline:

- The required calls, `adapters.REQUIRED`: the state check, the login and
  the fields it needs, the token page, `rows()` for a section, `item()` for
  one item, `whoami()` for the account's own identifier, a row's `branch()`
  and `url()`, and `project_of()`, the project path an address names, or
  nil where the adapter cannot say — a Jira key names its project itself —
  which the dash holds a row against its clone's remotes with, and tells a
  fork's clone from the target's by.
- The optional calls, `adapters.OPTIONAL`, each declared in the adapter's
  `capabilities` list and implemented only when declared: the writes a save
  makes, `complete()` for the omnifunc, `states()` and `state_set()`,
  `assign()`, `item_create()`, and the review's `diff()`, `threads()`,
  `line_comment()`, `thread_resolve()` and `submit()`. A caller binds only
  what an adapter declares, through `adapters.can(adapter, capability)`,
  which is what keeps the asymmetry between backends out of the buffer: Jira
  has no diff, GitHub implements the row calls alone and names a `handoff`.
- `adapters.ARITY`, how many parameters each call takes. `verify()` reads a
  function's declared count with `debug.getinfo(fn, "u").nparams` (`:help
  debug.getinfo()`; the manual at
  <https://www.lua.org/manual/5.1/manual.html#pdf-debug.getinfo>), because a
  function is a function whatever its arity, and without the check a
  `rows()` written without its callback passes and fails as a nil callback
  at the first fetch. A vararg function is not held to a count.
- `adapters.ME` and `adapters.NOBODY`, the two values `assign()` takes
  besides a person's identifier, spelled so that no identifier either backend
  issues can be one.

`verify(adapter, name)` runs once, when the registry first loads a module,
and names every shortfall in one message: a required call missing, a
capability declared and not implemented, an optional call implemented and
not declared, a wrong arity, a `handoff` that is not a plugin's name. A
module that fails is not kept, so the next call reports the same failure.
The blocking form of `auth_status` exists because the login runs on the main
loop and a prompt has to follow the check there; every other call that
crosses the network takes a callback and answers in a fast event.

`id` in a call is an identifier string, or a reference `{ id, cwd }` naming
the directory the call runs in. glab finds the project an `!482` belongs to
from its working directory, so the same number names another merge request
in another clone: `glab.item()` answers the item with a `ref` naming the
clone it read in, `buffer.target(state)` hands that reference to every later
call about the item, and the review mode passes one naming its worktree.
An adapter that answers no `ref` never meets one. An adapter with a `handoff`
meets one more shape in `item()`: `{ id, url }`, the identifier and the
address a dash row carries, which it names to the plugin; `:Docket #12`
typed by hand gives the identifier alone.

## The cache

The dash shows cached rows the moment it opens and refreshes behind them,
and the age travels with the rows, so a stale view is never shown as live.
The rows live under `config.options.cache_dir`, `$XDG_CACHE_HOME/docket`
with `~/.cache` standing in when the variable is unset or empty
(`config.cache_dir()`; `:help docket-setup-cache_dir`). That is outside
neovim's own cache directory because what is cached is a query's answer,
keyed to an account and a set of repositories rather than to an editor, so a
second front end asking the same question can share it; and outside the
source tree because nothing a program writes is tracked, as "Adding to this
repository" in the repository's `README.md` states.

`cache.key(source, query, scope)` is the adapter's name, the query, and for
a review client the clone's root, since `glab` and `gh` resolve the project
from their working directory and `mr list --reviewer=@me` names a different
project in every clone; a JQL query names its own projects and its rows are
the same in every clone. No account is in the key, because building one
would cost a client call on the path that assembles the dash; a login clears
every key instead. `cache.name(key)` hashes the key into a file name, since a
query carries spaces and quotes and can be longer than a file name may be;
the key is written inside the file and checked on read, so a collision reads
as a miss. `cache.write` writes `{ format, key, written, rows }` as JSON to
a temporary file, mode `0600` in a `0700` directory, and renames it into
place, so another process never reads a half-written file. `format` is the
file-local `FORMAT`, the number of the row shape the module writes, and
`cache.read` treats a file whose `format` is another number, or absent, as
a miss, so a row cached under an older shape is fetched again rather than
shown without a field the current shape carries and a key reads: `w` and `R`
read a merge request's `fork`, and a row shown without it reaches the
launcher. `FORMAT` moves on when a row gains such a field, and the test
`cache: an absent directory, one that cannot be written, a file that is not
JSON, and one of another format are each a miss` in `tests/docket.lua`
spells the number out rather than reading it off the module, so a bump
changes that test too. `cache.read` holds every row to `row.new` and treats
a file with one bad row as a miss, because a row the dash cannot render
would break the paint until the file was removed by hand; it keeps the
file's entry rather than what `row.new` built, so what an adapter adds
beyond the fields `row.new` returns — such as the `url` on a merge request's
or a pull request's row — survives the round trip.

Nothing in the module raises: an absent directory, a file that is not JSON
or is of another format, a read that fails part way are each a miss, because
the cache stands in front of the client and a broken cache must not stop the
dash from asking. Every function is safe in a fast-event context, which is
where a spawn callback lands, so the hash is Lua and the directory is made
through `vim.uv` rather than `vim.fn`.

What invalidates it: `cache.drop(key)` removes one key's file and refuses the
answer of a request in flight for it; `cache.drop_item(source, id)` runs
after a save, a transition or an assignment, reads every row file and drops
the keys whose rows hold the item, and moves every request in flight on,
since a search that started before the write can answer with the item as it
was; `cache.clear()` runs after a login and drops every key. `cache.fetch`
is the `flight` join over the request, and `cache.pending` asks it.

## The item buffer's regions

The buffer is a rendered document whose structure is invisible: nothing in
the text says where the description ends and a comment begins, and the
extmarks carry it. An extmark is a position, or a range between two
positions, that neovim keeps attached to the text as lines are inserted,
deleted and moved (`:help extmarks`, `:help nvim_buf_set_extmark()`). The
rules for how the marks are set and read, which is the part that gets built
wrong, are in `buffer.lua`'s opening comment under "The region rules"; what a
save does with what the marks say is `diff.lua`'s opening comment. Neither
is restated here. What a reader needs to open `buffer.lua`:

- Each region is one ranged extmark in `buffer.REGIONS`, from column 0 of
  its first line to column 0 of the line after its last, with the gravities
  that take a line opened above or below into the region. Each also has an
  edge, a point mark in `buffer.EDGES` where the range ended at the read, and
  a head, a point mark in `buffer.HEADS` at the end of the nearest text line
  above it; edge and head together tell text typed at a region's boundary
  apart from the region's own. Highlights are extmarks in `buffer.DECOR`,
  one per line, so the region mark stays a single range.
- The API takes 0-based rows and columns, and a range's end is exclusive,
  while `render.render` returns 1-based, inclusive `first_line` and
  `last_line`, as Lua's own strings and tables are 1-based; `render.render`'s
  comment gives the conversion, and `:help api-indexing` is the rule.
- `populate()` stores the snapshot in the buffer variable `vim.b[buf].docket`
  (`:help vim.b`, `:help lua-vim-variables`): the item's `source`, `id`,
  `title`, `url`, `me`, `ref` and `project`; `load`, the read's number, so a
  write can tell the buffer was read again under it; `snapshot`, with
  `regions` and `frame` in the shape `diff.plan()` takes; `marks`, mapping
  each mark's id, as a string because a buffer variable turns integer keys
  into a list, to the region's identifier, kind, owner, edge and head; and
  `stamps`, each comment's `updated` as loaded, for the write's conflict
  check.
- `buffer.current(buf)` reads the marks back into `current`, one entry per
  region — its lines, or `overlaps`, or `reversed` — and `frame`, the text
  outside every region with its line numbers. `diff.plan(snapshot, current,
  frame)` is pure, so the part that decides what is sent is tested without a
  buffer; its one rule is that a changed region whose `editable` is false is
  refused with its `reason`, and the read path is the only place that can
  judge editability, because it holds the tree and the `whoami()` answer.
- `compose()` appends a region under the identifier `diff.NEW`; the read
  that follows a post is what names the comment it became, because the
  clients answer a post with no identifier.

## Jira's document tree: read wide, write narrow

Jira returns a body as a document tree, Atlassian Document Format, and the
buffer shows text, so `adf.lua` is where the two meet. `adf.render(node)`
turns any tree into lines: a mark on text, a list, a heading or a code block
in the shape Markdown gives it, a mention as its display name, and a node
the module does not know as `[unsupported: <type>]` with whatever it holds
rendered beneath, so no text is lost from the buffer. `adf.serialise(text)`
goes the other way and builds only what plain text can carry: `doc`,
`paragraph`, `hardBreak` and `text` with no marks, the set `adf.SUBSET`
names. Over that subset the two are inverses, which the suite asserts, and
`adf.editable(node)` is true exactly when a tree lies within it — otherwise
a write would replace a link, a list or a mention by its flattened text.
`render.render` combines that judgement with `item.regions`' ownership
judgement into each region's `editable` and `reason`, and the write path
judges a body again from the read that precedes a save, because formatting
added on the web to words already there leaves the text the same.

A GitLab body is Markdown as a string, so none of this applies there:
`render.region_lines` splits it at its newlines, `render.crlf` records a body
whose line ends are all CRLF so a save puts them back, and every region the
account wrote is editable. `jira.lua` sends each write as a file holding the
serialised tree — `write_document()` over `--body-file`, `--body-adf` or
`--description-file` — created with `uv.fs_mkstemp()` so it is `0600` from
the start, since it holds a comment's body; `glab.lua` writes the text to the
client's standard input. `:help docket-item` says what the person sees of
this.

## The launcher

`env.launch(opts)` builds the development environment for a ticket, given
`key` and `summary`, or for a review, given `branch` and `review`. It runs
on the main loop, each step through `spawn.wait`, because each needs the
previous one's output.

The branch for a ticket is `env.branch_for(key, summary)`: the key, a
hyphen, the summary lowercased with every run outside `[a-z0-9]` collapsed
to one hyphen, capped at `env.BRANCH_MAX` without cutting into the key. The
key is read back off any branch by `env.key_of(branch)` with
`env.KEY_PATTERN`. That is a Lua pattern, not a regular expression: the
classes are single letters after `%`, `%u` for an uppercase letter and `%d`
for a digit, and there is no alternation (`:help lua-pattern`; the manual's
section 5.4.1, <https://www.lua.org/manual/5.1/manual.html#5.4.1>). The
pattern ends in `%f[^%w]`, a frontier: it matches at a position where the
character before is in the set's complement and the one at it is in the set,
here the transition from a word character to a non-word one or the end, so
`PROJ-142abc` yields no key while `PROJ-142-fix` yields `PROJ-142`. The
frontier is in Lua 5.1 and LuaJIT but absent from the 5.1 manual, and
`:help lua-pattern` follows the manual; the test `the key ends at a word
boundary` in `tests/docket.lua` is what pins it. `jira.KEY` is the same
shape read the other way, and the suite asserts the two accept the same
identifiers.

`env.window_name(branch)` collapses every run outside `[A-Za-z0-9_-]` to
one hyphen, because tmux reads `:` and `.` in a target as separators; it
truncates nothing, since two long branches sharing a prefix would collide.

The sequence: `repo.worktrees(root)` lists the clone's worktrees; a ticket
in an unbound clone, or from a project the clone is not bound to, is
refused with the binding command; `repo.worktree_for_key` reuses a worktree
whose branch starts with the key, `repo.worktree_for_branch` one on the
exact branch; a review branch that is not on `origin`, which
`env.remote_has_branch` asks with `git ls-remote`, is refused, because `git
wt-add` would create a new branch of that name; `env.add_worktree` runs `git
wt-add`; then `env.open_windows`. Inside tmux, which `env.in_tmux` decides
from `$TMUX` and not from a running server, `env.tmux_windows` makes the two
windows with `new-window -S -n <name>`, which finds or creates, addresses
each as `=<name>`, an exact match, and sets `allow-rename off`; the focus
move is what decides success, as the function's comment explains. Away from
tmux, `open_windows` opens a tab of the running editor and runs `:tcd` into
the worktree, since it is tab-local (`:help :tcd`), and returns
`env.tmux_script` for the report to print, so a shell inside tmux can reach
the same place.

`env.teardown(opts)` closes both windows and then removes the worktree
through `git wt-rm`, in that order because a window left in a removed
worktree sits in a folder that no longer exists. No command in the plugin
calls it; the suite exercises it, and "Removing an environment" in `:help
docket-work` gives the by-hand procedure.

## The review mode

A review is one batch: comments are held in the editor and nothing reaches
the merge request until the review is submitted, which is what octo.nvim does
for GitHub. `review.lua`'s opening comment lists the fields of a review and
is the place to read first.

`review.open(source, id)` checks for diffview.nvim by `:DiffviewOpen`
existing, makes the state check, checks the adapter's capabilities against
`review.NEEDS`, finds the worktree's top level and HEAD with git, and
registers the review under the worktree and the identifier through
`review.start`. `review.load` reads the merge request through a `flight`
join: the adapter's `diff()` for the branches and the shas, then `threads()`
for the discussions, kept on the review by the join's `accept`. On the main
loop, the file-local `show()` refuses a worktree on another branch, finds the
merge base, warns about uncommitted changes or a worktree behind the merge
request's head, opens `:DiffviewOpen origin/<target>...HEAD --imply-local`
and records the tab, then `review.decorate`.

`review.locate(review, buf)` says which side of which file a buffer shows,
asking diffview's own view first, through `require("diffview.lib")` under
`pcall` since it is diffview's internals, and falling back to a file of the
worktree being the new side. `review.marks(threads, held, loc)` is pure: the
discussions and the held comments to draw on one side of one file, each as
virtual lines under its line; `decorate` sets them as extmarks with
`virt_lines` in the review's namespace. `review.thread_line` places a
discussion from its GitLab `position`, and `review.elsewhere` leaves one
placed on another version of the diff at no line.

The verbs: `review.comment` finds the review, the side and the line with the
file-local `here()`, refuses a line the merge request's diff does not show
through `in_diff`, since glab refuses a comment there, and a file that
differs from HEAD through `unchanged`, then opens `review.compose`, a
floating window over an `acwrite` buffer named `docket-review://<worktree>/
<place>` whose `BufWriteCmd` runs the file-local `written()`: `review.hold`
for a comment, or `review.send` for a summary. `review.hold(review,
position, text)` replaces the comment held at that place, drops it on empty
text, and refuses a place the worktree does not match through `review.check`.
`review.submit(verdict)` runs `review.send(review, adapter, verdict,
on_done)`: a `flight` join per review that refuses a second submit, a read of
the merge request to find held comments the head has moved under
(`review.stale`), each held comment through the adapter's `line_comment()`
in order with the first failure stopping the batch, then `submit()` for the
summary and again for the approval, so an approval refused after the summary
went out is known as that. `review.resolve` runs `review.resolve_thread`;
`review.abandon` runs `review.discard`, which drops the held comments and
refuses while a submit is in flight. `:help docket-review` covers what each
verb shows.

## Completion

An item buffer's `'omnifunc'` is `complete.omnifunc`, set by
`buffer.prepare` when `require("docket.complete")` succeeds, together with
the buffer-local setting that makes mini.completion's fallback call it.
neovim calls an omnifunc twice: first with `findstart` set, for the column
the completion starts at, then with `base`, the text it replaces, for the
candidates (`:help complete-functions`, `:help 'omnifunc'`). `complete.trigger
(before)` reads the text before the cursor for `@name`, `!digits` or a Jira
key, and answers `complete.NONE`, which is -3, when there is none, so an
empty menu never opens on ordinary typing; the adapter is asked on the first
call, since that is the only way to know there is nothing to offer in time to
cancel, and the second call hands back what the first found. `complete.items
(source, kind, query, replaced)` asks the adapter's `complete(kind, query)`,
which blocks under the `complete` timeout, and keeps each answer for
`complete.TTL` seconds because mini.completion asks after every pause in
typing. `:help docket-completion` says what each backend offers and why Jira
offers no people.

## Highlights

`highlight.lua` names the `Docket*` groups and, for each, the `Octo*` group
it follows when octo.nvim has been set up and a built-in group otherwise;
`highlight.define()` links them with `nvim_set_hl` and runs from `setup()`
and again from a `ColorScheme` autocommand, since a colour scheme change
clears the groups. `highlight.state_group(state, category)` picks a state's
group: a Jira status by its `statusCategory.key`, which each Jira row and
item carries as `category`, because a status name is the workflow's own
word; a GitLab or GitHub state by its fixed word. `:help docket-highlights`
lists the groups and the mapping.

## Help tags

`:help docket` needs a `tags` file beside `doc/docket.txt`, and `init.lua`
writes it from `setup()` — `docket.helptags()`, over `:helptags` (`:help
:helptags`) — whenever the tags are older than the help file, reporting once
when it cannot. It is done there rather than in a bootstrap script because a
script would have to run neovim on a fresh machine, and on the profile
without `sudo` neovim is a mise tool the bootstrap's scripts have no shims
for. `docket.help_files()` is the one lookup of the help file and its tags,
through
`nvim_get_runtime_file`, which searches `pack/*/start/*` as well as
`'runtimepath'` (`:help runtime-search-path`), and `health.lua` reads it for
`:checkhealth docket`. The tags file is never tracked, and `tests/check.py`
fails on one anywhere in the source; `README.md`, under "Trying a change from
the source tree", gives the scratch-copy route to reading edited help.

## The suite

`tests/docket.lua` runs under `nvim -u NONE -l`, neovim's script mode (`:help
-l`), because the modules call into `vim.*`; the buffers, windows and tabs a
test opens belong to that instance and end with it. It sets `package.path`
from its own location to the package's `lua/` directory, so it runs from any
directory, and it requires every module and the adapters up front.

Each test is `test(name, body)`, appended to a list the runner at the end of
the file walks, calling each body under `pcall` and printing `ok` or `FAIL`
with the message. `eq(actual, expected, label)` compares by
`vim.deep_equal`. The file is in sections, each opened by a comment line the
runner does not read; this prints them:

```sh
grep -n -- '^-- .*-----$' "$(chezmoi source-path)/tests/docket.lua"
```

No process runs. At load the suite replaces `spawn.run` and `spawn.wait`
with a function that raises `a test reached spawn without a stub`, and the
runner puts that guard back after every test, so a test that reaches a
client without stubbing fails instead of running it as the account signed in
on the machine. A test that needs a client answer replaces one of them for
its own duration: `stub_run(answer)` records each call as `{ argv, opts }`
and answers it from `answer(argv, opts)` before `run` returns;
`stub_run_fast(answer)` answers from a libuv timer instead, which is the
fast-event context a real answer lands in, so a caller that touches the
editor there without scheduling fails as it would in the editor; `stub_wait`
is the blocking form. `done(argv, payload)` and `failed(argv, code, stderr)`
build results in the shape `spawn` returns. Above the adapters,
`stub_calls(adapter, answers)` replaces the adapter's own calls with
recorders answered from a timer, or held for the test to release, so the
write path and the review are tested against the contract rather than
against a client's output. The exceptions are the tests of `spawn` itself,
which run `sh`, and one that runs a `!` filter through `sh`.

The rest of the editor is stood in for the same way: diffview.nvim is two
user commands the review tests declare, `DiffviewOpen` opening a tab on a
worktree file and `DiffviewClose` closing it, with its view a table put in
`package.loaded["diffview.lib"]`; a picker is `vim.ui.select` replaced for
the test; `vim.notify` is replaced to collect messages; and the cache
directory is a directory of the run's own, set through `XDG_CACHE_HOME`, so
a test that logs in clears nothing of the machine's. The calls that have to
stay in one clone are exercised from two clones of one project, with a state
check in the other clone between the entry and each answer. `README.md`,
under "Running the gate and the suite", gives the command and what it
prints.

## Adding to docket

Each procedure below names the places the code reads, walked against it.

### An adapter

1. Add the name to `row.SOURCES` in `row.lua`. Its position is the order the
   dash shows the backend's sections in and sorts its rows by. `row.new`
   refuses a row whose `source` is not in the list, `adapters.get` refuses a
   name that is not, `health.lua` checks each name, and `commands.complete`
   offers each after `login`.
2. Write `lua/docket/adapters/<name>.lua`: a table with every call in
   `adapters.REQUIRED` at the arity `adapters.ARITY` gives it, a
   `capabilities` list naming each call in `adapters.OPTIONAL` the module
   implements, and `handoff` when items open in another plugin. The first
   `adapters.get(name)` runs `verify()` and names every shortfall in one
   message, and this asks for it before any test exists, printing `ok` or
   the shortfall:

   ```sh
   nvim -u NONE --headless \
     --cmd "set rtp^=$(chezmoi source-path)/dot_local/share/private_nvim/private_site/pack/docket/start/docket" \
     -c 'lua print(select(2, require("docket.adapters").get("<name>")) or "ok")' -c q
   ```

   Every callback answers in a fast event; every call that can be
   given a reference reads it with a helper like `glab.lua`'s `subject()`.
   `M.forget()` is the shape the other adapters use for dropping what was
   learnt under the account signing out. A `rows()` that lists code reviews
   sets `fork` on a row whose branch lives in another project, as
   `glab.lua`'s `forked()` and `gh.rows()` do, because `w` and `R` refuse
   such a row on that field alone; a row without it reaches the launcher.
3. Teach `commands.source_of` the identifier's shape, so `:Docket <id>` finds
   the adapter; the shapes are the constants above it.
4. When a remote's host selects the client, add it to `repo.adapter_for` and
   to the `review` sections' queries in `config.defaults.sections`, keyed by
   the adapter's name; `commands.backends` then includes it in `:Docket
   login` with no argument. When its identifiers are numbered within a
   project, add it to `buffer.BY_PROJECT`; when it has state words of its
   own, to `highlight.STATES`.
5. The places that name a backend outside its adapter are listed by
   `grep -n '"jira"' lua/docket/commands.lua lua/docket/list.lua
   lua/docket/repo.lua`: the launcher takes a ticket from Jira alone, a new
   ticket is Jira's, and a Jira query's rows are the same in every clone.
   Each is a decision to revisit for the new backend.
6. Add a section to `doc/docket.txt` under `docket-backends`, and a section
   to `tests/docket.lua` with `stub_run` answering the client's payloads;
   the tests under `the adapter contract` show how a module is held to
   `verify()`.

### A command

1. `commands.run(command)` dispatches on `command.fargs[1]`, with
   `command.bang` available; add the branch there, and the word to the
   candidates in `commands.complete`, which also has a branch per word for
   what follows it.
2. The `desc` string of `nvim_create_user_command` in `plugin/docket.lua`
   names the forms; add the new one. Nothing else in that file changes, and
   its bodies keep requiring a module only when they run.
3. The body follows the pattern above: `auth.ready` before the first client
   call, an optional capability only through `adapters.can`, and every
   buffer change inside `vim.schedule` when it follows a client's answer. A
   key belongs to one kind of buffer and is set in `commands.attach`,
   `attach_dash` — whose footer is `list.KEYS` — or `commands.REVIEW_KEYS`,
   never in `plugin/docket.lua`, which holds `<leader>dd` alone.
4. Document it under `docket-commands` in `doc/docket.txt`, and test it in
   the `the commands` section of `tests/docket.lua`; the test `commands: gx
   opens the adapter's url, and completion offers the subcommands then the
   backends` is where the command line's completion is asserted.

### A dash section

1. Add an entry to `config.defaults.sections`, or for one machine to
   `sections` in `setup{}`, which replaces the default list whole: `{ title,
   adapter, query }`. For `adapter = "jira"`, `query` is JQL carrying
   `<projects>` joined to the rest by `AND`, and holding `currentUser()` if
   it is to run in an unbound clone — `repo.jql` drops the placeholder only
   when `AND` joins it and refuses a query that would search every project;
   for `adapter = "review"`, `query` is a table keyed `glab` and `gh`, each
   the arguments of that client's list command; for `"glab"` or `"gh"`, the
   one list. The client adds the page size and the output format itself.
2. Give the section a title no other has: `jira.lua` keeps each section's
   rows for completion under its title, and the dash's state identifies a
   section by its definition.
3. `repo.sections` turns the configured list into what is shown under each
   binding, and `list.open` builds the cache key, with the clone's root for a
   review client; neither needs a change for a new entry.
4. Update the default listing under `docket-setup-sections` in
   `doc/docket.txt`, and the tests under `query assembly` and `the dashboard`
   in `tests/docket.lua`, where the section counts and titles are asserted.
