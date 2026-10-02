-- Unit tests for the docket modules: query assembly, the branch and
-- window-name rules, the launcher and its teardown, the remote-to-adapter
-- choice, the repository's binding, the worktree listing parser, row
-- ordering, spawn's failure paths, the document tree's render and serialise,
-- the item and its regions, the buffer rendering, the highlight groups, the
-- region compare, the adapter contract, the in-flight join, the cache, the
-- Jira, GitLab and GitHub adapters, the login flow, the item buffer's marks
-- and its write path, completion, the dashboard, the commands -- a
-- transition, an assignment and a new ticket's draft among them -- the review
-- mode, the help tags, the health report, the plugin file, and last, that the
-- suite read every module from the source tree.
--
-- No git runs, no client is called, no tmux window opens: every process call
-- goes through spawn, and the tests that reach one replace spawn.run or
-- spawn.wait with a function that records the argument list and answers from
-- a recorded payload. Between tests both raise, so a test that reaches a
-- client without replacing them fails rather than running it. The tests of
-- the write path and of the item buffer's keys replace the adapter's own
-- calls instead, with stub_calls. The spawn tests are the exception: they run
-- `sh`, and name a client no machine has. So is the test of a `!` filter over
-- an item buffer's lines, which the editor runs through `sh` with `sort` and
-- `sed`, both POSIX. The
-- editor actions exercised are the tabs the launcher opens away from tmux, the
-- item and dashboard buffers, a new ticket's draft, the scratch buffers the
-- item buffer's marks are tested in, and a review's tab, file and compose
-- floats, all of which nvim -l can create. diffview.nvim is two user commands
-- declared by the review tests, and its view a table put in package.loaded.
-- A picker is vim.ui.select replaced for the test.
--
-- Runs under nvim, the interpreter that loads these modules:
--
--   nvim -u NONE -l tests/docket.lua
--
-- The module path is set from this file's own location to the package's
-- `lua/` directory, so it runs by hand from any directory as well as from
-- tests/check.py. What it tests is the source tree whatever copy of docket
-- the machine has installed; isolate() below says how.

local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.uv.fs_realpath(vim.fs.dirname(here) .. "/..")
local lua = root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/lua"

-- Whether a runtime directory holds a copy of docket: its modules, its plugin
-- file or its help file.
local function holds_docket(dir)
  for _, path in ipairs({ "lua/docket", "lua/docket.lua", "plugin/docket.lua", "doc/docket.txt" }) do
    if vim.uv.fs_stat(dir .. "/" .. path) then
      return true
    end
  end
  return false
end

-- Takes every installed copy of docket out of the editor's sight. neovim's
-- own module loader runs ahead of package.path and searches each
-- 'runtimepath' entry and every `pack/*/start/*` folder under each 'packpath'
-- entry, and `-u NONE` leaves both at their defaults, which name
-- ~/.local/share/nvim/site. On a machine this repository has configured
-- docket is deployed there, so without this a require() reads the deployed
-- copy, and its help file is on the runtime path, where the help and health
-- tests assert there is none. Every 'runtimepath' entry that holds a copy is
-- dropped, and 'packpath' is emptied, since the suite needs no package from
-- the machine and a copy can sit in any package under any folder name. The
-- source tree is on neither, so the help file is found nowhere, and its
-- modules come from package.path.
local function isolate()
  vim.opt.runtimepath = vim.tbl_filter(function(dir)
    return not holds_docket(dir)
  end, vim.opt.runtimepath:get())
  vim.o.packpath = ""
end
isolate()
package.path = lua .. "/?.lua;" .. lua .. "/?/init.lua;" .. package.path

-- Where each docket module was read from, by module name, which the last test
-- checks is the source tree. The recorder sits after package.preload, the
-- first searcher, because the tests stand a module in through preload, and
-- before neovim's loader; it asks the searchers after it in their order, so
-- the module found is the one require() would have found without it.
local origins = {}
table.insert(package.loaders, 2, function(name)
  if name ~= "docket" and not vim.startswith(name, "docket.") then
    return nil
  end
  for index = 3, #package.loaders do
    local loader = package.loaders[index](name)
    if type(loader) == "function" then
      origins[name] = debug.getinfo(loader, "S").source:gsub("^@", "")
      return loader
    end
  end
  return nil
end)

local adapters = require("docket.adapters")
local adf = require("docket.adf")
local auth = require("docket.auth")
local buffer = require("docket.buffer")
local cache = require("docket.cache")
local commands = require("docket.commands")
local config = require("docket.config")
local docket = require("docket")
local diff = require("docket.diff")
local env = require("docket.env")
local flight = require("docket.flight")
local gh = require("docket.adapters.gh")
local glab = require("docket.adapters.glab")
local health = require("docket.health")
local highlight = require("docket.highlight")
local item = require("docket.item")
local jira = require("docket.adapters.jira")
local list = require("docket.list")
local render = require("docket.render")
local repo = require("docket.repo")
local review = require("docket.review")
local row = require("docket.row")
local spawn = require("docket.spawn")

-- The guard the header describes: without it, a test that reaches a client
-- unstubbed runs the real one as the account signed in on this machine. It
-- raises with the argument list. The spawn tests call the real functions
-- through these two names.
local real_run, real_wait = spawn.run, spawn.wait
local function unstubbed(argv)
  error("a test reached spawn without a stub: " .. table.concat(argv, " "), 2)
end
spawn.run, spawn.wait = unstubbed, unstubbed

-- Every cache read and write in this run lands under a directory of the run's
-- own. A test that logs in reaches cache.clear(), which unlinks the row files
-- where the cache directory points; pointing it here keeps the account's own
-- rows out of it. nvim removes the directory tempname() names when it exits.
-- The runner points it here again after every test.
local CACHE_HOME = vim.fn.tempname()
vim.env.XDG_CACHE_HOME = CACHE_HOME
config.options.cache_dir = config.cache_dir()

local function eq(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(("%s:\n  expected %s\n  got      %s"):format(label or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local tests = {}
local function test(name, body)
  tests[#tests + 1] = { name = name, body = body }
end

local OPEN = " AND statusCategory != Done ORDER BY updated DESC"

-- query assembly ---------------------------------------------------------------

test("query: one project fills the placeholder", function()
  local binding = { kind = "projects", projects = { "PROJ" } }
  eq(repo.jql("<projects>" .. OPEN, binding), "project IN (PROJ)" .. OPEN)
end)

test("query: several projects are one IN clause", function()
  local binding = { kind = "projects", projects = { "PAY", "OPS" } }
  eq(
    repo.jql("<projects> AND assignee = currentUser()" .. OPEN, binding),
    "project IN (PAY, OPS) AND assignee = currentUser()" .. OPEN
  )
end)

test("query: unbound drops the project clause", function()
  local binding = { kind = "unbound" }
  eq(repo.jql("<projects> AND assignee = currentUser()" .. OPEN, binding), "assignee = currentUser()" .. OPEN)
  eq(repo.jql("assignee = currentUser() AND <projects>", binding), "assignee = currentUser()")
  eq(repo.jql("<projects> and reporter = currentUser()", binding), "reporter = currentUser()", "JQL keywords are case-insensitive")
  eq(
    repo.jql("assignee = currentUser() AND <projects> AND resolution = Unresolved", binding),
    "assignee = currentUser() AND resolution = Unresolved",
    "a placeholder inside an AND chain is dropped with its AND"
  )
  local query, err = repo.jql("<projects> OR assignee = currentUser()", binding)
  eq(query, nil, "a placeholder not joined by AND cannot be dropped")
  eq(err:find("cannot be dropped", 1, true) ~= nil, true, err)
  local shown = repo.sections(binding, { { title = "T", adapter = "jira", query = "(<projects>) AND b" } }, { adapter = "gh" })
  eq(shown[1].query, nil)
  eq(shown[1].reason:find("cannot be dropped", 1, true) ~= nil, true, "the section carries the reason")
end)

test("query: unbound refuses a template not scoped to the account", function()
  local query, err = repo.jql("<projects> AND statusCategory != Done ORDER BY updated DESC", { kind = "unbound" })
  eq(query, nil)
  eq(err:find("currentUser()", 1, true) ~= nil, true, "the reason names the clause that would have allowed it")
end)

test("sections: unbound with no account-scoped section shows one section with no query and the reason", function()
  local configured = { { title = "All open tickets", adapter = "jira", query = "<projects> AND statusCategory != Done" } }
  local shown = repo.sections({ kind = "unbound" }, configured, { adapter = "glab" })
  eq(shown[1].adapter, "jira")
  eq(shown[1].query, nil)
  eq(shown[1].unbound, true)
  eq(shown[1].reason:find("currentUser()", 1, true) ~= nil, true)
end)

test("query: a complete jql is used as given", function()
  local binding = { kind = "jql", jql = "filter = 12345" }
  eq(repo.jql("<projects>" .. OPEN, binding), "filter = 12345")
end)

test("query: an epic narrows the project clause to its children, in every Jira section", function()
  local binding = { kind = "projects", projects = { "PAY" }, epic = "PAY-10" }
  eq(repo.clause(binding), "project IN (PAY) AND parent = PAY-10")
  eq(repo.jql("<projects>" .. OPEN, binding), "project IN (PAY) AND parent = PAY-10" .. OPEN)
  local shown = repo.sections(binding, config.defaults.sections, { adapter = "glab" })
  local jira = vim.tbl_filter(function(section)
    return section.adapter == "jira"
  end, shown)
  eq(#jira > 1, true, "every Jira section is shown")
  for _, section in ipairs(jira) do
    eq(section.query:find("^project IN %(PAY%) AND parent = PAY%-10 ") ~= nil, true, section.query)
    eq(section.reason, nil, section.title)
  end
end)

test("query: an epic beside a complete jql narrows nothing, and the section says so", function()
  local binding = { kind = "jql", jql = "filter = 1", epic = "PAY-10" }
  eq(repo.jql("<projects>" .. OPEN, binding), "filter = 1", "the query runs as written")
  local shown = repo.sections(binding, config.defaults.sections, { adapter = "glab" })
  eq(shown[1].query, "filter = 1")
  eq(
    shown[1].reason,
    "dotfiles.jira.epic is PAY-10, and dotfiles.jira.jql runs as written, so the epic narrows nothing; put parent = PAY-10 into the query"
  )
  local plain = repo.sections({ kind = "jql", jql = "filter = 1" }, config.defaults.sections, { adapter = "glab" })
  eq(plain[1].reason, nil, "with no epic there is nothing to say")
end)

test("sections: the defaults carry a title, an adapter and a query each", function()
  for _, section in ipairs(config.defaults.sections) do
    eq(type(section.title), "string", "title")
    eq(section.adapter == "jira" or section.adapter == "review", true, section.title .. " adapter")
    if section.adapter == "jira" then
      eq(section.query:find(config.PLACEHOLDER, 1, true), 1, section.title .. " placeholder")
    else
      eq(type(section.query.glab), "table", section.title .. " glab query")
      eq(type(section.query.gh), "table", section.title .. " gh query")
    end
  end
end)

test("sections: unbound shows one labelled Jira section with the binding command", function()
  local shown = repo.sections({ kind = "unbound" }, config.defaults.sections, { adapter = "glab" })
  local jira = vim.tbl_filter(function(section)
    return section.adapter == "jira"
  end, shown)
  eq(#jira, 1, "one jira section")
  eq(jira[1].title, "Assigned to me (unbound)")
  eq(jira[1].query, "assignee = currentUser()" .. OPEN)
  eq(jira[1].unbound, true)
  eq(jira[1].reason:find(repo.BIND_COMMAND, 1, true) ~= nil, true, "reason names the binding command")
  eq(jira[1].reason:find(repo.LIST_COMMAND, 1, true) ~= nil, true, "reason names the listing command")
end)

test("sections: bound by project shows every section, review ones on the client", function()
  local shown = repo.sections({ kind = "projects", projects = { "PAY" } }, config.defaults.sections, { adapter = "gh" })
  eq(#shown, #config.defaults.sections)
  eq(shown[1].query, "project IN (PAY)" .. OPEN)
  eq(shown[4].adapter, "gh")
  eq(shown[4].query, { "pr", "list", "--search", "review-requested:@me" })
end)

test("sections: ignored shows no Jira section; an unknown remote states its reason", function()
  local shown = repo.sections({ kind = "ignored" }, config.defaults.sections, { reason = "origin is elsewhere" })
  eq(#shown, 1)
  eq(shown[1].adapter, nil)
  eq(shown[1].reason, "origin is elsewhere")
end)

test("sections: a complete jql runs in the first Jira section alone", function()
  -- A review section placed ahead of the Jira ones must not count as the first.
  local configured = { config.defaults.sections[4], unpack(config.defaults.sections) }
  local shown = repo.sections({ kind = "jql", jql = "filter = 1" }, configured, { adapter = "glab" })
  local jira = vim.tbl_filter(function(section)
    return section.adapter == "jira"
  end, shown)
  eq(#jira, 1)
  eq(jira[1].title, "All open tickets")
  eq(jira[1].query, "filter = 1")
end)

test("config: configure replaces the section list whole and merges the rest", function()
  local options = config.configure({ sections = { { title = "Only", adapter = "jira", query = "<projects>" } }, timeouts = { tmux = 1 } })
  eq(#options.sections, 1)
  eq(options.timeouts.tmux, 1)
  eq(options.timeouts.git, config.defaults.timeouts.git)
  config.configure({})
  eq(#config.options.sections, #config.defaults.sections)
end)

test("config: the cache directory follows XDG_CACHE_HOME, set or empty", function()
  local saved = vim.env.XDG_CACHE_HOME
  vim.env.XDG_CACHE_HOME = "/x/cache"
  eq(config.cache_dir(), "/x/cache/docket")
  eq(config.configure({}).cache_dir, "/x/cache/docket", "configure takes it from the same function")
  vim.env.XDG_CACHE_HOME = ""
  eq(config.cache_dir(), vim.env.HOME .. "/.cache/docket", "empty counts as unset")
  vim.env.XDG_CACHE_HOME = nil
  eq(config.cache_dir(), vim.env.HOME .. "/.cache/docket")
  eq(config.cache_dir():find("/nvim/", 1, true), nil, "never under the editor's own cache")
  vim.env.XDG_CACHE_HOME = saved
  config.configure({})
end)

test("config: with HOME empty as well, the cache is under the passwd entry's home", function()
  local saved_xdg, saved_home = vim.env.XDG_CACHE_HOME, vim.env.HOME
  vim.env.XDG_CACHE_HOME, vim.env.HOME = "", ""
  local dir = config.cache_dir()
  vim.env.XDG_CACHE_HOME, vim.env.HOME = saved_xdg, saved_home
  eq(dir, vim.uv.os_get_passwd().homedir .. "/.cache/docket")
end)

-- the branch rule ----------------------------------------------------------------

test("branch: punctuation collapses to single hyphens", function()
  eq(env.branch_for("PROJ-142", "Fix: race (in) flush!!"), "PROJ-142-fix-race-in-flush")
end)

test("branch: a summary that is all punctuation leaves the key alone", function()
  eq(env.branch_for("PROJ-142", "!!! ??? ..."), "PROJ-142")
  eq(env.branch_for("PROJ-142", ""), "PROJ-142")
end)

test("branch: a very long summary is capped with no trailing hyphen", function()
  local summary = ("retry backoff drops the last attempt when the queue is"):rep(4)
  local branch = env.branch_for("PROJ-142", summary)
  eq(#branch <= env.BRANCH_MAX, true, "length")
  eq(branch:sub(1, 9), "PROJ-142-")
  eq(branch:sub(-1) ~= "-", true, "no trailing hyphen")
  eq(branch:find("[^%w%-]"), nil, "alphabet")
  -- The cap lands just after the run of letters, on the hyphen before `tail`.
  eq(env.branch_for("PROJ-142", ("a"):rep(50) .. " tail"), "PROJ-142-" .. ("a"):rep(50), "a cut on a hyphen drops it")
  local long_key = ("K"):rep(70) .. "-1"
  eq(env.key_of(env.branch_for(long_key, "x")), long_key, "the cap never shortens the key")
end)

test("branch: the key is read back off a generated branch", function()
  eq(env.key_of("PROJ-142-fix-race-in-flush"), "PROJ-142")
  eq(env.key_of("feature/PROJ-142"), nil)
  eq(env.key_of("main"), nil)
  eq(env.key_of("PROJ-142abc"), nil, "the key ends at a word boundary")
  eq(env.key_of("PROJ-142"), "PROJ-142")
  eq(env.key_of("PROJ-1420-x"), "PROJ-1420")
  eq(env.key_of("PROJ-142_x"), "PROJ-142")
end)

-- the window-name rule -----------------------------------------------------------

test("window: slash, dot, colon and space each collapse to one hyphen", function()
  eq(env.window_name("feature/PAY 1.2:hot fix"), "feature-PAY-1-2-hot-fix")
  eq(env.window_name("a/./:  b"), "a-b")
end)

test("window: a branch inside the alphabet is unchanged and never truncated", function()
  eq(env.window_name("PROJ-142-fix_race"), "PROJ-142-fix_race")
  local long = ("x"):rep(200)
  eq(env.window_name(long), long)
end)

test("window: the editor command carries the review identifier as one argument", function()
  eq(env.editor_command(nil), { "nvim" })
  eq(env.editor_command("!482"), { "nvim", "-c", "Docket review !482" })
end)

-- Opens the windows for PROJ-1-x inside tmux with every tmux call recorded,
-- `list-windows` answered with `windows` and every other call succeeding.
-- `answer`, when given, is asked first for each call and answers it with the
-- result it returns; a nil return leaves the call to the rule above.
local function tmux_launch(windows, answer)
  local saved_tmux, saved_wait = vim.env.TMUX, spawn.wait
  local calls = {}
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  spawn.wait = function(argv)
    calls[#calls + 1] = argv
    local answered = answer and answer(argv)
    if answered then
      return vim.tbl_extend("keep", answered, { argv = argv, stdout = "", stderr = "", timed_out = false })
    end
    local stdout = argv[2] == "list-windows" and windows or ""
    return { argv = argv, ok = true, code = 0, stdout = stdout, stderr = "", timed_out = false }
  end
  local ok, opened, err = pcall(env.open_windows, "/w/p", "PROJ-1-x", env.editor_command("!4"))
  spawn.wait = saved_wait
  vim.env.TMUX = saved_tmux
  assert(ok, opened)
  return opened, err, calls
end

-- The calls that make both windows and list them, which every launch inside
-- tmux starts with.
local TMUX_MADE = {
  { "tmux", "new-window", "-S", "-n", "PROJ-1-x", "-c", "/w/p", "nvim", "-c", "Docket review !4" },
  { "tmux", "new-window", "-S", "-d", "-n", "PROJ-1-x-sh", "-c", "/w/p" },
  { "tmux", "list-windows", "-F", "#{window_id} #{window_name}" },
}

test("window: inside tmux every target after creation is a window id, and nothing spawns but tmux", function()
  local opened, err, calls = tmux_launch("@3 PROJ-1-x\n@4 PROJ-1-x-sh\n")
  eq(err, nil)
  eq(opened, { how = "tmux", editor = "PROJ-1-x", shell = "PROJ-1-x-sh" })
  eq(
    calls,
    vim.list_extend(vim.deepcopy(TMUX_MADE), {
      { "tmux", "set-option", "-w", "-t", "@3", "allow-rename", "off" },
      { "tmux", "set-option", "-w", "-t", "@4", "allow-rename", "off" },
      { "tmux", "select-window", "-t", "@3" },
    })
  )
end)

test("window: a companion the listing does not hold once is a warning naming it, and is not settled", function()
  for _, case in ipairs({
    {
      listing = "@1 dash\n@3 PROJ-1-x\n",
      warning = "tmux lists no window named PROJ-1-x-sh after new-window -S made it; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    },
    {
      listing = "@3 PROJ-1-x\n@4 PROJ-1-x-sh\n@9 PROJ-1-x-sh\n",
      warning = "tmux lists more than one window named PROJ-1-x-sh: @4, @9; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    },
  }) do
    local opened, err, calls = tmux_launch(case.listing)
    eq(err, nil)
    eq(opened, { how = "tmux", editor = "PROJ-1-x", warning = case.warning }, "no companion to switch to")
    eq(
      calls,
      vim.list_extend(vim.deepcopy(TMUX_MADE), {
        { "tmux", "set-option", "-w", "-t", "@3", "allow-rename", "off" },
        { "tmux", "select-window", "-t", "@3" },
      }),
      "the editor's window is still settled and selected"
    )
  end
end)

test("window: an editor's window the listing does not hold once fails the launch with the listing's ids", function()
  for _, case in ipairs({
    {
      listing = "@1 dash\n@4 PROJ-1-x-sh\n",
      err = "tmux lists no window named PROJ-1-x after new-window -S made it; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    },
    {
      listing = "@3 PROJ-1-x\n@4 PROJ-1-x-sh\n@7 PROJ-1-x\n",
      err = "tmux lists more than one window named PROJ-1-x: @3, @7; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    },
  }) do
    local opened, err, calls = tmux_launch(case.listing)
    eq(opened, nil)
    eq(err, case.err)
    eq(calls, TMUX_MADE, "nothing is addressed once the editor's window has no single id")
  end
end)

test("window: a listing tmux refuses fails the launch with tmux's words, and nothing is addressed", function()
  local opened, err, calls = tmux_launch("", function(argv)
    if argv[2] == "list-windows" then
      return { ok = false, code = 1, stderr = "no server running" }
    end
  end)
  eq(opened, nil)
  eq(err, "tmux exited 1\nno server running")
  eq(calls, TMUX_MADE)
end)

test("window: a companion that closes after the listing is a warning, and is not named", function()
  local opened, err, calls = tmux_launch("@3 PROJ-1-x\n@4 PROJ-1-x-sh\n", function(argv)
    if argv[2] == "set-option" and argv[5] == "@4" then
      return { ok = false, code = 1, stderr = "can't find window: @4" }
    end
  end)
  eq(err, nil)
  eq(opened, { how = "tmux", editor = "PROJ-1-x", warning = "tmux exited 1\ncan't find window: @4" }, "no companion to switch to")
  eq(
    calls,
    vim.list_extend(vim.deepcopy(TMUX_MADE), {
      { "tmux", "set-option", "-w", "-t", "@3", "allow-rename", "off" },
      { "tmux", "set-option", "-w", "-t", "@4", "allow-rename", "off" },
      { "tmux", "select-window", "-t", "@3" },
    }),
    "the editor's window is still selected"
  )
end)

test("window: a listing is read into ids and names, a name with a space included, and an empty one holds no window", function()
  eq(env.parse_windows(""), {})
  eq(env.parse_windows("\n"), {})
  eq(env.parse_windows("@1 dash\n@12 my notes\n@3 \n"), {
    { id = "@1", name = "dash" },
    { id = "@12", name = "my notes" },
    { id = "@3", name = "" },
  })
  eq({ env.window_id(env.parse_windows("@1 a\n@2 ab\n"), "a") }, { "@1", { "@1" } }, "the whole name, not a prefix")
  eq({ env.window_id(env.parse_windows(""), "a") }, { nil, {} })
end)

test("window: away from tmux a tab of this editor opens at the path and runs a review's command, and a tab already there is reused", function()
  local saved_tmux, saved_wait = vim.env.TMUX, spawn.wait
  vim.env.TMUX = nil
  spawn.wait = function()
    error("nothing is spawned away from tmux")
  end
  local path, other = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  vim.fn.mkdir(other, "p")
  local reviewed = {}
  vim.api.nvim_create_user_command("Docket", function(command)
    reviewed[#reviewed + 1] = command.args
  end, { nargs = "*" })
  local tabs = vim.fn.tabpagenr("$")
  local ok, opened, err = pcall(env.open_windows, path, "PROJ-1-x", env.editor_command("!4"))
  local path_tab = vim.api.nvim_get_current_tabpage()
  local path_cwd = vim.fn.getcwd(-1, 0)
  local ok_plain, plain, err_plain = pcall(env.open_windows, other, "PROJ-2-y", env.editor_command(nil))
  local other_tab = vim.api.nvim_get_current_tabpage()
  local opened_tabs = vim.fn.tabpagenr("$")
  -- The same review again, from the tab at the other path: the tab at this
  -- one is switched to, as `new-window -S` finds a window inside tmux.
  local ok_again, again, err_again = pcall(env.open_windows, path, "PROJ-1-x", env.editor_command("!4"))
  local again_tab = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_del_user_command("Docket")
  spawn.wait = saved_wait
  vim.env.TMUX = saved_tmux
  -- The tabs close again, or a later test finds its buffer still shown in a
  -- tab this one left, and a `bufhidden=wipe` buffer is never hidden.
  for _, tab in ipairs({ path_tab, other_tab }) do
    if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
    end
  end
  assert(ok, opened)
  assert(ok_plain, plain)
  assert(ok_again, again)
  eq({ err, err_plain, err_again }, {})
  eq({ opened.how, plain.how, again.how }, { "tab", "tab", "tab" })
  eq(opened_tabs, tabs + 2, "one tab per path")
  eq(vim.uv.fs_realpath(path_cwd), vim.uv.fs_realpath(path), "the new tab's working directory is the path")
  eq(again_tab, path_tab, "a tab already at the path is switched to")
  eq(reviewed, { "review !4" }, "the review command ran in the tab it opened, once, and not again in the tab reused")
  eq(again.script, opened.script, "the reused tab still returns the script for printing")
  eq(opened.script:sub(1, #"tmux new-window -S -n"), "tmux new-window -S -n", "the script is returned for printing")
  eq(opened.editor, nil, "no window names: nothing was opened in tmux")
  eq(vim.fn.tabpagenr("$"), tabs, "and the tabs it opened are closed")
end)

test("window: the pasteable script quotes the path, names both windows, and reads as fish", function()
  local script = env.tmux_script("/w/my repo/PROJ-1-x", "PROJ-1-x", { "nvim", "-c", "Docket review !4" })
  local lines = vim.split(script, "\n")
  eq(lines[1], "tmux new-window -S -n 'PROJ-1-x' -c '/w/my repo/PROJ-1-x' 'nvim' '-c' 'Docket review !4'")
  eq(lines[2], "tmux new-window -S -d -n 'PROJ-1-x-sh' -c '/w/my repo/PROJ-1-x'")
  eq(lines[3], "tmux set-window-option -t '=PROJ-1-x' allow-rename off")
  eq(lines[4], "tmux set-window-option -t '=PROJ-1-x-sh' allow-rename off")
  eq(lines[#lines], "tmux select-window -t '=PROJ-1-x'")
  -- Pasted at a fish or a bash prompt, which spell a variable differently, so
  -- no line sets one or reads one back.
  for _, line in ipairs(lines) do
    eq(line:find("$(", 1, true), nil, "no substitution: " .. line)
    eq(line:find("=$", 1, true), nil, "no assignment: " .. line)
  end
end)

-- the remote-to-adapter choice -----------------------------------------------------

test("remote: a GitLab host selects glab", function()
  eq(repo.adapter_for("git@gitlab.example.com:group/proj.git"), "glab")
  eq(repo.adapter_for("ssh://git@GitLab.corp:2222/group/proj.git"), "glab")
end)

test("remote: a GitHub host selects gh", function()
  eq(repo.adapter_for("https://github.com/owner/repo.git"), "gh")
  eq(repo.adapter_for("git@github.com:owner/repo.git"), "gh")
end)

test("remote: anything else selects nothing and says why", function()
  local adapter, reason = repo.adapter_for("ssh://git@bitbucket.org/team/repo.git")
  eq(adapter, nil)
  eq(reason:find("bitbucket.org", 1, true) ~= nil, true, "reason names the host")
  -- The host alone: no user in front of it and no port behind it, in either
  -- form of the URL.
  local elsewhere = "origin is on bitbucket.org, which is neither GitLab nor GitHub, so there are no review sections"
  eq(select(2, repo.adapter_for("ssh://git@bitbucket.org:7999/team/repo.git")), elsewhere)
  eq(select(2, repo.adapter_for("git@bitbucket.org:team/repo.git")), elsewhere)
  adapter, reason = repo.adapter_for("/srv/git/repo.git")
  eq(adapter, nil)
  eq(reason:find("names no host", 1, true) ~= nil, true, "a path names no host")
end)

-- the worktree listing --------------------------------------------------------------

test("worktrees: porcelain pairs each path with its branch, detached with none", function()
  local porcelain = table.concat({
    "worktree /w/repo",
    "HEAD 14a101eb9a31b979dcb033978afd9a713b06f60f",
    "bare",
    "",
    "worktree /w/repo/PROJ-142-fix-race",
    "HEAD 96b18f5bdb0274141283ef4343de8a823c5002ba",
    "branch refs/heads/PROJ-142-fix-race",
    "",
    "worktree /w/repo/v1.2.0",
    "HEAD 96b18f5bdb0274141283ef4343de8a823c5002ba",
    "detached",
    "",
  }, "\n")
  local found = repo.parse_worktrees(porcelain)
  eq(found, {
    { path = "/w/repo" },
    { path = "/w/repo/PROJ-142-fix-race", branch = "PROJ-142-fix-race" },
    { path = "/w/repo/v1.2.0" },
  })
  eq(repo.worktree_for_key(found, "PROJ-142"), found[2])
  eq(repo.worktree_for_key(found, "PROJ-14"), nil, "the prefix includes the hyphen")
  eq(repo.worktree_for_branch(found, "PROJ-142-fix-race"), found[2])
  eq(repo.worktree_for_branch(found, "PROJ-142"), nil)
end)

-- row ordering ------------------------------------------------------------------------

test("rows: identifiers compare by number, sources in section order", function()
  local rows = {
    row.new({ source = "glab", id = "!10", state = "open", title = "b" }),
    row.new({ source = "jira", id = "PAY-1234", state = "To Do", title = "c" }),
    row.new({ source = "glab", id = "!9", state = "open", title = "a" }),
    row.new({ source = "jira", id = "PAY-1201", state = "To Do", title = "d" }),
  }
  local ids = vim.tbl_map(function(r)
    return r.id
  end, row.sort(rows))
  eq(ids, { "PAY-1201", "PAY-1234", "!9", "!10" })
end)

test("rows: a row missing a rendered field is refused", function()
  eq(pcall(row.new, { source = "jira", id = "PAY-1", state = "", title = "t" }), false)
  eq(pcall(row.new, { source = "svn", id = "1", state = "s", title = "t" }), false)
end)

test("rows and items: a category is kept only as a non-empty string, and fork only when true", function()
  local base = { source = "jira", id = "PAY-1", state = "To Do", title = "t" }
  eq(row.new(vim.tbl_extend("force", base, { category = "new" })).category, "new")
  eq(item.new(vim.tbl_extend("force", base, { category = "new" })).category, "new")
  -- A JSON null decodes to vim.NIL where luanil is not asked for, and a
  -- payload of another shape can put a table there.
  for _, odd in ipairs({ "", vim.NIL, { key = "new" }, 3 }) do
    eq(row.new(vim.tbl_extend("force", base, { category = odd })).category, nil, vim.inspect(odd))
    eq(item.new(vim.tbl_extend("force", base, { category = odd })).category, nil, vim.inspect(odd))
  end
  eq(row.new(vim.tbl_extend("force", base, { fork = true })).fork, true)
  for _, odd in ipairs({ false, "true", 1 }) do
    eq(row.new(vim.tbl_extend("force", base, { fork = odd })).fork, nil, vim.inspect(odd))
  end
end)

-- spawn's pure parts --------------------------------------------------------------------

test("spawn: the added environment is the four variables and nothing curated", function()
  eq(spawn.ENV, { NO_COLOR = "1", CLICOLOR = "0", GH_NO_UPDATE_NOTIFIER = "1", GH_PROMPT_DISABLED = "1" })
end)

test("spawn: a failure message carries stderr verbatim", function()
  local result = { argv = { "glab", "mr", "list" }, ok = false, code = 1, stdout = "", stderr = "not logged in\nrun glab auth login", timed_out = false }
  eq(spawn.message(result), "glab exited 1\nnot logged in\nrun glab auth login")
  eq(spawn.decode({ argv = { "glab" }, stdout = '{"iid": 4}' }), { iid = 4 })
  local value, err = spawn.decode({ argv = { "glab" }, stdout = "not json" })
  eq(value, nil)
  eq(err:find("^glab: output is not JSON") ~= nil, true, err)
end)

-- The tests below call the real spawn.run and spawn.wait. The only processes
-- they start are `sh`; a client name that no machine has is how a missing
-- one is reached.

test("spawn: a missing executable is a result, answered before run returns, with no source location", function()
  local got
  local handle = real_run({ "docket-no-such-client" }, nil, function(result)
    got = result
  end)
  eq(handle, nil)
  eq(got and got.code, spawn.MISSING, "on_done ran before run returned")
  eq(got.ok, false)
  eq(got.stderr:find("^[^%s]-:%d+: "), nil, got.stderr)
  eq(got.stderr:find("docket-no-such-client", 1, true) ~= nil, true, "vim.system's own words name the command: " .. got.stderr)
  eq(real_wait({ "docket-no-such-client" }).code, spawn.MISSING)
  eq(spawn.message(got):sub(1, #"docket-no-such-client: not found\n"), "docket-no-such-client: not found\n")
  eq(spawn.message({ argv = { "acli" }, code = 1, stderr = "", timed_out = false }), "acli exited 1", "no stderr, no trailing newline")
end)

test("spawn: a working directory that does not exist is not reported as a missing client", function()
  local gone = real_wait({ "sh", "-c", "true" }, { cwd = "/nonexistent" })
  eq(gone.ok, false)
  eq(gone.code, 1, "not MISSING: sh is there")
  eq(gone.unstarted, true)
  eq(spawn.message(gone), "sh: not started\nthe working directory /nonexistent does not exist; :cd to one that does")
  -- vim.fn.getcwd() answers "" in a tab whose directory has been removed.
  local removed = real_wait({ "sh", "-c", "true" }, { cwd = "" })
  eq({ removed.code, removed.unstarted }, { 1, true })
  eq(removed.stderr, "the editor's working directory has been removed; :cd to one that exists")
  local got
  real_run({ "sh", "-c", "true" }, { cwd = "/nonexistent" }, function(result)
    got = result
  end)
  eq({ got.code, got.unstarted }, { 1, true }, "run reports it the same way, before it returns")
  eq(real_wait({ "sh", "-c", "true" }).unstarted, nil, "a process that ran carries no unstarted")
end)

test("spawn: a process whose child keeps the output open past the timeout is a timeout, not an error", function()
  -- sh waits for the `sleep` it started, so neither has exited at the
  -- timeout, and both hold the pipes open.
  local ok, result = pcall(real_wait, { "sh", "-c", "sleep 2 & wait; true" }, { timeout = 200 })
  eq(ok, true, tostring(result))
  eq({ result.ok, result.code, result.timed_out, result.timeout }, { false, spawn.TIMED_OUT, true, 200 })
  eq(spawn.message(result), "sh: killed after 200 ms without exiting")
end)

test("spawn: run answers at its timeout when the process exits and a child it left holds the output, and kills that child", function()
  -- sh exits at once and the `sleep` it started keeps both pipes open, so
  -- vim.system itself would answer after five seconds, with code 0. The
  -- sleep's pid goes to a file, since the output is what is being held.
  local pidfile = vim.fn.tempname()
  local answers = {}
  local started = vim.uv.hrtime()
  real_run({ "sh", "-c", ("sleep 5 & echo $! > %s; true"):format(vim.fn.shellescape(pidfile)) }, { timeout = 200 }, function(result)
    answers[#answers + 1] = { result = result, ms = (vim.uv.hrtime() - started) / 1e6 }
  end)
  vim.wait(2000, function()
    return #answers > 0
  end)
  eq(#answers, 1, "an answer came within two seconds")
  local result = answers[1].result
  eq({ result.ok, result.code, result.timed_out, result.timeout }, { false, spawn.TIMED_OUT, true, 200 })
  eq(answers[1].ms < 1000, true, ("answered after %d ms"):format(answers[1].ms))
  local pid = tonumber(vim.fn.readfile(pidfile)[1])
  local gone = vim.wait(1000, function()
    return not pcall(function()
      assert(vim.uv.kill(pid, 0))
    end)
  end)
  eq(gone, true, "the sleep sh left behind was killed with its group")
  -- The group is dead, so vim.system's own answer lands now; it is dropped.
  vim.wait(300)
  eq(#answers, 1, "the late exit does not answer a second time")
  vim.fn.delete(pidfile)
end)

test("spawn: wait returns at its timeout when the process exits and a child it left holds the output, and kills that child", function()
  -- sh exits at once and the `sleep` keeps both pipes open, so vim.system's
  -- own answer would come when the sleep ends.
  local started = vim.uv.hrtime()
  local result = real_wait({ "sh", "-c", "sleep 2 & true" }, { timeout = 200 })
  local ms = (vim.uv.hrtime() - started) / 1e6
  eq({ result.ok, result.code, result.timed_out, result.timeout }, { false, spawn.TIMED_OUT, true, 200 })
  eq(ms < 1000, true, ("returned after %d ms"):format(ms))
  -- The same with the sleep's pid written to a file, since the output is
  -- what is being held.
  local pidfile = vim.fn.tempname()
  started = vim.uv.hrtime()
  result = real_wait({ "sh", "-c", ("sleep 5 & echo $! > %s; true"):format(vim.fn.shellescape(pidfile)) }, { timeout = 200 })
  ms = (vim.uv.hrtime() - started) / 1e6
  eq({ result.ok, result.code, result.timed_out }, { false, spawn.TIMED_OUT, true })
  eq(ms < 1000, true, ("returned after %d ms"):format(ms))
  local pid = tonumber(vim.fn.readfile(pidfile)[1])
  local gone = vim.wait(1000, function()
    return not pcall(function()
      assert(vim.uv.kill(pid, 0))
    end)
  end)
  eq(gone, true, "the sleep sh left behind was killed with its group")
  vim.fn.delete(pidfile)
  eq(real_wait({ "sh", "-c", "printf out; exit 3" }, { timeout = 1000 }).stdout, "out", "a process that exits in time is answered with its own output")
end)

test("spawn: run answers a process that exits before its timeout with its own result, once", function()
  local answers = {}
  real_run({ "sh", "-c", "printf out; printf err >&2; exit 3" }, { timeout = 200 }, function(result)
    answers[#answers + 1] = result
  end)
  vim.wait(1000, function()
    return #answers > 0
  end)
  vim.wait(300)
  eq(#answers, 1, "the timer that passes after the exit does not answer")
  eq({ answers[1].ok, answers[1].code, answers[1].timed_out, answers[1].stdout, answers[1].stderr }, { false, 3, false, "out", "err" })
end)

test("spawn: at the timeout the group is sent SIGTERM, which a process can catch, and SIGKILL once GRACE has passed", function()
  -- sh runs a trap once the `wait` the signal interrupts returns, so a
  -- handler that ran leaves the file behind. The `sleep` holds the output.
  local marker = vim.fn.tempname()
  local started = vim.uv.hrtime()
  local result = real_wait({ "sh", "-c", ("trap 'echo cleaned > %s; exit 0' TERM; sleep 5 & wait"):format(vim.fn.shellescape(marker)) }, { timeout = 200 })
  local ms = (vim.uv.hrtime() - started) / 1e6
  eq({ result.ok, result.code, result.timed_out, result.signal }, { false, spawn.TIMED_OUT, true, vim.uv.constants.SIGTERM })
  eq(ms < 1000, true, ("returned after %d ms"):format(ms))
  local cleaned = vim.wait(1000, function()
    return vim.uv.fs_stat(marker) ~= nil
  end)
  eq(cleaned, true, "the handler ran, so the signal sent first was one it could catch")
  eq(vim.fn.readfile(marker), { "cleaned" })
  vim.fn.delete(marker)

  -- A group that ignores SIGTERM -- the `sleep` inherits the disposition --
  -- is still there when wait() returns, and gone once GRACE has passed.
  local pidfile = vim.fn.tempname()
  result = real_wait({ "sh", "-c", ("trap '' TERM; echo $$ > %s; sleep 5 & wait"):format(vim.fn.shellescape(pidfile)) }, { timeout = 200 })
  eq({ result.timed_out, result.signal }, { true, vim.uv.constants.SIGTERM })
  local pid = tonumber(vim.fn.readfile(pidfile)[1])
  eq(vim.uv.kill(pid, 0), 0, "SIGTERM alone left the leader running")
  started = vim.uv.hrtime()
  local gone = vim.wait(spawn.GRACE + 1000, function()
    return not pcall(function()
      assert(vim.uv.kill(pid, 0))
    end)
  end)
  ms = (vim.uv.hrtime() - started) / 1e6
  eq(gone, true, "SIGKILL ended it")
  eq(ms >= spawn.GRACE * 0.8, true, ("the kill came after %d ms, and GRACE is %d"):format(ms, spawn.GRACE))
  vim.fn.delete(pidfile)
end)

test("spawn: a process a signal ended is not ok, whatever its code, and the message names the signal", function()
  -- vim.system reports such a process with code 0, which alone would read as
  -- success: a `glab auth status` the OOM killer ended is not signed in.
  local result = real_wait({ "sh", "-c", "kill -9 $$" }, { timeout = 2000 })
  eq({ result.ok, result.code, result.signal, result.timed_out }, { false, 0, vim.uv.constants.SIGKILL, false })
  eq(spawn.message(result), "sh: killed by signal 9")
  local got
  real_run({ "sh", "-c", "kill -TERM $$" }, { timeout = 2000 }, function(answer)
    got = answer
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq({ got.ok, got.code, got.signal }, { false, 0, vim.uv.constants.SIGTERM }, "run reports it the same way")
  eq(spawn.message(got), "sh: killed by signal 15")
  eq(real_wait({ "sh", "-c", "exit 0" }, { timeout = 2000 }).signal, nil, "a process that exited carries no signal")
  -- The timeout result carries the signal sent first, and its message names
  -- the timeout, which is what the caller decides `unsure` from.
  local timed = real_wait({ "sh", "-c", "sleep 2" }, { timeout = 100 })
  eq({ timed.timed_out, timed.ok, timed.signal }, { true, false, vim.uv.constants.SIGTERM })
  eq(spawn.message(timed), "sh: killed after 100 ms without exiting")
end)

test("spawn: a word a shell would change is quoted, and sh reads every word back as it was", function()
  eq(spawn.shell_line({ "acli", [[a\b]], "it's" }), [[acli 'a'"\\"'b' 'it'\''s']])
  eq(spawn.shell_line({ "glab", "mr", "list", "--reviewer=@me", "a/b.c:1,2%+" }), "glab mr list --reviewer=@me a/b.c:1,2%+", "nothing to quote")
  -- Through a real shell, so the assertion is what a pasted line does rather
  -- than what this file expects it to look like. fish reads the same forms --
  -- the backslash case exists for it -- and is not installed on every machine
  -- this runs on, so sh is the shell that runs.
  local words = { [[a\b]], "it's", [[\']], "two words", "$HOME", "(PAY, TIG)", "" }
  local line = spawn.shell_line(vim.list_extend({ "printf", "[%s]\\n" }, words))
  local result = real_wait({ "sh", "-c", line })
  eq(result.ok, true, spawn.message(result))
  local expected = vim.tbl_map(function(word)
    return "[" .. word .. "]"
  end, words)
  eq(vim.split(result.stdout, "\n", { trimempty = true }), expected, line)
end)

-- the region compare ----------------------------------------------------------------------

-- The snapshot as the read path stores it: `editable` and `reason` are its
-- judgement, and the compare makes none of its own.
local function snapshot()
  return {
    regions = {
      body = { kind = diff.BODY, editable = true, lines = { "The retry loop re-enters", "before the final attempt." } },
      ["10001"] = {
        kind = diff.COMMENT,
        owner = "acc-ana",
        editable = false,
        reason = "written by ana; gx opens it on the web",
        lines = { "Repros on staging." },
      },
      ["10002"] = { kind = diff.COMMENT, owner = "acc-me", editable = true, lines = { "Fix is in review." } },
    },
  }
end

local function unchanged()
  return {
    body = { lines = { "The retry loop re-enters", "before the final attempt." } },
    ["10001"] = { lines = { "Repros on staging." } },
    ["10002"] = { lines = { "Fix is in review." } },
  }
end

test("diff: no change yields no calls", function()
  eq(diff.plan(snapshot(), unchanged()), { calls = {}, skipped = {}, refused = {} })
end)

test("diff: blank lines joined at the edges are not an edit", function()
  local current = unchanged()
  current.body.lines = { "", "The retry loop re-enters", "before the final attempt.", "", "" }
  eq(diff.plan(snapshot(), current).calls, {})
end)

test("diff: a changed body yields one body update", function()
  local current = unchanged()
  current.body.lines = { "The retry loop re-enters", "before the final attempt, so", "one attempt is lost." }
  eq(diff.plan(snapshot(), current).calls, {
    { kind = diff.BODY_UPDATE, id = "body", text = "The retry loop re-enters\nbefore the final attempt, so\none attempt is lost." },
  })
end)

test("diff: a changed own comment yields one comment update", function()
  local current = unchanged()
  current["10002"].lines = { "Fix is merged." }
  eq(diff.plan(snapshot(), current).calls, { { kind = diff.COMMENT_UPDATE, id = "10002", text = "Fix is merged." } })
end)

test("diff: a new region yields a create, an empty one is skipped", function()
  local loaded = snapshot()
  loaded.regions.new = { kind = diff.NEW, lines = { "" } }
  local current = unchanged()
  current.new = { lines = { "Seen on prod too." } }
  eq(diff.plan(loaded, current).calls, { { kind = diff.COMMENT_CREATE, id = "new", text = "Seen on prod too." } })
  current.new = { lines = { "", "  " } }
  local planned = diff.plan(loaded, current)
  eq(planned.calls, {})
  eq(planned.skipped, { { id = "new", reason = "empty; nothing sent" } })
end)

test("diff: an edit in another owner's region is refused before any call", function()
  local current = unchanged()
  current["10001"].lines = { "Repros on staging and prod." }
  current.body.lines = { "changed too" }
  local planned = diff.plan(snapshot(), current)
  eq(planned.calls, {}, "the body change is not sent either")
  eq(#planned.refused, 1)
  eq(planned.refused[1].id, "10001")
  eq(planned.refused[1].reason, "written by ana; gx opens it on the web", "the snapshot's reason, verbatim")
end)

test("diff: an unknown identity is a reason like any other", function()
  local loaded = snapshot()
  loaded.regions["10002"].editable = false
  loaded.regions["10002"].reason = "the account's own identifier is unknown"
  local current = unchanged()
  current["10002"].lines = { "Fix is merged." }
  local refused = diff.plan(loaded, current).refused
  eq(#refused, 1)
  eq(refused[1].reason, "the account's own identifier is unknown")
end)

test("diff: a body carrying a node the write would flatten is refused when changed", function()
  local loaded = snapshot()
  loaded.regions.body.editable = false
  loaded.regions.body.reason = "carries a mention node, which a write would replace by its flattened text"
  local current = unchanged()
  eq(diff.plan(loaded, current), { calls = {}, skipped = {}, refused = {} }, "unchanged, it refuses nothing")
  current.body.lines = { "The retry loop re-enters", "before the final attempt, always." }
  local planned = diff.plan(loaded, current)
  eq(planned.calls, {})
  eq(planned.refused, { { id = "body", reason = loaded.regions.body.reason } })
end)

test("diff: a read-only region left unchanged does not stop the rest", function()
  local current = unchanged()
  current["10002"].lines = { "Fix is merged." }
  local planned = diff.plan(snapshot(), current)
  eq(planned.refused, {})
  eq(planned.calls, { { kind = diff.COMMENT_UPDATE, id = "10002", text = "Fix is merged." } })
end)

test("diff: a region loaded empty and still empty is neither skipped nor sent", function()
  local loaded = snapshot()
  loaded.regions.body.lines = { "" }
  local current = unchanged()
  current.body.lines = { "" }
  eq(diff.plan(loaded, current), { calls = {}, skipped = {}, refused = {} }, "an item with no description saves clean")
  current.body.lines = { "", "  " }
  eq(diff.plan(loaded, current), { calls = {}, skipped = {}, refused = {} }, "blank lines are still not an edit")
  current.body.lines = { "A description at last." }
  eq(diff.plan(loaded, current).calls, { { kind = diff.BODY_UPDATE, id = "body", text = "A description at last." } })
end)

test("diff: a region whose every line was deleted is skipped and the rest still sent", function()
  local current = unchanged()
  current["10002"] = { lines = {} }
  current.body.lines = { "changed" }
  local planned = diff.plan(snapshot(), current)
  eq(planned.skipped, { { id = "10002", reason = "empty; nothing sent" } })
  eq(planned.calls, { { kind = diff.BODY_UPDATE, id = "body", text = "changed" } })
end)

test("diff: a mark gone from the buffer refuses the whole write, naming the yank and :e!", function()
  local current = unchanged()
  current["10001"] = nil
  current.body.lines = { "changed" }
  local planned = diff.plan(snapshot(), current)
  eq(planned.calls, {})
  -- The help file quotes this text.
  eq(planned.refused, { { id = "10001", reason = "its mark is gone; yank the text, then :e! reads the item again" } })
end)

test("diff: regions whose ranges overlap, or one whose end is above its start, refuse the whole write rather than read as emptied", function()
  local current = unchanged()
  current.body = { overlaps = "10002" }
  current["10002"] = { overlaps = "body" }
  local planned = diff.plan(snapshot(), current)
  eq(planned.calls, {})
  eq(planned.skipped, {})
  eq(planned.refused, {
    {
      id = "10002",
      reason = "its text runs into body's, so which lines are whose is lost; u undoes that edit; otherwise yank the text, then :e! reads the item again",
    },
    {
      id = "body",
      reason = "its text runs into 10002's, so which lines are whose is lost; u undoes that edit; otherwise yank the text, then :e! reads the item again",
    },
  })
  current = unchanged()
  current.body = { reversed = true }
  current["10002"].lines = { "Fix is merged." }
  planned = diff.plan(snapshot(), current)
  eq(planned.calls, {}, "the comment's edit waits for the body")
  eq(planned.refused, {
    {
      id = "body",
      reason = "an edit moved its first line below its last, so its mark no longer spans its text; u undoes that edit; otherwise yank the text, then :e! reads the item again",
    },
  })
end)

-- The text outside the regions of the buffer snapshot() describes, as loaded
-- and as buffer.current() reads it.
local FRAME = { "PROJ-142   In Progress   me", "# Retry backoff", "ana   3 days ago", "me   yesterday" }
local function frame_now(lines)
  local rows = { 1, 2, 7, 10 }
  return vim.tbl_map(function(index)
    return { row = rows[index] or index, text = lines[index] }
  end, vim.fn.range(1, #lines))
end

test("diff: text outside every region that was not there at the read refuses the whole write, naming its line", function()
  local loaded = snapshot()
  loaded.frame = FRAME
  local current = unchanged()
  current.body.lines = { "The retry loop re-enters" }
  eq(diff.plan(loaded, current, frame_now(FRAME)).calls, { { kind = diff.BODY_UPDATE, id = "body", text = "The retry loop re-enters" } })
  -- The body's last line, moved out to between the blank after it and the
  -- first author line.
  local frame = frame_now(FRAME)
  table.insert(frame, 3, { row = 6, text = "before the final attempt." })
  local planned = diff.plan(loaded, current, frame)
  eq(planned.calls, {}, "the body is not sent without the line")
  eq(planned.refused, {
    {
      id = diff.OUTSIDE,
      reason = 'line 6, "before the final attempt.", is outside every region, where a save sends nothing; move it into a region, or u undoes the edit that put it there',
    },
  })
  -- An edit to the title is the same: it is never sent.
  frame = frame_now(FRAME)
  frame[2].text = "# Retry backoff, again"
  eq(diff.plan(loaded, unchanged(), frame).refused, {
    {
      id = diff.OUTSIDE,
      reason = 'line 2, "# Retry backoff, again", is outside every region, where a save sends nothing; move it into a region, or u undoes the edit that put it there',
    },
  })
end)

test("diff: text gone from outside the regions refuses the whole write, since a sort may have moved it into one", function()
  local loaded = snapshot()
  loaded.frame = FRAME
  local frame = frame_now(FRAME)
  table.remove(frame, 4)
  local current = unchanged()
  current["10002"].lines = { "me   yesterday", "Fix is in review." }
  eq(diff.plan(loaded, current, frame).refused, {
    {
      id = diff.OUTSIDE,
      reason = '"me   yesterday" is no longer outside the regions, so an edit deleted it or moved it into one, and a save cannot tell which; u undoes that edit',
    },
  })
end)

test("diff: line breaks and spaces moved outside the regions are not a change, and with no frame given nothing outside is compared", function()
  local loaded = snapshot()
  loaded.frame = FRAME
  -- A reflow that split the last author line in two.
  local frame = frame_now({ FRAME[1], FRAME[2], FRAME[3], "me" })
  frame[#frame + 1] = { row = 11, text = "yesterday" }
  eq(diff.plan(loaded, unchanged(), frame), { calls = {}, skipped = {}, refused = {} })
  eq(diff.plan(loaded, unchanged()), { calls = {}, skipped = {}, refused = {} })
end)

test("diff: a region with no snapshot refuses the whole write", function()
  local current = unchanged()
  current["99"] = { lines = { "from nowhere" } }
  local planned = diff.plan(snapshot(), current)
  eq(planned.calls, {})
  eq(planned.refused, { { id = "99", reason = "not in the loaded snapshot" } })
end)

-- the document tree ------------------------------------------------------------------------

local function text(value, marks)
  return { type = "text", text = value, marks = marks }
end

local function paragraph(...)
  return { type = "paragraph", content = { ... } }
end

local function doc(...)
  return { version = 1, type = "doc", content = { ... } }
end

test("adf: render and serialise are inverses over the editable subset", function()
  local tree = doc(
    paragraph(text("The retry loop re-enters"), { type = "hardBreak" }, text("before the final attempt.")),
    paragraph(text("So one attempt is lost."))
  )
  local lines = adf.render(tree)
  eq(lines, { "The retry loop re-enters", "before the final attempt.", "", "So one attempt is lost." })
  eq(adf.serialise(table.concat(lines, "\n")), tree)
  for _, sample in ipairs({ "one", "one\ntwo", "one\n\ntwo", "a\n\n\nb", "a\n", "\na", "  spaced  ", "" }) do
    eq(table.concat(adf.render(adf.serialise(sample)), "\n"), sample, ("round trip of %q"):format(sample))
    eq(adf.editable(adf.serialise(sample)), true, ("serialised %q is editable"):format(sample))
  end
  eq(adf.serialise(""), doc(), "empty text is an empty document")
  eq(adf.serialise("a\n\n\nb"), doc(paragraph(text("a")), paragraph(), paragraph(text("b"))), "two blanks hold one empty paragraph")
  eq(adf.render(nil), {}, "an absent body renders to no lines")
  eq(adf.render(vim.NIL), {}, "a JSON null body renders to no lines")
  -- A description emptied on the web is a document of empty paragraphs, and
  -- it stays editable: the judgement is over node types alone.
  eq({ adf.editable(doc(paragraph())) }, { true }, "one empty paragraph is editable")
  eq({ adf.editable(doc(paragraph(), paragraph())) }, { true }, "two empty paragraphs are editable")
  eq(adf.render(doc(paragraph(), paragraph())), { "" }, "and render to the one blank line the region shows")
end)

test("adf: every tree in the subset renders to lines that serialise back to the same lines", function()
  -- What editable() rests on, since it judges node types alone: over doc,
  -- paragraph, hardBreak and unmarked text, the text render() shows is the
  -- text the write reproduces. Every paragraph of up to three inline nodes
  -- drawn from these, in documents of up to three paragraphs.
  local inlines = { text("a"), text(""), text("  x  "), { type = "hardBreak" } }
  local paragraphs = { paragraph() }
  for _, first in ipairs(inlines) do
    paragraphs[#paragraphs + 1] = paragraph(first)
    for _, second in ipairs(inlines) do
      paragraphs[#paragraphs + 1] = paragraph(first, second)
      for _, third in ipairs(inlines) do
        paragraphs[#paragraphs + 1] = paragraph(first, second, third)
      end
    end
  end
  -- A region with no lines and one with a single blank line are the same
  -- buffer text: render.lua shows both as one blank line.
  local function lines_of(tree)
    local lines = adf.render(tree)
    if #lines == 1 and lines[1] == "" then
      return {}
    end
    return lines
  end
  local function check(tree)
    local editable, reason = adf.editable(tree)
    if not editable then
      error(("editable refused %s: %s"):format(vim.inspect(tree), reason))
    end
    local shown = lines_of(tree)
    local back = lines_of(adf.serialise(table.concat(adf.render(tree), "\n")))
    if not vim.deep_equal(back, shown) then
      error(("round trip of %s:\n  shown %s\n  back  %s"):format(vim.inspect(tree), vim.inspect(shown), vim.inspect(back)))
    end
  end
  local count = 0
  check(doc())
  for _, first in ipairs(paragraphs) do
    check(doc(first))
    count = count + 1
    for _, second in ipairs(paragraphs) do
      check(doc(first, second))
      count = count + 1
    end
  end
  -- Three paragraphs, over the shorter ones, keeps the run under a second.
  local short = { paragraph(), paragraph(text("a")), paragraph({ type = "hardBreak" }), paragraph(text(""), text("a")) }
  for _, first in ipairs(short) do
    for _, second in ipairs(short) do
      for _, third in ipairs(short) do
        check(doc(first, second, third))
        count = count + 1
      end
    end
  end
  eq(count > 1000, true, "the space was actually walked")
end)

test("adf: editable names the first node outside the subset", function()
  eq({ adf.editable(nil) }, { true }, "an absent body is editable")
  eq({ adf.editable(doc()) }, { true }, "an empty body is editable")
  local cases = {
    { "strong", doc(paragraph(text("plain "), text("bold", { { type = "strong" } }))), "a text node with a strong mark" },
    { "em", doc(paragraph(text("x", { { type = "em" } }))), "a text node with an em mark" },
    { "underline", doc(paragraph(text("x", { { type = "underline" } }))), "a text node with an underline mark" },
    { "link", doc(paragraph(text("see", { { type = "link", attrs = { href = "https://x" } } }))), "a text node with a link mark" },
    { "mention", doc(paragraph(text("cc "), { type = "mention", attrs = { id = "acc", text = "@ana" } })), "a mention node" },
    { "list", doc({ type = "bulletList", content = { { type = "listItem", content = { paragraph(text("x")) } } } }), "a bulletList node" },
    { "heading", doc({ type = "heading", attrs = { level = 2 }, content = { text("Steps") } }), "a heading node" },
    { "codeBlock", doc({ type = "codeBlock", attrs = { language = "sh" }, content = { text("ls") } }), "a codeBlock node" },
    { "table", doc({ type = "table", content = {} }), "a table node" },
    { "emoji", doc(paragraph({ type = "emoji", attrs = { shortName = ":smile:" } })), "an emoji node" },
  }
  for _, case in ipairs(cases) do
    local editable, reason = adf.editable(case[2])
    eq(editable, false, case[1])
    eq(reason:find(case[3], 1, true), 9, case[1] .. ": " .. tostring(reason))
  end
  -- The first offending node is the one named, even when a later one differs.
  local _, reason = adf.editable(doc(paragraph(text("a")), { type = "rule" }, paragraph(text("b", { { type = "em" } }))))
  eq(reason:find("a rule node", 1, true) ~= nil, true, reason)
end)

test("adf: the nodes Jira produces render in place, and an unknown one is named", function()
  local tree = doc(
    { type = "heading", attrs = { level = 2 }, content = { text("Steps") } },
    {
      type = "orderedList",
      attrs = { order = 3 },
      content = {
        { type = "listItem", content = { paragraph(text("first"), { type = "hardBreak" }, text("more")) } },
        { type = "listItem", content = { paragraph(text("second")) } },
      },
    },
    { type = "bulletList", content = { { type = "listItem", content = { paragraph(text("x")), { type = "bulletList", content = { { type = "listItem", content = { paragraph(text("y")) } } } } } } } },
    { type = "codeBlock", attrs = { language = "sh" }, content = { text("ls\npwd") } },
    { type = "blockquote", content = { paragraph(text("quoted")), paragraph(text("twice")) } },
    { type = "panel", attrs = { panelType = "info" }, content = { paragraph(text("note")) } },
    paragraph(
      text("bold", { { type = "strong" } }),
      text(" "),
      text("em", { { type = "em" } }),
      text(" "),
      text("code", { { type = "code" } }),
      text(" "),
      text("gone", { { type = "strike" } }),
      text(" "),
      text("site", { { type = "link", attrs = { href = "https://example.test" } } }),
      text(" "),
      { type = "mention", attrs = { id = "acc", text = "@ana" } },
      text(" "),
      { type = "emoji", attrs = { shortName = ":smile:", text = "😀" } },
      text(" "),
      { type = "inlineCard", attrs = { url = "https://example.test/PROJ-1" } }
    ),
    { type = "rule" },
    {
      type = "table",
      content = {
        { type = "tableRow", content = { { type = "tableHeader", content = { paragraph(text("k")) } }, { type = "tableHeader", content = { paragraph(text("v")) } } } },
        { type = "tableRow", content = { { type = "tableCell", content = { paragraph(text("a")) } }, { type = "tableCell", content = { paragraph(text("b")) } } } },
      },
    },
    { type = "mediaSingle", content = { { type = "media", attrs = { id = "m1", alt = "screenshot.png" } } } },
    { type = "taskList", content = { { type = "taskItem", attrs = { state = "DONE" }, content = { text("done") } }, { type = "taskItem", attrs = { state = "TODO" }, content = { text("open") } } } },
    { type = "hologram", content = {} },
    {
      type = "layoutSection",
      content = {
        { type = "layoutColumn", attrs = { width = 50 }, content = { paragraph(text("left")) } },
        { type = "layoutColumn", attrs = { width = 50 }, content = { paragraph(text("right")) } },
      },
    },
    { type = "blockCard", attrs = { url = "https://example.test/card" } },
    { type = "bodiedExtension", attrs = { extensionType = "x" }, content = { paragraph(text("kept")), paragraph(text("too")) } },
    paragraph(text("after "), { type = "placeholder", attrs = { text = "here" } }),
    paragraph({ type = "wormhole", content = { text("inside") } })
  )
  eq(adf.render(tree), {
    "## Steps",
    "",
    "3. first",
    "   more",
    "4. second",
    "",
    "- x",
    "  - y",
    "",
    "```sh",
    "ls",
    "pwd",
    "```",
    "",
    "> quoted",
    ">",
    "> twice",
    "",
    "> [info]",
    "> note",
    "",
    "**bold** _em_ `code` ~~gone~~ [site](https://example.test) @ana 😀 https://example.test/PROJ-1",
    "",
    "---",
    "",
    "| k | v |",
    "| --- | --- |",
    "| a | b |",
    "",
    "[media: screenshot.png]",
    "",
    "- [x] done",
    "- [ ] open",
    "",
    "[unsupported: hologram]",
    "",
    "left",
    "",
    "right",
    "",
    "https://example.test/card",
    "",
    "[unsupported: bodiedExtension]",
    "",
    "kept",
    "",
    "too",
    "",
    "after here",
    "",
    "[unsupported: wormhole] inside",
  })
  -- A node in the wrong position, or an unknown one holding inline content,
  -- renders as inline: one line per line break, not one block per node.
  eq(adf.render(doc({ type = "widget", content = { text("inline text"), { type = "hardBreak" }, text("second line") } })), {
    "[unsupported: widget]",
    "inline text",
    "second line",
  })
  eq(adf.render(doc({ type = "status", attrs = { text = "DONE" } })), { "[DONE]" })
  eq(adf.render(doc({ type = "date", attrs = { timestamp = "1714737600000" } })), { "2024-05-03" })
  eq(adf.render(doc({ type = "placeholder", attrs = { text = "here" } })), { "here" })
  -- A cell is one line, whatever an unknown node inside it would put on a
  -- line of its own.
  eq(
    adf.render({
      type = "table",
      content = {
        { type = "tableRow", content = { { type = "tableCell", content = { { type = "widget", content = { paragraph(text("x")), paragraph(text("y")) } } } } } },
      },
    }),
    { "| [unsupported: widget] x y |" }
  )
end)

test("adf: an image renders by its file name wherever ADF puts it", function()
  -- Inside a paragraph, an image is a mediaInline carrying the file's attrs
  -- or holding the media node that does; on a line of its own it is a
  -- mediaSingle holding the media node. Every position names the file.
  local function media_inline(fields)
    return vim.tbl_extend("force", { type = "mediaInline" }, fields)
  end
  local shot = { alt = "shot.png" }
  eq(adf.render(doc(paragraph(text("see "), media_inline({ attrs = shot })))), { "see [media: shot.png]" })
  eq(
    adf.render(doc(paragraph(media_inline({ content = { { type = "media", attrs = { alt = "inner.png" } } } })))),
    { "[media: inner.png]" },
    "a mediaInline holding the media node names the file, not the wrapper"
  )
  eq(adf.render(doc(paragraph(text("see "), { type = "media", attrs = shot }))), { "see [media: shot.png]" })
  eq(adf.render(doc(media_inline({ attrs = shot }))), { "[media: shot.png]" })
  eq(adf.render(doc({ type = "mediaSingle", content = { { type = "media", attrs = shot } } })), { "[media: shot.png]" })
  eq(adf.render(doc(paragraph({ type = "media", attrs = { id = "m1" } }))), { "[media: m1]" }, "the id when there is no alt")
  -- A mention with neither a display text nor an account id is named as
  -- unsupported rather than rendered as `@nil`.
  eq(adf.render(doc(paragraph({ type = "mention" }))), { "[unsupported: mention]" })
  eq(adf.render(doc(paragraph({ type = "mention", attrs = { id = "acc-1" } }))), { "@acc-1" })
end)

-- the item ------------------------------------------------------------------------------

local function ticket(overrides)
  local fields = {
    source = "jira",
    id = "PROJ-142",
    title = "Retry backoff drops the last attempt",
    state = "In Progress",
    -- What `statusCategory.key` carries for a status in progress, which is
    -- what the header colours the state by.
    category = "indeterminate",
    url = "https://jira.example.test/browse/PROJ-142",
    assignee = { id = "acc-me", name = "Me Myself" },
    reporter = { id = "acc-ana", name = "ana" },
    updated = "2024-05-03T10:00:00.000+0000",
    body = doc(paragraph(text("The retry loop re-enters"), { type = "hardBreak" }, text("before the final attempt."))),
    comments = {
      { id = 10001, author = { id = "acc-ana", name = "ana" }, created = "2024-04-30T12:00:00.000+0000", body = doc(paragraph(text("Repros on staging."))) },
      { id = 10002, author = { id = "acc-me", name = "Me Myself" }, created = "2024-05-02T09:00:00.000+0000", body = doc(paragraph(text("Fix is in review."))) },
    },
    total = 2,
    me = "acc-me",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  return item.new(fields)
end

-- 2024-05-03T12:00:00Z, the present every relative time here is measured from.
local NOW = 1714737600

test("item: the kinds agree with diff's", function()
  eq({ item.BODY, item.COMMENT, item.NEW }, { diff.BODY, diff.COMMENT, diff.NEW })
end)

test("item: fields are normalised, a null is nil, and a comment id is a string", function()
  local it = ticket({ body = vim.NIL, total = vim.NIL, reporter = vim.NIL })
  eq(it.body, nil)
  eq(it.total, nil)
  eq(it.missing, 0, "no total means nothing is known to be missing")
  eq(it.reporter, nil)
  eq(it.comments[1].id, "10001")
  eq(it.comments[1].author, { id = "acc-ana", name = "ana" })
  -- `project` is kept as a non-empty string alone: with "" kept, the item
  -- buffer would hold it against the name and refuse the read as "!1 of ".
  eq(item.new({ source = "glab", id = "!1", title = "t", project = "acme/payments" }).project, "acme/payments")
  eq(item.new({ source = "glab", id = "!1", title = "t", project = "" }).project, nil)
  eq(item.new({ source = "glab", id = "!1", title = "t", project = vim.NIL }).project, nil)
  eq(item.new({ source = "glab", id = "!1", title = "t" }).project, nil)
  -- Refused with the message alone: the buffer shows it after the item's
  -- name, where a path into item.lua would be noise.
  eq({ pcall(item.new, { source = "jira", id = "PROJ-1", title = "" }) }, { false, "item: PROJ-1 needs a non-empty string for title" })
  eq(
    { pcall(item.new, { source = "jira", id = "PROJ-1", title = "t", comments = { { body = doc() } } }) },
    { false, "item: comment 1 of PROJ-1 has no id" }
  )
end)

test("item: a merge request keeps its source branch and its fork mark, each only when it is one", function()
  local it = item.new({ source = "glab", id = "!1", title = "t", branch = "feature/x", fork = true })
  eq({ it.branch, it.fork }, { "feature/x", true })
  for _, given in ipairs({ { branch = "", fork = false }, { branch = vim.NIL, fork = vim.NIL }, {} }) do
    local bare = item.new(vim.tbl_extend("force", { source = "glab", id = "!1", title = "t" }, given))
    eq({ bare.branch, bare.fork }, {}, vim.inspect(given))
  end
  eq({ ticket().branch, ticket().fork }, {}, "a ticket carries neither")
end)

test("item: a truncated thread is the difference between total and what came", function()
  eq(ticket({ total = 7 }).missing, 5)
  eq(ticket({ total = 2 }).missing, 0)
  eq(ticket({ total = 1 }).missing, 0, "a total below the count is not a negative gap")
  eq(ticket().start_at, 0, "unsaid, the page starts the thread")
  eq(ticket({ start_at = 5 }).start_at, 5)
  eq(ticket({ start_at = vim.NIL }).start_at, 0)
end)

test("item: timestamps parse in every shape the clients write, and read relatively", function()
  eq(item.parse_time("2024-05-03T12:00:00.000+0000"), NOW)
  eq(item.parse_time("2024-05-03T13:00:00.000+0100"), NOW)
  eq(item.parse_time("2024-05-03T11:30:00-00:30"), NOW)
  eq(item.parse_time("2024-05-03T12:00:00Z"), NOW)
  eq(item.parse_time("1970-01-01T00:00:00Z"), 0)
  -- Across a leap day, a month, a year, and either side of the epoch: each
  -- value is what Python's datetime.fromisoformat gives.
  eq(item.parse_time("2024-02-29T23:59:59Z"), 1709251199)
  eq(item.parse_time("2024-03-01T00:00:00Z"), 1709251200)
  eq(item.parse_time("2024-12-31T23:59:59.999+0100"), 1735685999)
  eq(item.parse_time("1900-03-01T00:00:00Z"), -2203891200)
  eq(item.parse_time("2100-02-28T00:00:00Z"), 4107456000)
  eq(item.parse_time("yesterday"), nil)
  eq(item.parse_time(nil), nil)
  -- An impossible date is nil rather than a plausible moment.
  eq(item.parse_time("2024-13-45T00:00:00Z"), nil)
  eq(item.parse_time("2024-02-30T00:00:00Z"), nil)
  eq(item.parse_time("2023-02-29T00:00:00Z"), nil, "not a leap year")
  eq(item.parse_time("2024-05-03T24:00:00Z"), nil)
  eq(item.ago(NOW - 5, NOW), "just now")
  eq(item.ago(NOW - 59, NOW), "just now")
  eq(item.ago(NOW - 60, NOW), "1m ago")
  eq(item.ago(NOW - 300, NOW), "5m ago")
  eq(item.ago(NOW - 3599, NOW), "59m ago")
  eq(item.ago(NOW - 7200, NOW), "2h ago")
  eq(item.ago(NOW - 86399, NOW), "23h ago")
  eq(item.ago(NOW - 86400, NOW), "yesterday")
  eq(item.ago(NOW - 30 * 3600, NOW), "yesterday")
  eq(item.ago(NOW - 2 * 86400, NOW), "2 days ago")
  eq(item.ago(NOW - 3 * 86400, NOW), "3 days ago")
  eq(item.ago(NOW - 30 * 86400, NOW), "2024-04-03")
  eq(item.ago(NOW - 45 * 86400, NOW), "2024-03-19")
end)

test("item: regions are the body then each comment, owned or not", function()
  local regions = item.regions(ticket())
  eq(#regions, 3)
  eq(regions[1].id, "body")
  eq(regions[1].kind, item.BODY)
  eq(regions[1].editable, true)
  eq(regions[2], { id = "10001", kind = item.COMMENT, owner = "acc-ana", editable = false, reason = "written by ana", body = ticket().comments[1].body })
  eq(regions[3].editable, true)
  eq(regions[3].owner, "acc-me")
end)

test("item: an unknown identity makes every comment read-only and the body stays editable", function()
  local regions = item.regions(ticket({ me = vim.NIL }))
  eq(regions[1].editable, true)
  for index = 2, 3 do
    eq(regions[index].editable, false)
    eq(regions[index].reason:find("identifier is unknown", 1, true) ~= nil, true, regions[index].reason)
  end
end)

-- the buffer rendering --------------------------------------------------------------------

test("render: the lines and the ranges of each region", function()
  local lines, regions = render.render(ticket(), { now = NOW })
  eq(lines, {
    "PROJ-142   In Progress   me   updated 2h ago",
    "# Retry backoff drops the last attempt",
    "",
    "The retry loop re-enters",
    "before the final attempt.",
    "",
    "ana   3 days ago",
    "Repros on staging.",
    "",
    "me   yesterday",
    "Fix is in review.",
  })
  eq(regions, {
    {
      id = "body",
      kind = diff.BODY,
      owner = nil,
      editable = true,
      reason = nil,
      first_line = 4,
      last_line = 5,
      lines = { "The retry loop re-enters", "before the final attempt." },
    },
    {
      id = "10001",
      kind = diff.COMMENT,
      owner = "acc-ana",
      editable = false,
      reason = "written by ana; " .. render.WEB_HINT,
      first_line = 8,
      last_line = 8,
      lines = { "Repros on staging." },
    },
    {
      id = "10002",
      kind = diff.COMMENT,
      owner = "acc-me",
      editable = true,
      reason = nil,
      first_line = 11,
      last_line = 11,
      lines = { "Fix is in review." },
    },
  })
  for _, region in ipairs(regions) do
    eq(vim.list_slice(lines, region.first_line, region.last_line), region.lines, region.id .. " range matches its lines")
  end
  -- The regions are exactly what diff's snapshot takes.
  local snap = { regions = {} }
  local current = {}
  for _, region in ipairs(regions) do
    snap.regions[region.id] = region
    current[region.id] = { lines = vim.deepcopy(region.lines) }
  end
  eq(diff.plan(snap, current), { calls = {}, skipped = {}, refused = {} })
end)

test("render: a region carrying a node the write would flatten is read-only with the node named", function()
  local it = ticket({
    body = doc(paragraph(text("cc "), { type = "mention", attrs = { id = "acc-ana", text = "@ana" } })),
    comments = {
      { id = 10002, author = { id = "acc-me", name = "me" }, created = "2024-05-02T09:00:00.000+0000", body = doc(paragraph(text("plain "), text("bold", { { type = "strong" } }))) },
    },
    total = 1,
  })
  local lines, regions = render.render(it, { now = NOW })
  eq(lines[4], "cc @ana")
  eq(regions[1].editable, false)
  eq(regions[1].reason, "carries a mention node, which a write would replace by its flattened text; " .. render.WEB_HINT)
  eq(lines[7], "plain **bold**")
  eq(regions[2].editable, false)
  eq(regions[2].reason:find("a text node with a strong mark", 1, true) ~= nil, true, regions[2].reason)
end)

test("render: ownership is judged before the tree, and an unknown identity keeps the body editable", function()
  local it = ticket({
    comments = {
      { id = 10001, author = { id = "acc-ana", name = "ana" }, body = doc(paragraph(text("x", { { type = "em" } }))) },
    },
    total = 1,
  })
  local _, regions = render.render(it, { now = NOW })
  eq(regions[2].reason, "written by ana; " .. render.WEB_HINT, "the owner is named, not the mark")
  _, regions = render.render(ticket({ me = vim.NIL }), { now = NOW })
  eq(regions[1].editable, true)
  eq(regions[2].editable, false)
  eq(regions[3].editable, false)
end)

test("render: an empty body is one editable blank line, and no comments is no author line", function()
  local lines, regions = render.render(ticket({ body = vim.NIL, comments = {}, total = 0, assignee = vim.NIL, updated = vim.NIL }), { now = NOW })
  eq(lines, { "PROJ-142   In Progress   unassigned", "# Retry backoff drops the last attempt", "", "" })
  eq(#regions, 1)
  eq(regions[1], { id = "body", kind = diff.BODY, owner = nil, editable = true, reason = nil, first_line = 4, last_line = 4, lines = { "" } })
end)

test("render: a truncated thread says how many comments are not shown, where they would be", function()
  -- The page starts the thread, so the comments not shown are the newer ones.
  local lines, regions = render.render(ticket({ total = 7 }), { now = NOW })
  eq(lines[#lines], "5 of 7 comments not shown; " .. render.WEB_HINT)
  eq(lines[#lines - 1], "")
  eq(#regions, 3, "the comments it has are ordinary regions")
  eq(regions[3].last_line, #lines - 2, "the notice sits outside every region")
  -- The page starts past the beginning, so the older ones are missing.
  lines, regions = render.render(ticket({ total = 7, start_at = 5 }), { now = NOW })
  eq(vim.list_slice(lines, 5, 9), {
    "before the final attempt.",
    "",
    "5 of 7 comments not shown; " .. render.WEB_HINT,
    "",
    "ana   3 days ago",
  })
  eq(lines[#lines], "Fix is in review.")
  eq(regions[1].last_line, 5)
  eq(regions[2].first_line, 10, "the notice sits between the body and the first comment")
  -- A page from the middle of the thread: some missing at each end, and
  -- each end says how many lie there.
  lines = render.render(ticket({ total = 7, start_at = 2 }), { now = NOW })
  eq(lines[7], "2 of 7 comments not shown; " .. render.WEB_HINT)
  eq(lines[#lines], "3 of 7 comments not shown; " .. render.WEB_HINT)
  eq(lines[#lines - 2], "Fix is in review.")
  -- start_at past the whole gap: everything missing lies before.
  lines = render.render(ticket({ total = 7, start_at = 9 }), { now = NOW })
  eq(lines[7], "5 of 7 comments not shown; " .. render.WEB_HINT)
  eq(lines[#lines], "Fix is in review.")
  -- No comment given at all: one notice after the body, whatever start_at.
  lines, regions = render.render(ticket({ comments = {}, total = 4, start_at = 2 }), { now = NOW })
  eq(vim.list_slice(lines, 5), { "before the final attempt.", "", "4 of 4 comments not shown; " .. render.WEB_HINT })
  eq(#regions, 1)
  -- The noun agrees with the thread's size: a thread of one that arrived
  -- empty is one comment.
  lines = render.render(ticket({ comments = {}, total = 1 }), { now = NOW })
  eq(lines[#lines], "1 of 1 comment not shown; " .. render.WEB_HINT)
  lines = render.render(ticket({ total = 2 }), { now = NOW })
  eq(lines[#lines], "Fix is in review.")
end)

test("render: an author line carries the timestamp it has, and the name alone without one", function()
  local it = ticket({
    comments = {
      { id = 10001, author = { id = "acc-ana", name = "ana" }, updated = "2024-04-30T12:00:00Z", body = doc(paragraph(text("x"))) },
      { id = 10002, author = { id = "acc-ana", name = "ana" }, body = doc(paragraph(text("y"))) },
    },
    total = 2,
  })
  local lines = render.render(it, { now = NOW })
  eq(lines[7], "ana   3 days ago", "updated stands in for created")
  eq(lines[10], "ana", "no timestamp at all: the name, with no trailing separator")
end)

test("render: a timestamp that does not parse is shown as given", function()
  local lines = render.render(ticket({ updated = "a while back" }), { now = NOW })
  eq(lines[1], "PROJ-142   In Progress   me   updated a while back")
end)

-- A merge request as the glab adapter hands it over: bodies are markdown
-- strings, and identities are usernames on both sides of the ownership test.
local function merge_request(overrides)
  local fields = {
    source = "glab",
    id = "!482",
    title = "Bump the pinned acli",
    state = "opened",
    assignee = { id = "me", name = "Me Myself" },
    updated = "2024-05-03T10:00:00.000Z",
    body = "Bumps the pin to 1.3.36.\n\n- moves the digest\n- reruns the matrix",
    comments = {
      { id = "9001", author = { id = "ana", name = "Ana" }, created = "2024-04-30T12:00:00.000Z", body = "Looks **good** to me." },
      { id = "9002", author = { id = "me", name = "Me Myself" }, created = "2024-05-02T09:00:00.000Z", body = "Thanks.\nMerging once green." },
    },
    total = 2,
    me = "me",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  return item.new(fields)
end

test("render: a markdown body is its own lines, breaks kept, and editable as it stands", function()
  local lines, regions = render.render(merge_request(), { now = NOW })
  eq(lines, {
    "!482   opened   me   updated 2h ago",
    "# Bump the pinned acli",
    "",
    "Bumps the pin to 1.3.36.",
    "",
    "- moves the digest",
    "- reruns the matrix",
    "",
    "Ana   3 days ago",
    "Looks **good** to me.",
    "",
    "me   yesterday",
    "Thanks.",
    "Merging once green.",
  })
  eq(regions[1].lines, { "Bumps the pin to 1.3.36.", "", "- moves the digest", "- reruns the matrix" })
  eq(regions[1].editable, true)
  eq(regions[1].reason, nil, "a string carries no node to refuse")
  eq(regions[2].editable, false)
  eq(regions[2].reason, "written by Ana; " .. render.WEB_HINT, "ownership still applies, by username")
  eq(regions[3].editable, true)
  eq(regions[3].reason, nil)
  eq(regions[3].lines, { "Thanks.", "Merging once green." })
  for _, region in ipairs(regions) do
    eq(vim.list_slice(lines, region.first_line, region.last_line), region.lines, region.id .. " range matches its lines")
  end
  -- The empty description GitLab returns as "" is one blank line to type into.
  local _, empty = render.render(merge_request({ body = "" }), { now = NOW })
  eq(empty[1].lines, { "" })
  eq(empty[1].editable, true)
  -- A body written with CRLF line ends shows no carriage returns.
  local _, crlf = render.render(merge_request({ body = "one\r\ntwo\r\n" }), { now = NOW })
  eq(crlf[1].lines, { "one", "two", "" })
end)

test("render: markdown naming a document node is text, and a tree still takes the adf path", function()
  local _, regions = render.render(merge_request({ body = "A `paragraph` with a mention, a codeBlock and a table." }), { now = NOW })
  eq(regions[1].lines, { "A `paragraph` with a mention, a codeBlock and a table." })
  eq(regions[1].editable, true)
  eq(regions[1].reason, nil)
  -- The same words as a Jira tree carrying a mention node are read-only.
  local _, jira = render.render(
    ticket({ body = doc(paragraph(text("A paragraph with "), { type = "mention", attrs = { id = "acc-ana", text = "@ana" } })) }),
    { now = NOW }
  )
  eq(jira[1].lines, { "A paragraph with @ana" }, "a tree renders through adf")
  eq(jira[1].editable, false)
  eq(jira[1].reason, "carries a mention node, which a write would replace by its flattened text; " .. render.WEB_HINT)
end)

test("render: a merge request's regions feed the compare, and an edit is one update", function()
  local _, regions = render.render(merge_request(), { now = NOW })
  local snap, current = { regions = {} }, {}
  for _, region in ipairs(regions) do
    snap.regions[region.id] = region
    current[region.id] = { lines = vim.deepcopy(region.lines) }
  end
  eq(diff.plan(snap, current), { calls = {}, skipped = {}, refused = {} }, "unedited, nothing is sent")
  current.body.lines = { "Bumps the pin to 1.3.37.", "", "- moves the digest", "- reruns the matrix" }
  eq(diff.plan(snap, current), {
    calls = { { kind = diff.BODY_UPDATE, id = "body", text = "Bumps the pin to 1.3.37.\n\n- moves the digest\n- reruns the matrix" } },
    skipped = {},
    refused = {},
  })
  current.body.lines = vim.deepcopy(regions[1].lines)
  current["9002"].lines = { "Thanks.", "Merged." }
  eq(diff.plan(snap, current).calls, { { kind = diff.COMMENT_UPDATE, id = "9002", text = "Thanks.\nMerged." } })
  current["9001"].lines = { "Looks bad." }
  eq(diff.plan(snap, current).refused, { { id = "9001", reason = "written by Ana; " .. render.WEB_HINT } })
end)

-- the adapter contract ---------------------------------------------------------------------

-- A function of exactly that many parameters, since verify() holds each call
-- to the arity the contract gives it.
local function taking(count)
  local params = {}
  for index = 1, count do
    params[index] = "p" .. index
  end
  return assert(load(("return function(%s) end"):format(table.concat(params, ", "))))()
end

-- An adapter carrying every required call at its arity and no capability, to vary.
local function bare_adapter()
  local adapter = { capabilities = {} }
  for _, name in ipairs(adapters.REQUIRED) do
    adapter[name] = taking(adapters.ARITY[name])
  end
  return adapter
end

test("adapters: a module missing a required call is refused, naming it", function()
  local adapter = bare_adapter()
  adapter.whoami = nil
  adapter.token_url = nil
  adapter.project_of = nil
  local ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("required call whoami is missing", 1, true) ~= nil, true, err)
  eq(err:find("required call token_url is missing", 1, true) ~= nil, true, "every shortfall is named: " .. err)
  -- The dash calls project_of() on every row a key takes, without checking
  -- for it, so an adapter without it has to fail here rather than there.
  eq(err:find("required call project_of is missing", 1, true) ~= nil, true, err)
  eq({ adapters.verify(bare_adapter(), "x") }, { true }, "the required calls alone are a valid adapter")
end)

test("adapters: a capability is refused when declared and not implemented, or implemented and not declared", function()
  local adapter = bare_adapter()
  adapter.capabilities = { "states" }
  local ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("capability states is declared and not implemented", 1, true) ~= nil, true, err)
  adapter = bare_adapter()
  adapter.states = function() end
  ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("states is implemented and not declared", 1, true) ~= nil, true, err)
  adapter = bare_adapter()
  adapter.capabilities = { "teleport" }
  ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("capability teleport is not one the contract names", 1, true) ~= nil, true, err)
  adapter = bare_adapter()
  adapter.capabilities = { "states" }
  adapter.states = taking(2)
  eq({ adapters.verify(adapter, "x") }, { true })
  eq(adapters.can(adapter, "states"), true)
  eq(adapters.can(adapter, "diff"), false)
end)

test("adapters: a call of the wrong arity is refused, and a vararg one is not held to a count", function()
  local adapter = bare_adapter()
  adapter.rows = taking(1)
  local ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("rows takes 1 parameters and the contract gives it 2", 1, true) ~= nil, true, err)
  adapter = bare_adapter()
  adapter.capabilities = { "comment_update" }
  adapter.comment_update = taking(3)
  ok, err = adapters.verify(adapter, "x")
  eq(ok, false)
  eq(err:find("comment_update takes 3 parameters and the contract gives it 4", 1, true) ~= nil, true, err)
  adapter = bare_adapter()
  adapter.rows = function(...)
    return ...
  end
  eq({ adapters.verify(adapter, "x") }, { true }, "a vararg function's count says nothing")
  -- A contract name with no arity is a shortfall in the message, not a raise:
  -- get() runs verify() outside its pcall, so a raise would reach auth.ready.
  adapter = bare_adapter()
  local saved_arity = adapters.ARITY.url
  adapters.ARITY.url = nil
  ok, err = adapters.verify(adapter, "x")
  adapters.ARITY.url = saved_arity
  eq(ok, false)
  eq(err, "adapter x: url is in the contract with no arity, so nothing holds it to one")
  for _, name in ipairs(adapters.REQUIRED) do
    eq(type(adapters.ARITY[name]), "number", name .. " has an arity")
  end
  for _, name in ipairs(adapters.OPTIONAL) do
    eq(type(adapters.ARITY[name]), "number", name .. " has an arity")
  end
end)

test("adapters: a handoff is the name of a plugin or absent", function()
  local adapter = bare_adapter()
  adapter.handoff = "octo.nvim"
  eq({ adapters.verify(adapter, "x") }, { true })
  for _, odd in ipairs({ true, "", 1, {} }) do
    adapter.handoff = odd
    local ok, err = adapters.verify(adapter, "x")
    eq(ok, false, vim.inspect(odd))
    eq(err, ("adapter x: handoff is %s rather than the name of the plugin an item opens in"):format(vim.inspect(odd)))
  end
  eq(gh.handoff, "octo.nvim")
  eq({ jira.handoff, glab.handoff }, {}, "the adapters that render their own items name none")
end)

test("adapters: the registry verifies a module on load and does not keep one that fails", function()
  -- A registry of its own, which holds no module an earlier test loaded
  -- through the shared one, so the stub below is what it loads.
  local saved_registry, saved_gh = package.loaded["docket.adapters"], package.loaded["docket.adapters.gh"]
  package.loaded["docket.adapters"] = nil
  local registry = require("docket.adapters")
  package.loaded["docket.adapters"] = saved_registry
  local incomplete = bare_adapter()
  incomplete.whoami = nil
  package.loaded["docket.adapters.gh"] = incomplete
  local adapter, err = registry.get("gh")
  local again, err_again = registry.get("gh")
  package.loaded["docket.adapters.gh"] = saved_gh
  eq(adapter, nil)
  eq(err:find("adapter gh: required call whoami is missing", 1, true) ~= nil, true, err)
  eq(again, nil)
  eq(err_again, err, "a module that failed is asked for afresh, not cached")
end)

test("adapters: the calls a save makes are capabilities, and jira passes the contract", function()
  local named = {}
  for _, name in ipairs(adapters.OPTIONAL) do
    named[name] = true
  end
  for _, call in ipairs({ diff.BODY_UPDATE, diff.COMMENT_UPDATE, diff.COMMENT_CREATE }) do
    eq(named[call], true, call)
  end
  eq({ adapters.verify(jira, "jira") }, { true })
  eq(adapters.get("jira"), jira, "the registry hands back the module")
  local adapter, err = adapters.get("svn")
  eq(adapter, nil)
  eq(err:find("jira, glab, gh", 1, true) ~= nil, true, "the refusal names the adapters: " .. err)
end)

-- the jira adapter -------------------------------------------------------------------------

local ACLI = { "acli", "jira" }

local function argv_of(...)
  return vim.list_extend(vim.deepcopy(ACLI), { ... })
end

local function done(argv, payload)
  local stdout = type(payload) == "string" and payload or vim.json.encode(payload)
  return { argv = argv, ok = true, code = 0, stdout = stdout, stderr = "", timed_out = false }
end

local function failed(argv, code, stderr)
  return { argv = argv, ok = false, code = code, stdout = "", stderr = stderr, timed_out = false }
end

-- Replaces spawn.run with one that records every call and answers each from
-- `answer(argv, opts)` before run returns. Returns the calls and the restore.
local function stub_run(answer)
  local calls, saved = {}, spawn.run
  spawn.run = function(argv, opts, on_done)
    calls[#calls + 1] = { argv = argv, opts = opts }
    on_done(answer(argv, opts))
    return nil
  end
  return calls, function()
    spawn.run = saved
  end
end

-- stub_run with the answer delivered from a libuv timer instead, which is the
-- fast-event context vim.system's own callback runs in: a vim.fn call or a
-- buffer change reached from there raises E5560 in the editor, and under
-- stub_run it would pass. A test using it waits with vim.wait.
local function stub_run_fast(answer)
  local calls, saved = {}, spawn.run
  spawn.run = function(argv, opts, on_done)
    calls[#calls + 1] = { argv = argv, opts = opts }
    local timer = vim.uv.new_timer()
    timer:start(0, 0, function()
      timer:close()
      on_done(answer(argv, opts))
    end)
  end
  return calls, function()
    spawn.run = saved
  end
end

local function stub_wait(answer)
  local calls, saved = {}, spawn.wait
  spawn.wait = function(argv, opts)
    calls[#calls + 1] = { argv = argv, opts = opts }
    return answer(argv, opts)
  end
  return calls, function()
    spawn.wait = saved
  end
end

local function jql_of(argv)
  for index, word in ipairs(argv) do
    if word == "--jql" then
      return argv[index + 1]
    end
  end
  return nil
end

local function has(argv, word)
  for _, given in ipairs(argv) do
    if given == word then
      return true
    end
  end
  return false
end

local function user(id, name)
  return {
    accountId = id,
    accountType = "atlassian",
    active = true,
    avatarUrls = vim.empty_dict(),
    displayName = name,
    self = "https://example.atlassian.net/rest/api/3/user?accountId=" .. id,
    timeZone = "Europe/Lisbon",
  }
end

-- A search row as acli prints one: the key, the fields asked for.
local function found(key, fields)
  return { id = "1" .. key:match("%d+$"), key = key, self = "https://example.atlassian.net/rest/api/3/issue/1" .. key:match("%d+$"), fields = fields }
end

-- A comment as `view --fields comment` returns one: `author`, `body`,
-- `created`, `id`, `jsdPublic`, `self`, `updateAuthor`, `updated`. The
-- update author is somebody else on purpose, since the adapter must judge
-- ownership by `author` alone.
local function comment(id, author, created, body)
  return {
    author = author,
    body = body,
    created = created,
    id = id,
    jsdPublic = true,
    self = "https://example.atlassian.net/rest/api/3/issue/11001/comment/" .. id,
    updateAuthor = user("acc-bot", "Automation"),
    updated = created:gsub("T10", "T11"),
  }
end

-- The `view` payload as phase 0 recorded it: the top-level keys, `fields`
-- holding what was asked for, `description` a document, `comment` a page
-- with `startAt`, `maxResults` and `total`.
local function view_payload()
  return {
    changelog = vim.NIL,
    editmeta = vim.NIL,
    expand = "renderedFields,names,schema,operations,editmeta,changelog,versionedRepresentations",
    fields = {
      summary = "Retry backoff drops the last attempt",
      status = { name = "In Progress", statusCategory = { key = "indeterminate", name = "In Progress" } },
      assignee = vim.tbl_extend("force", user("acc-me", "Me Myself"), { emailAddress = "me@example.test" }),
      reporter = user("acc-ana", "Ana"),
      updated = "2024-05-03T10:00:00.000+0000",
      description = doc(paragraph(text("The retry loop re-enters"), { type = "hardBreak" }, text("before the final attempt."))),
      comment = {
        comments = {
          comment("10001", user("acc-ana", "Ana"), "2024-04-30T10:00:00.000+0000", doc(paragraph(text("Repros on staging.")))),
          comment("10002", user("acc-me", "Me Myself"), "2024-05-02T10:00:00.000+0000", doc(paragraph(text("Fix is in review.")))),
        },
        maxResults = 14,
        self = "https://example.atlassian.net/rest/api/3/issue/11001/comment",
        startAt = 0,
        total = 5,
      },
    },
    fieldsToInclude = vim.NIL,
    id = "11001",
    key = "TIG-1001",
    names = vim.NIL,
    operations = vim.NIL,
    properties = vim.NIL,
    renderedFields = vim.NIL,
    schema = vim.NIL,
    self = "https://example.atlassian.net/rest/api/3/issue/11001",
    transitions = vim.NIL,
  }
end

-- The names `acli jira workitem search --fields` takes are a list of acli's
-- own, which neither its help nor Atlassian's reference prints, and a name
-- outside it is refused: `comment` as `field 'comment' is not allowed`, and
-- `updated` on the pinned 1.3.36 with a refusal whose exact wording was not
-- captured. The one list documented is search's default, printed by `acli
-- jira workitem search --help`, so every search the adapter runs is held to
-- these names.
local SEARCH_FIELDS = { issuetype = true, key = true, assignee = true, priority = true, status = true, summary = true }

-- What a section's search asks for per row, spelled out rather than read off
-- jira.ROW_FIELDS: a name added there that search refuses, or dropped while
-- rows() still reads it, is the defect, and an assertion that reads the list
-- cannot see either.
local JIRA_FIELDS = "key,summary,status"

-- The value after `--fields` in an argument list, or nil.
local function fields_of(argv)
  for index, word in ipairs(argv) do
    if word == "--fields" then
      return argv[index + 1]
    end
  end
  return nil
end

local ASSIGNEE_QUERY = argv_of("workitem", "search", "--jql", "assignee = currentUser()", "--json", "--fields", "assignee")
local REPORTER_QUERY = argv_of("workitem", "search", "--jql", "reporter = currentUser()", "--json", "--fields", "key")
local REPORTER_VIEW = argv_of("workitem", "view", "TIG-7", "--fields", "reporter", "--json")

-- An abridged answer to `view <KEY> --fields reporter --json`: `id`, `key`,
-- `self`, and `fields` holding the reporter alone. view_payload() has the
-- full set of top-level keys `view` prints.
local function reporter_payload(key, reporter)
  return { id = "1" .. key:match("%d+$"), key = key, self = "https://example.atlassian.net/rest/api/3/issue/1" .. key:match("%d+$"), fields = { reporter = reporter } }
end

test("jira: whoami falls back to a reported work item's reporter through view, and then answers without asking again", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if argv[4] == "view" then
      return done(argv, reporter_payload(argv[5], user("acc-me", "Me Myself")))
    end
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    -- The row carries what `--fields key` returns and no reporter, so the
    -- identifier has to come from the view.
    return done(argv, { found("TIG-7", {}) })
  end)
  local answers = {}
  jira.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  jira.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  restore()
  eq(answers, { { "acc-me" }, { "acc-me" } })
  eq(#calls, 3, "two searches and a view for the first answer, none for the second")
  eq(calls[1].argv, ASSIGNEE_QUERY)
  eq(calls[2].argv, REPORTER_QUERY)
  eq(calls[3].argv, REPORTER_VIEW)
  eq(has(calls[1].argv, "--paginate"), false, "the first page is enough")
  eq(has(calls[2].argv, "--paginate"), false, "and one key is enough")
end)

test("jira: whoami with nothing assigned or reported says to assign one work item, and asks again next time", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    return done(argv, {})
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  eq(got[1], nil)
  eq(got[2]:find("Assign it one work item", 1, true) ~= nil, true, got[2])
  jira.whoami(function() end)
  restore()
  eq(#calls, 4, "an empty answer is not remembered")
  for _, call in ipairs(calls) do
    eq(call.argv[4], "search", "no key to view, so no view: " .. table.concat(call.argv, " "))
  end
end)

test("jira: whoami views no reported key outside a work item key's shape, and names the first", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    -- A key Jira Data Center's configurable pattern allows and KEY does not.
    return done(argv, { found("MY_PROJ-3", {}) })
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got[1], nil)
  eq(#calls, 2, "no view: " .. table.concat(calls[#calls].argv, " "))
  eq(got[2]:find("no work item it reported has a key of the shape PROJ-123, the first being MY_PROJ-3", 1, true) ~= nil, true, got[2])
  eq(got[2]:find("Assign it one work item", 1, true) ~= nil, true, got[2])
end)

test("jira: whoami reports a view that prints no JSON with the key it read and the decode error", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    if argv[4] == "view" then
      return done(argv, "not json")
    end
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    return done(argv, { found("TIG-7", {}) })
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got[1], nil)
  eq(got[2]:find("reading the reporter of TIG-7, a work item it reported, failed\n", 1, true) ~= nil, true, got[2])
  eq(got[2]:find("output is not JSON", 1, true) ~= nil, true, got[2])
end)

test("jira: whoami reports a failed reporter search with acli's own words and views nothing", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    return failed(argv, 1, "Error: JQL is invalid")
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got, { nil, "acli exited 1\nError: JQL is invalid" })
  eq(#calls, 2)
end)

test("jira: whoami reports a failed view with acli's own words, and a view printing no reporter with the command to run, and asks again after either", function()
  jira.forget()
  local views = 0
  local calls, restore = stub_run(function(argv)
    if argv[4] == "view" then
      views = views + 1
      if views == 1 then
        return failed(argv, 1, "Error: work item TIG-7 does not exist")
      end
      return done(argv, reporter_payload(argv[5], vim.NIL))
    end
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    return done(argv, { found("TIG-7", { summary = "Seven" }) })
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  eq(got, {
    nil,
    "the account's own identifier is unknown: reading the reporter of TIG-7, a work item it reported, failed\nacli exited 1\nError: work item TIG-7 does not exist",
  })
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(#calls, 6, "neither answer was remembered, so the second call searched and viewed again")
  eq(got[1], nil)
  eq(got[2]:find("view TIG-7 printed no reporter carrying an accountId", 1, true) ~= nil, true, got[2])
  eq(got[2]:match("\n  (.-)\n"), "acli jira workitem view TIG-7 --fields reporter --json", "the line to paste")
end)

test("jira: every search names --fields from search's default list, ROW_FIELDS among them, and so does the search a create prints", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if argv[4] == "view" then
      return done(argv, reporter_payload(argv[5], user("acc-me", "Me Myself")))
    end
    if argv[4] == "create" then
      return done(argv, "Created TIG-48 and TIG-49")
    end
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, {})
    end
    return done(argv, { found("TIG-7", { summary = "Seven", status = { name = "To Do" } }) })
  end)
  jira.rows({ query = "project = TIG" }, function() end)
  jira.whoami(function() end)
  jira.states("TIG-7", function() end)
  local printed
  jira.item_create({ project = "TIG", type = "Task", summary = "Probe" }, "", function(_, err)
    printed = err
  end)
  restore()
  local function held(fields, where)
    eq(type(fields), "string", "--fields is passed: " .. where)
    for _, name in ipairs(vim.split(fields, ",", { plain = true })) do
      eq(SEARCH_FIELDS[name], true, ("%s is outside search's default list: %s"):format(name, where))
    end
  end
  held(jira.ROW_FIELDS, "jira.ROW_FIELDS")
  local searched = {}
  for _, call in ipairs(calls) do
    if call.argv[4] == "search" then
      searched[#searched + 1] = jql_of(call.argv)
      held(fields_of(call.argv), table.concat(call.argv, " "))
    end
  end
  table.sort(searched)
  -- Every search site in the adapter ran: rows(), both of whoami()'s, and
  -- states(). A site added to the adapter is added here too, or it is not held.
  eq(searched, {
    "assignee = currentUser()",
    "project = TIG",
    "project = TIG ORDER BY updated DESC",
    "reporter = currentUser()",
  })
  local line = printed:match("\n  (acli jira workitem search [^\n]*)")
  eq(type(line), "string", "the create's report names the search to run by hand: " .. printed)
  held(line:match("%-%-fields (%S+)"), line)
end)

test("jira: whoami reports a failed search with acli's own words, and joins callers during one query", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    return failed(argv, 1, "Error: not authenticated")
  end)
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got, { nil, "acli exited 1\nError: not authenticated" })

  -- Two callers while the search is in flight make one search.
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local answers = {}
  jira.whoami(function(id)
    answers[#answers + 1] = id
  end)
  jira.whoami(function(id)
    answers[#answers + 1] = id
  end)
  eq(#pending, 1, "one search in flight")
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) }))
  spawn.run = saved
  eq(answers, { "acc-me", "acc-me" })
end)

test("jira: a whoami answer landing after a login is not remembered as the new account's", function()
  -- spawn.wait pumps the event loop, and so do the login flow's prompts, so a
  -- search started before the login settles inside it, after forget().
  jira.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  local _, restore_wait = stub_wait(function(argv)
    -- The old account's search answers while the login blocks.
    local search = table.remove(pending, 1)
    search.on_done(done(search.argv, { found("TIG-7", { assignee = user("acc-OLD-ACCOUNT", "Old") }) }))
    return done(argv, "")
  end)
  jira.auth_login("tok", { site = "example.atlassian.net", email = "new@example.test" })
  restore_wait()
  eq(got[1], nil)
  eq(got[2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, got[2])
  jira.whoami(function() end)
  eq(#pending, 1, "nothing was remembered: the next whoami searches again")
  eq(jql_of(pending[1].argv), "assignee = currentUser()")
  -- Answered, so no query is left in flight for the tests after this one.
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) }))
  spawn.run = saved
end)

test("jira: a caller asking after a login starts its own query, and the stale one changes nothing", function()
  jira.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local before
  jira.whoami(function(id, err)
    before = { id, err }
  end)
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  -- The old account's search is still running when the login returns.
  jira.auth_login("tok", { site = "example.atlassian.net", email = "new@example.test" })
  restore_wait()
  local after
  jira.whoami(function(id, err)
    after = { id, err }
  end)
  eq(#pending, 2, "the caller after the login does not join the stale query")
  eq(after, nil, "and waits on its own")
  pending[2].on_done(done(pending[2].argv, { found("TIG-7", { assignee = user("acc-NEW", "New") }) }))
  eq(after, { "acc-NEW" }, "answered from its own query")
  eq(before, nil, "the stale query has not exited yet")
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-OLD", "Old") }) }))
  eq(before[1], nil)
  eq(before[2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, before[2])
  local again
  jira.whoami(function(id)
    again = id
  end)
  spawn.run = saved
  eq(again, "acc-NEW", "the stale exit changed nothing")
  eq(#pending, 2, "and nothing was asked again")
end)

test("jira: a login the client refuses still drops the identity and refuses the query in flight", function()
  jira.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  jira.whoami(function(id, err)
    got = { id, err }
  end)
  local _, restore_wait = stub_wait(function(argv)
    -- The search answers while the login blocks, as it does on a login that
    -- succeeds: the flow runs the same way up to the client's verdict.
    local search = table.remove(pending, 1)
    search.on_done(done(search.argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) }))
    return failed(argv, 1, "Error: Invalid token")
  end)
  local result = jira.auth_login("bad", { site = "example.atlassian.net", email = "me@example.test" })
  restore_wait()
  eq(result.ok, false)
  eq(got[1], nil, "the answer is not handed on")
  -- Nobody signed in and the account that was signed in still is, so the
  -- refusal says a login ran rather than that an account replaced another.
  eq(got[2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, got[2])
  eq(got[2]:find("may be the account that signed out", 1, true) ~= nil, true, got[2])
  jira.whoami(function() end)
  eq(#pending, 1, "the identity was dropped whatever the client answered, so the next whoami asks again")
  -- Answered, so no query is left in flight for the tests after this one.
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) }))
  spawn.run = saved
end)

test("jira: each query owns its waiters, so a stale settle answers its own caller and leaves the fresh list alone", function()
  jira.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  -- Every answer a caller is given is recorded, so a caller answered twice is
  -- told apart from one answered once.
  local answers = { {}, {}, {}, {} }
  local function ask(index)
    jira.whoami(function(id, err)
      answers[index][#answers[index] + 1] = { id, err }
    end)
  end
  ask(1)
  eq(#pending, 1, "the first caller starts a query")
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  jira.auth_login("tok", { site = "example.atlassian.net", email = "new@example.test" })
  restore_wait()
  ask(2)
  eq(#pending, 2, "the caller after the login starts its own query")
  ask(3)
  eq(#pending, 2, "and the next one joins that query")
  -- The stale query settles into a slot the fresh one now holds.
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-old", "Old") }) }))
  eq(#answers[1], 1, "its own caller is answered once")
  eq(answers[1][1][1], nil)
  eq(answers[1][1][2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, answers[1][1][2])
  eq(answers[2], {}, "and the fresh query's callers are left for its own settle")
  eq(answers[3], {})
  ask(4)
  eq(#pending, 2, "the stale settle left the fresh slot in place, so a later caller joins it too")
  pending[2].on_done(done(pending[2].argv, { found("TIG-7", { assignee = user("acc-new", "New") }) }))
  spawn.run = saved
  eq(answers[2], { { "acc-new" } }, "each caller of the fresh query is answered exactly once")
  eq(answers[3], { { "acc-new" } })
  eq(answers[4], { { "acc-new" } })
  eq(#answers[1], 1, "and the stale caller is not answered again")
end)

test("jira: a section that answers after a login is not shown, and its keys and site are not remembered", function()
  jira.forget()
  local pending, saved = {}, spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  jira.rows({ title = "Mine", query = "project = OLD" }, function(rows, err)
    got = { rows, err }
  end)
  jira.forget()
  pending[1].on_done(done(pending[1].argv, { found("OLD-1", { summary = "One", status = { name = "To Do" } }) }))
  spawn.run = saved
  eq(got, { nil, "jira: a login ran while this section was in flight, so its rows are not shown; refresh to ask again" })
  eq(jira.complete("item", "OLD"), {}, "the previous account's keys are not offered")
  eq(jira.url({ id = "OLD-1" }), nil, "nor is its site read off the rows")
end)

test("jira: an item read across a login opens with no identity and the reason, and its site is not read off it", function()
  jira.forget()
  local pending, saved = {}, spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  jira.item("TIG-1001", function(it, err, me_err)
    got = { it, err, me_err }
  end)
  -- The identity answers under the account signing out, and the login runs
  -- before `view` lands.
  pending[1].on_done(done(pending[1].argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) }))
  jira.forget()
  pending[2].on_done(done(pending[2].argv, view_payload()))
  spawn.run = saved
  eq(got[2], nil, "the item still opens")
  eq(got[1].me, nil)
  eq(got[3], "a login ran while the item was read; open it again")
  eq(got[1].url, nil, "the site is the new account's to name")
  eq(item.regions(got[1])[3].editable, false, "the comment the previous account wrote is not offered for editing")
end)

test("jira: the item is built from the view payload, thread and identity included", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local got, got_err
  jira.item("TIG-1001", function(it, err)
    got, got_err = it, err
  end)
  -- The identity is not asked for again.
  jira.item("TIG-1001", function() end)
  restore()
  eq(#calls, 3, "the second open is one view call")
  eq(got_err, nil)
  eq(calls[2].argv, argv_of("workitem", "view", "TIG-1001", "--fields", jira.VIEW_FIELDS, "--json"))
  eq(jira.VIEW_FIELDS, "summary,status,assignee,reporter,updated,description,comment")
  eq(got.id, "TIG-1001")
  eq(got.title, "Retry backoff drops the last attempt")
  eq(got.state, "In Progress")
  eq(got.assignee, { id = "acc-me", name = "Me Myself" })
  eq(got.reporter, { id = "acc-ana", name = "Ana" })
  eq(got.updated, "2024-05-03T10:00:00.000+0000")
  eq(got.body, view_payload().fields.description)
  eq(got.me, "acc-me")
  eq(#got.comments, 2)
  eq(got.comments[1].id, "10001")
  eq(got.comments[1].author, { id = "acc-ana", name = "Ana" }, "accountId and displayName, as item.new takes them")
  eq(got.comments[2].author, { id = "acc-me", name = "Me Myself" }, "the author, never updateAuthor: Jira grants edit rights by author")
  eq(got.comments[1].created, "2024-04-30T10:00:00.000+0000", "a comment read through view carries created")
  eq(got.comments[1].updated, "2024-04-30T11:00:00.000+0000", "and updated, which the conflict check compares")
  eq(got.comments[1].body, view_payload().fields.comment.comments[1].body)
  eq(got.total, 5)
  eq(got.start_at, 0)
  eq(got.missing, 3)
  eq(got.url, "https://example.atlassian.net/browse/TIG-1001", "the site is read off the payload's self")
  -- The item renders, and the ownership test is accountId against accountId.
  local lines, regions = render.render(got, { now = NOW })
  eq(lines[1], "TIG-1001   In Progress   me   updated 2h ago")
  eq(regions[2].editable, false)
  eq(regions[2].reason, "written by Ana; " .. render.WEB_HINT)
  eq(regions[3].editable, true)
  eq(lines[#lines], "3 of 5 comments not shown; " .. render.WEB_HINT)
end)

test("jira: a page from the middle of a thread keeps its offset, and the notice lands at each end", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    local payload = view_payload()
    payload.fields.comment.startAt = 4
    payload.fields.comment.total = 9
    return done(argv, payload)
  end)
  local got
  jira.item("TIG-1001", function(it)
    got = it
  end)
  restore()
  eq(got.start_at, 4)
  eq(got.total, 9)
  eq(got.missing, 7)
  local lines = render.render(got, { now = NOW })
  local notices = vim.tbl_filter(function(line)
    return line:find("comments not shown", 1, true) ~= nil
  end, lines)
  eq(notices, { "4 of 9 comments not shown; " .. render.WEB_HINT, "3 of 9 comments not shown; " .. render.WEB_HINT })
  eq(lines[#lines], notices[2], "the newer ones are missing after the page")
end)

test("jira: an item still opens when the identity is unknown, with the reason beside it", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, {})
    end
    return done(argv, view_payload())
  end)
  local got, got_err, got_me_err
  jira.item("TIG-1001", function(it, err, me_err)
    got, got_err, got_me_err = it, err, me_err
  end)
  restore()
  eq(got_err, nil)
  eq(got.me, nil)
  eq(got_me_err:find("Assign it one work item", 1, true) ~= nil, true, got_me_err)
  local regions = item.regions(got)
  eq(regions[2].editable, false)
  eq(regions[3].editable, false, "the own comment too, for want of an ownership test")
end)

test("jira: a failed view and a payload with no fields are each reported", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    if argv[5] == "TIG-404" then
      return failed(argv, 1, "Error: Issue does not exist or you do not have permission to see it.")
    end
    return done(argv, "null")
  end)
  local got, got_err
  jira.item("TIG-404", function(it, err)
    got, got_err = it, err
  end)
  eq(got, nil)
  eq(got_err, "acli exited 1\nError: Issue does not exist or you do not have permission to see it.")
  jira.item("TIG-1", function(it, err)
    got, got_err = it, err
  end)
  restore()
  eq(got, nil)
  eq(got_err:find("no `fields` object", 1, true) ~= nil, true, got_err)
end)

-- The document file a write hands acli, read while it exists: the stub reads
-- it before answering, and the adapter removes it once the call is done.
local function read_document(argv, flag)
  for index, word in ipairs(argv) do
    if word == flag then
      local path = argv[index + 1]
      local handle = assert(io.open(path, "r"))
      local content = handle:read("a")
      handle:close()
      return path, vim.json.decode(content)
    end
  end
  return nil, nil
end

test("jira: a comment is created as a document through --body-file, never as text", function()
  local path, written
  local calls, restore = stub_run(function(argv)
    path, written = read_document(argv, "--body-file")
    return done(argv, { results = {}, successCount = 1, totalCount = 1 })
  end)
  local got
  jira.comment_create("TIG-1001", "one\ntwo\n\nthree", function(ok, err)
    got = { ok, err }
  end)
  restore()
  eq(got, { true })
  eq(vim.list_slice(calls[1].argv, 1, 8), argv_of("workitem", "comment", "create", "--key", "TIG-1001", "--json"))
  eq(written, adf.serialise("one\ntwo\n\nthree"), "the file holds the serialised tree")
  eq(has(calls[1].argv, "one\ntwo\n\nthree"), false, "the text is in no argument")
  eq(vim.uv.fs_stat(path), nil, "the file is removed once acli has exited")
end)

test("jira: a comment update goes through --body-adf and a body update through --description-file --yes", function()
  local written_comment, written_body
  local calls, restore = stub_run(function(argv)
    if argv[5] == "update" then
      written_comment = select(2, read_document(argv, "--body-adf"))
    else
      written_body = select(2, read_document(argv, "--description-file"))
    end
    return done(argv, "")
  end)
  local outcomes = {}
  jira.comment_update("TIG-1001", "10002", "Fix is merged.", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  jira.body_update("TIG-1001", "A description at last.", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  restore()
  eq(outcomes, { { true }, { true } })
  eq(vim.list_slice(calls[1].argv, 1, 9), argv_of("workitem", "comment", "update", "--key", "TIG-1001", "--id", "10002"))
  eq(written_comment, adf.serialise("Fix is merged."))
  eq(vim.list_slice(calls[2].argv, 1, 8), argv_of("workitem", "edit", "--key", "TIG-1001", "--yes", "--json"))
  eq(written_body, adf.serialise("A description at last."))
end)

test("jira: a write that fails reports acli's words, and a bulk summary with no success is a failure", function()
  local _, restore = stub_run(function(argv)
    if argv[5] == "create" then
      return done(argv, { results = { { key = "TIG-1001", error = "comment body is required" } }, successCount = 0, totalCount = 1 })
    end
    return failed(argv, 1, "Error: field 'description' cannot be set")
  end)
  local outcomes = {}
  jira.comment_create("TIG-1001", "x", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  jira.body_update("TIG-1001", "x", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  restore()
  eq(outcomes, { { false, "TIG-1001: comment body is required" }, { false, "acli exited 1\nError: field 'description' cannot be set" } })
end)

test("jira: a structured Jira error in a bulk summary is flattened, never printed as a table address", function()
  local _, restore = stub_run(function(argv)
    return done(argv, {
      results = {
        {
          key = "TIG-1001",
          error = { errorMessages = { "Transition is not valid" }, errors = { resolution = "Resolution is required", summary = "too long" } },
        },
        { key = "TIG-1002", error = { code = 403 } },
      },
      successCount = 0,
      totalCount = 2,
    })
  end)
  local got
  jira.state_set("TIG-1001", "Done", function(ok, err)
    got = { ok, err }
  end)
  restore()
  eq(got[1], false)
  eq(got[2], "TIG-1001: Transition is not valid; resolution: Resolution is required; summary: too long\nTIG-1002: " .. vim.json.encode({ code = 403 }))
  eq(got[2]:find("table: 0x", 1, true), nil)
end)

test("jira: a document file left by a client killed with the editor is removed at VimLeavePre", function()
  local held
  local saved = spawn.run
  spawn.run = function(argv)
    for index, word in ipairs(argv) do
      if word == "--body-file" then
        held = argv[index + 1]
      end
    end
    -- The client never calls back.
  end
  jira.comment_create("TIG-1001", "left behind", function() end)
  spawn.run = saved
  eq(vim.uv.fs_stat(held) ~= nil, true, "the file exists while the client runs")
  eq(bit.band(vim.uv.fs_stat(held).mode, 511), 384, "created 0600, before anything opens it")
  -- The adapter registers the hook on vim.schedule, so that requiring it
  -- from a fast-event context works; one pump of the loop is what runs it.
  vim.wait(0)
  eq(#vim.api.nvim_get_autocmds({ group = "docket_jira_files", event = "VimLeavePre" }), 1)
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "docket_jira_files" })
  eq(vim.uv.fs_stat(held), nil, "removed on leaving")
end)

test("jira: a search that prints an unknown shape is refused with a command a shell accepts", function()
  local _, restore = stub_run(function(argv)
    return done(argv, { nextPageToken = "abc" })
  end)
  local got
  jira.rows({ query = "project IN (PAY, TIG) AND statusCategory != Done" }, function(rows, err)
    got = { rows, err }
  end)
  restore()
  eq(got[1], nil)
  eq(got[2]:find("neither a list nor an object holding `issues`", 1, true) ~= nil, true, got[2])
  local line = got[2]:match("\n  (.-)\n")
  eq(
    line,
    "acli jira workitem search --jql 'project IN (PAY, TIG) AND statusCategory != Done' --json --fields "
      .. JIRA_FIELDS
      .. " --paginate",
    "the JQL is quoted, so `(PAY,` opens no substitution in fish"
  )
end)

test("jira: a document that cannot be written is reported and its file removed", function()
  local before = vim.fn.glob(vim.uv.os_tmpdir() .. "/docket-*", false, true)
  local saved_write, saved_run = vim.uv.fs_write, spawn.run
  vim.uv.fs_write = function()
    return nil, "EIO: i/o error"
  end
  spawn.run = function()
    error("nothing runs without a document")
  end
  local got
  jira.comment_create("TIG-1001", "x", function(ok, err)
    got = { ok, err }
  end)
  vim.uv.fs_write, spawn.run = saved_write, saved_run
  eq(got[1], false)
  eq(got[2]:find("^cannot write .*docket%-.*: EIO") ~= nil, true, got[2])
  eq(vim.fn.glob(vim.uv.os_tmpdir() .. "/docket-*", false, true), before, "no file left behind")
end)

test("jira: a transition carries --yes, and a comment delete names the key and the id", function()
  local calls, restore = stub_run(function(argv)
    return done(argv, "")
  end)
  local outcomes = {}
  jira.state_set("TIG-1001", "In Review", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  jira.comment_delete("TIG-1001", "10002", function(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end)
  restore()
  eq(outcomes, { { true }, { true } })
  eq(calls[1].argv, argv_of("workitem", "transition", "--key", "TIG-1001", "--status", "In Review", "--yes", "--json"))
  eq(calls[2].argv, argv_of("workitem", "comment", "delete", "--key", "TIG-1001", "--id", "10002"))
end)

test("jira: states are the distinct statuses across the project's rows, sorted", function()
  local calls, restore = stub_run(function(argv)
    return done(argv, {
      found("TIG-1", { status = { name = "To Do" } }),
      found("TIG-2", { status = { name = "In Progress" } }),
      found("TIG-3", { status = { name = "To Do" } }),
      found("TIG-4", { status = { name = "Done" } }),
      found("TIG-5", {}),
    })
  end)
  local got
  jira.states("TIG-1001", function(states, err)
    got = { states, err }
  end)
  restore()
  eq(got[2], nil)
  eq(got[1], {
    { label = "Done", target = "Done" },
    { label = "In Progress", target = "In Progress" },
    { label = "To Do", target = "To Do" },
  })
  eq(
    calls[1].argv,
    argv_of("workitem", "search", "--jql", "project = TIG ORDER BY updated DESC", "--json", "--fields", "status"),
    "one page of recent rows carries the workflow's statuses, and `status` is what is read off them"
  )
end)

test("jira: states refuses an identifier that is not a key, because a query reaches acli as written", function()
  local calls, restore = stub_run(function(argv)
    return done(argv, {})
  end)
  local got
  for _, id in ipairs({ "x OR project = SECRET", "tig-1", "TIG", "PROJ-142abc", "A-1" }) do
    jira.states(id, function(states, err)
      got = { states, err }
    end)
    eq(got[1], nil, id)
    eq(got[2], ("%s is not a work item key, so its project is unknown"):format(id))
  end
  restore()
  eq(calls, {}, "nothing was searched")
  -- The shape is env.KEY_PATTERN's read the other way, so the two accept the
  -- same identifiers; `A-1` is refused by both, since the prefix wants two
  -- characters at least. repo.KEY, which an epic is held to, is the same
  -- shape again.
  calls, restore = stub_run(function(argv)
    return done(argv, {})
  end)
  for _, id in ipairs({ "TIG-1001", "AB1-2", "PROJ-142", "A-1", "TIG-1a", "tig-1", "PROJ-142abc" }) do
    local refused
    jira.states(id, function(_, err)
      refused = err ~= nil
    end)
    eq(refused, env.key_of(id) ~= id, id .. ": states and env.key_of agree")
    eq(id:match(repo.KEY) == nil, env.key_of(id) ~= id, id .. ": repo.KEY and env.key_of agree")
  end
  restore()
  eq(#calls, 3, "the three keys were searched")
end)

test("jira: rows are normalised, either search shape is read, and complete answers from them", function()
  jira.forget()
  local calls, restore = stub_run(function(argv)
    if jql_of(argv):find("issues", 1, true) then
      return done(argv, { issues = { found("TIG-9", { summary = "Nine", status = { name = "Done" } }) }, startAt = 0, maxResults = 50 })
    end
    -- The first row carries fields the search is not asked for, as a client
    -- that ignored `--fields` would return them; none reaches the row.
    return done(argv, {
      found("TIG-12", {
        summary = "Twelve",
        status = { name = "To Do" },
        assignee = user("acc-me", "Me Myself"),
        reporter = user("acc-ana", "Ana"),
        updated = "2024-05-03T10:00:00.000+0000",
      }),
      found("TIG-3", { summary = "Three", status = { name = "In Progress" } }),
    })
  end)
  local got
  jira.rows({ title = "Mine", query = "project = TIG" }, function(rows, err)
    got = { rows, err }
  end)
  eq(got[2], nil)
  eq(calls[1].argv, argv_of("workitem", "search", "--jql", "project = TIG", "--json", "--fields", JIRA_FIELDS, "--paginate"))
  eq(got[1][1].id, "TIG-12")
  eq(got[1][1].state, "To Do")
  eq(got[1][1].title, "Twelve")
  eq(got[1][1].source, "jira")
  eq(
    { got[1][1].assignee, got[1][1].reporter, got[1][1].updated },
    { nil, nil, nil },
    "a row carries what it renders: the fields the search does not ask for are not read"
  )
  eq(jira.complete("item", "tig-1"), { { id = "TIG-12", title = "Twelve" } })
  eq(jira.complete("item", "Tig-1"), { { id = "TIG-12", title = "Twelve" } }, "matched in any case")
  eq(jira.complete("item", ""), { { id = "TIG-3", title = "Three" }, { id = "TIG-12", title = "Twelve" } }, "in the dashboard's order, by number")
  eq(jira.complete("user", "me"), {}, "no user is offered: a mention cannot be written")
  eq(jira.complete("user", "T"), {}, "nor a key, for a query that matches one")
  jira.rows({ title = "Recently updated", query = "project = TIG AND text ~ issues" }, function(rows, err)
    got = { rows, err }
  end)
  restore()
  eq(got[2], nil)
  eq(#got[1], 1)
  eq(got[1][1].id, "TIG-9")
  eq(got[1][1].branch, nil)
  eq(jira.branch(got[1][1]), nil, "a ticket has no branch until the launcher generates one")
  -- The dashboard runs its Jira sections at once, so the candidates are the
  -- rows both sections last returned, not the last section to finish.
  eq(jira.complete("item", ""), {
    { id = "TIG-3", title = "Three" },
    { id = "TIG-9", title = "Nine" },
    { id = "TIG-12", title = "Twelve" },
  })
end)

test("jira: a section's rows replace its own candidates, and a key two sections return is offered once", function()
  jira.forget()
  local _, restore = stub_run(function(argv)
    local jql = jql_of(argv)
    if jql == "mine" then
      return done(argv, {
        found("TIG-12", { summary = "Twelve", status = { name = "To Do" } }),
        found("TIG-3", { summary = "Three", status = { name = "In Progress" } }),
      })
    end
    if jql == "mine, after the transition" then
      return done(argv, { found("TIG-12", { summary = "Twelve and a half", status = { name = "Done" } }) })
    end
    if jql == "reported, after the transition" then
      return done(argv, {})
    end
    return done(argv, { found("TIG-3", { summary = "Three", status = { name = "In Progress" } }) })
  end)
  jira.rows({ title = "Mine", query = "mine" }, function() end)
  jira.rows({ title = "Reported by me", query = "reported" }, function() end)
  eq(jira.complete("item", ""), {
    { id = "TIG-3", title = "Three" },
    { id = "TIG-12", title = "Twelve" },
  }, "TIG-3 is in both sections and is offered once")
  -- The first section runs again: TIG-3 has left it, and TIG-12's summary was
  -- edited. The other section still holds TIG-3.
  jira.rows({ title = "Mine", query = "mine, after the transition" }, function() end)
  eq(jira.complete("item", ""), {
    { id = "TIG-3", title = "Three" },
    { id = "TIG-12", title = "Twelve and a half" },
  }, "the section's own rows replaced what it returned before")
  -- And when the section that still held TIG-3 returns nothing, the key is
  -- offered by no section and gone.
  jira.rows({ title = "Reported by me", query = "reported, after the transition" }, function() end)
  restore()
  eq(jira.complete("item", ""), { { id = "TIG-12", title = "Twelve and a half" } })
end)

test("jira: a row the client left without a status is left out and named, and the rest still shown", function()
  local _, restore = stub_run(function(argv)
    if jql_of(argv):find("broken", 1, true) then
      return done(argv, { found("TIG-1", { summary = "One" }), found("TIG-2", { status = { name = "Done" } }) })
    end
    return done(argv, {
      found("TIG-1", { summary = "One" }),
      found("TIG-2", { summary = "Two", status = { name = "Done" } }),
      found("TIG-3", { summary = "Three", status = { name = "To Do" } }),
    })
  end)
  local got
  jira.rows({ query = "project = TIG" }, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  eq(got[2], nil)
  eq(#got[1], 2, "the whole rows survive")
  eq(got[1][1].id, "TIG-2")
  eq(got[1][2].id, "TIG-3")
  eq(got[3]:find("TIG-1 needs a non-empty string for state", 1, true) ~= nil, true, got[3])
  jira.rows({ query = "project = TIG AND text ~ broken" }, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  restore()
  eq(got[1], nil, "no row survived")
  eq(got[2]:find("TIG-1 needs a non-empty string for state", 1, true) ~= nil, true, got[2])
  eq(got[2]:find("TIG-2 needs a non-empty string for title", 1, true) ~= nil, true, got[2])
  eq(got[3], nil)
end)

test("category: a Jira status's category reaches the row and the item, and colours `Renewal` by it rather than by its name", function()
  jira.forget()
  -- `Renewal` holds `new`, which a match on the name would colour as open.
  local renewal = { name = "Renewal", statusCategory = { key = "indeterminate", name = "In Progress" } }
  local _, restore = stub_run(function(argv)
    if argv[4] == "search" and jql_of(argv) == "assignee = currentUser()" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    if argv[4] == "search" then
      return done(argv, {
        found("TIG-5", { summary = "Five", status = renewal }),
        found("TIG-6", { summary = "Six", status = { name = "Triage" } }),
      })
    end
    local payload = view_payload()
    payload.fields.status = renewal
    return done(argv, payload)
  end)
  local rows, it
  jira.rows({ title = "Mine", query = "project = TIG" }, function(found_rows)
    rows = found_rows
  end)
  jira.item("TIG-1001", function(found_item)
    it = found_item
  end)
  restore()
  eq({ rows[1].category, rows[2].category }, { "indeterminate", nil }, "a status carrying no category leaves none")
  eq({ it.state, it.category }, { "Renewal", "indeterminate" })

  local _, _, marks = list.lines({ root = "/w/repo", sections = { { def = { title = "Mine" }, rows = rows } } }, 0)
  local states = {}
  for _, mark in ipairs(marks) do
    if mark[2] == #list.INDENT + #"TIG-5" + #list.GAP then
      states[#states + 1] = mark[4]
    end
  end
  eq(states, { "DocketStatePending", "DocketLabel" }, "the dashboard's state column: by category, and a label with none")

  local buf = vim.api.nvim_create_buf(false, true)
  buffer.populate(buf, it, { now = NOW })
  local header
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, buffer.DECOR, 0, -1, { details = true })) do
    if mark[2] == 0 and mark[3] == #"TIG-1001" + #render.SEPARATOR then
      header = { mark[3], mark[4].end_col, mark[4].hl_group }
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(header, { 11, 11 + #"Renewal", "DocketStatePending" }, "the item buffer's header")
end)

local STATUS_SIGNED_IN = "✓ Authenticated\n  Site: example.atlassian.net\n  Email: me@example.test\n  Authentication Type: api_token\n"
-- The site here is one nothing but this output names, so an assertion on it
-- proves the `Site:` line was read rather than a `self` URL from an earlier
-- payload, which also names example.atlassian.net.
local STATUS_ONLY_SITE = "✓ Authenticated\n  Site: status-only.atlassian.net\n  Email: me@example.test\n  Authentication Type: api_token\n"

test("jira: auth status is read from the output, and a missing client is said to be missing", function()
  local _, restore = stub_wait(function(argv)
    return done(argv, STATUS_ONLY_SITE)
  end)
  local status = jira.auth_status()
  restore()
  eq(status, { authenticated = true, missing = false, detail = vim.trim(STATUS_ONLY_SITE) })
  eq(jira.url({ id = "TIG-1" }), "https://status-only.atlassian.net/browse/TIG-1", "the site comes off the Site: line")

  _, restore = stub_wait(function(argv)
    return failed(argv, 1, "✗ Not authenticated. Run: acli jira auth login")
  end)
  status = jira.auth_status()
  restore()
  eq(status, { authenticated = false, missing = false, detail = "acli exited 1\n✗ Not authenticated. Run: acli jira auth login" })

  _, restore = stub_wait(function(argv)
    return done(argv, "Not authenticated\n")
  end)
  eq(jira.auth_status().authenticated, false, "the word has to be the capitalised one on its own")
  restore()

  _, restore = stub_wait(function(argv)
    return failed(argv, spawn.MISSING, "ENOENT: no such file or directory")
  end)
  status = jira.auth_status()
  restore()
  eq(status.missing, true)
  eq(status.authenticated, false)
end)

test("jira: a login the client refuses leaves the site of the account still signed in", function()
  jira.forget()
  local _, restore = stub_wait(function(argv)
    if argv[4] == "status" then
      return done(argv, STATUS_ONLY_SITE)
    end
    return failed(argv, 1, "Error: 401 Unauthorized")
  end)
  jira.auth_status()
  local result = jira.auth_login("bad", { site = "typo.atlassian.net", email = "me@example.test" })
  restore()
  eq(result.ok, false)
  eq(jira.url({ id = "TIG-1" }), "https://status-only.atlassian.net/browse/TIG-1")
  eq(jira.auth_fields()[1].default, "status-only.atlassian.net", "and offers it at the next login")
  _, restore = stub_wait(function(argv)
    return done(argv, "")
  end)
  jira.auth_login("good", { site = "other.atlassian.net", email = "me@example.test" })
  restore()
  eq(jira.url({ id = "TIG-1" }), "https://other.atlassian.net/browse/TIG-1", "a login that succeeds names its own")
end)

test("jira: the login puts the token on stdin with a trailing newline and never in the argument list", function()
  jira.forget()
  local calls, restore = stub_wait(function(argv)
    return done(argv, "")
  end)
  local result = jira.auth_login("s3cret-token", { site = "example.atlassian.net", email = "me@example.test" })
  restore()
  eq(result.ok, true)
  eq(#calls, 1)
  eq(calls[1].argv, argv_of("auth", "login", "--site", "example.atlassian.net", "--email", "me@example.test", "--token"))
  eq(calls[1].opts.stdin, "s3cret-token\n")
  for _, word in ipairs(calls[1].argv) do
    eq(word:find("s3cret", 1, true), nil, "the token is in no argument")
  end
  eq(jira.token_url(), "https://id.atlassian.com/manage-profile/security/api-tokens")
  local names = vim.tbl_map(function(field)
    return field.name
  end, jira.auth_fields())
  eq(names, { "site", "email" })
end)

test("jira: a login drops the remembered identity and the rows, so the next open asks again", function()
  jira.forget()
  local runs, restore_run = stub_run(function(argv)
    return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself"), summary = "Seven", status = { name = "To Do" } }) })
  end)
  jira.whoami(function() end)
  jira.whoami(function() end)
  eq(#runs, 1)
  jira.rows({ query = "project = TIG" }, function() end)
  eq(jira.complete("item", ""), { { id = "TIG-7", title = "Seven" } }, "a candidate from the account signed in until now")
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  jira.auth_login("t", { site = "s", email = "e" })
  restore_wait()
  eq(jira.complete("item", ""), {}, "no key from the previous account's projects is offered")
  jira.whoami(function() end)
  restore_run()
  eq(#runs, 3, "asked again after the login")
end)

-- the login flow --------------------------------------------------------------------------

-- The editor's prompts, replaced for a test and put back after it.
local function stub_prompts(answers)
  local saved = { input = vim.fn.input, inputsecret = vim.fn.inputsecret, confirm = vim.fn.confirm, open = vim.ui.open, echo = vim.api.nvim_echo }
  local asked = {}
  -- Silenced, so the token page the flow puts in the history stays out of
  -- the suite's output; a test that wants it replaces nvim_echo itself.
  vim.api.nvim_echo = function() end
  vim.fn.input = function(opts)
    asked[#asked + 1] = opts.prompt
    return answers.input or ""
  end
  vim.fn.inputsecret = function(prompt)
    asked[#asked + 1] = prompt
    return answers.secret or ""
  end
  vim.fn.confirm = function()
    return answers.confirm or 2
  end
  vim.ui.open = function(url)
    asked[#asked + 1] = "open " .. url
  end
  return asked, function()
    vim.fn.input, vim.fn.inputsecret, vim.fn.confirm, vim.ui.open = saved.input, saved.inputsecret, saved.confirm, saved.open
    vim.api.nvim_echo = saved.echo
  end
end

-- What a client's state check answers, from `state` as stub_acli takes it:
-- acli from `signed_in`, glab and gh from `state.glab` and `state.gh`, each
-- not signed in unless set. A client not signed in exits 1 with words of its
-- own, as all three do. nil for a call that is not a state check.
local function status_answer(state, argv)
  if argv[1] == "acli" then
    if argv[3] ~= "auth" or argv[4] ~= "status" then
      return nil
    end
    if state.signed_in then
      return done(argv, STATUS_SIGNED_IN)
    end
    return failed(argv, 1, "✗ Not authenticated")
  end
  if argv[2] ~= "auth" or argv[3] ~= "status" then
    return nil
  end
  if state[argv[1]] then
    return done(argv, ("✓ Logged in to %s.example.test as me\n"):format(argv[1]))
  end
  return failed(argv, 1, ("x %s: no token"):format(argv[1]))
end

-- The clients as the flows meet them. acli: `auth status` answers from
-- `signed_in`, which a successful `auth login` flips, and `auth login`
-- answers from `login`. glab and gh: every call answers as their state check
-- does, from `state.glab` and `state.gh`.
local function stub_acli(state)
  return stub_wait(function(argv)
    if argv[1] ~= "acli" then
      if state[argv[1]] then
        return done(argv, ("✓ Logged in to %s.example.test as me\n"):format(argv[1]))
      end
      return failed(argv, 1, ("x %s: no token"):format(argv[1]))
    end
    local status = status_answer(state, argv)
    if status then
      return status
    end
    local result = state.login(argv)
    if result.ok then
      state.signed_in = true
    end
    return result
  end)
end

-- An answer for stub_run or stub_run_fast: each client's state check answers
-- as stub_acli has it answer, from `state`, and every other call goes to
-- `answer`. The dashboard asks for the state through spawn.run, so a test of
-- it that stubs spawn.run answers the check there.
local function checked(state, answer)
  return function(argv, opts)
    return status_answer(state, argv) or answer(argv, opts)
  end
end

-- spawn.run answering the state checks alone, each client signed in as
-- `state` says, for a test that replaces the calls after them itself.
local function stub_checks(state)
  return stub_run(checked(state, function(argv)
    error("a call past the state check reached spawn.run: " .. table.concat(argv, " "))
  end))
end

-- Whether a recorded call is a client's state check.
local function is_status(call)
  return status_answer({}, call.argv) ~= nil
end

test("auth: the flow checks the state, prompts, logs in on stdin, and reports the state after", function()
  jira.forget()
  local calls, restore_acli = stub_acli({ signed_in = false, login = function(argv)
    return done(argv, "")
  end })
  local asked, restore_prompts = stub_prompts({ input = "me@example.test", secret = "tok", confirm = 1 })
  -- The token page has to be in the message history before the dialog,
  -- because vim.fn.confirm draws on the command line and clears it.
  local echoed, saved_echo = {}, vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, history)
    echoed[#echoed + 1] = { chunks[1][1], history, #asked }
  end
  config.configure({ jira = { site = "example.atlassian.net" } })
  local ok, message = auth.login("jira")
  config.configure({})
  vim.api.nvim_echo = saved_echo
  restore_prompts()
  restore_acli()
  eq(ok, true)
  eq(message:sub(1, #"jira: signed in"), "jira: signed in")
  eq(message:find("Site: example.atlassian.net", 1, true) ~= nil, true, "the state after the login is what is reported")
  eq(asked, { "Atlassian account email: ", "open " .. jira.TOKEN_URL, "jira token: " }, "the site came from setup{} and was not asked for")
  eq(echoed, { { "A token is minted at " .. jira.TOKEN_URL, true, 1 } }, "echoed into the history, after the field and before the dialog")
  eq(#calls, 3)
  eq(calls[1].argv, argv_of("auth", "status"))
  eq(calls[2].argv, argv_of("auth", "login", "--site", "example.atlassian.net", "--email", "me@example.test", "--token"))
  eq(calls[2].opts.stdin, "tok\n")
  eq(calls[3].argv, argv_of("auth", "status"))
end)

test("auth: a client already signed in is left alone, and force logs in again", function()
  local calls, restore_acli = stub_acli({ signed_in = true, login = function(argv)
    return done(argv, "")
  end })
  local asked, restore_prompts = stub_prompts({ input = "x", secret = "tok" })
  local ok, message = auth.login("jira")
  eq(ok, true)
  eq(message:sub(1, #"jira: already signed in"), "jira: already signed in")
  -- The bang on the command name, where Vim reads one: `:Docket login! jira`
  -- passes `login!` as an argument, and the command refuses it.
  eq(message:find(":Docket! login jira", 1, true) ~= nil, true, "the way through is named: " .. message)
  eq(asked, {}, "no prompt")
  eq(#calls, 1, "the state check alone")
  ok = auth.login("jira", { force = true })
  restore_prompts()
  restore_acli()
  eq(ok, true)
  eq(#calls, 4, "the state check, the login, the state check after")
  eq(calls[3].argv[4], "login", "force runs the login")
  eq(calls[3].opts.stdin, "tok\n")
end)

test("auth: a machine with no opener reports it and the flow goes on", function()
  local _, restore_acli = stub_acli({ signed_in = false, login = function(argv)
    return done(argv, "")
  end })
  local _, restore_prompts = stub_prompts({ input = "x", secret = "tok", confirm = 1 })
  vim.ui.open = function()
    return nil, "vim.ui.open: no handler found (tried: xdg-open)"
  end
  local echoed, saved_echo = {}, vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks)
    echoed[#echoed + 1] = { chunks[1][1], chunks[1][2] }
  end
  local ok = auth.login("jira")
  vim.api.nvim_echo = saved_echo
  restore_prompts()
  restore_acli()
  eq(ok, true, "the address is on screen to reach by hand")
  eq(echoed, {
    { "A token is minted at " .. jira.TOKEN_URL, nil },
    { "vim.ui.open: no handler found (tried: xdg-open)", "WarningMsg" },
  }, "the failure is highlighted as one")
end)

test("auth: an empty answer stops the flow with nothing run", function()
  local calls, restore_acli = stub_acli({ signed_in = false, login = function()
    error("no login should run")
  end })
  local _, restore_prompts = stub_prompts({ input = "" })
  local ok, message = auth.login("jira")
  eq(ok, false)
  eq(message, "jira: no site given; nothing changed")
  restore_prompts()
  _, restore_prompts = stub_prompts({ input = "x", secret = "" })
  ok, message = auth.login("jira")
  restore_prompts()
  restore_acli()
  eq(ok, false)
  eq(message, "jira: no token given; nothing changed")
  eq(#calls, 2, "one state check per attempt and no login")
  -- <C-c> at input() raises where inputsecret() answers "", and reads the same.
  calls, restore_acli = stub_acli({ signed_in = false, login = function()
    error("no login should run")
  end })
  _, restore_prompts = stub_prompts({})
  vim.fn.input = function()
    error("Keyboard interrupt")
  end
  ok, message = auth.login("jira")
  restore_prompts()
  restore_acli()
  eq({ ok, message }, { false, "jira: no site given; nothing changed" })
  eq(#calls, 1, "the state check alone")
end)

test("auth: a failed login reports the client's own message verbatim", function()
  local _, restore_acli = stub_acli({ signed_in = false, login = function(argv)
    return failed(argv, 1, "Error: 401 Unauthorized\nCheck the token and the email address.")
  end })
  local _, restore_prompts = stub_prompts({ input = "x", secret = "tok" })
  local ok, message = auth.login("jira")
  restore_prompts()
  restore_acli()
  eq(ok, false)
  eq(message, "acli exited 1\nError: 401 Unauthorized\nCheck the token and the email address.")
end)

test("auth: a missing client and an unknown adapter are each refused with the reason", function()
  local _, restore_acli = stub_wait(function(argv)
    return failed(argv, spawn.MISSING, "ENOENT: no such file or directory")
  end)
  local ok, message = auth.login("jira")
  local adapter, reason = auth.ready("jira")
  restore_acli()
  eq(ok, false)
  eq(message:find("^jira: the client is not installed") ~= nil, true, message)
  eq(adapter, nil)
  eq(reason:find("not installed", 1, true) ~= nil, true, reason)
  ok, message = auth.login("svn")
  eq(ok, false)
  eq(message:find("no adapter named svn", 1, true) ~= nil, true, message)
end)

test("auth: ready hands the adapter over when signed in and names the login command otherwise", function()
  local _, restore_acli = stub_acli({ signed_in = false })
  local adapter, reason = auth.ready("jira")
  eq(adapter, nil)
  eq(reason:find(":Docket login jira", 1, true) ~= nil, true, reason)
  eq(reason:find("Not authenticated", 1, true) ~= nil, true, "the client's own output follows")
  restore_acli()
  _, restore_acli = stub_acli({ signed_in = true })
  adapter, reason = auth.ready("jira")
  restore_acli()
  eq(adapter, jira)
  eq(reason, nil)
end)

-- spawn.run holding every call it is given, in the order given, until the
-- test hands one its result with `answer(index, result)`.
local function stub_run_held()
  local held, saved = {}, spawn.run
  spawn.run = function(argv, opts, on_done)
    held[#held + 1] = { argv = argv, opts = opts, on_done = on_done }
  end
  local function answer(index, result)
    held[index].on_done(result)
  end
  return held, answer, function()
    spawn.run = saved
  end
end

test("auth: check answers what ready answers, handed on, and a name the registry refuses before it returns", function()
  local answers = {}
  for _, signed_in in ipairs({ true, false }) do
    local _, restore_wait = stub_acli({ signed_in = signed_in })
    local ready = { auth.ready("jira") }
    restore_wait()
    local _, restore_run = stub_run(checked({ signed_in = signed_in }, function(argv)
      error("the check ran more than the state check: " .. table.concat(argv, " "))
    end))
    local _, restore_guard = stub_wait(function(argv)
      error("check held the editor for " .. table.concat(argv, " "))
    end)
    local checked_answer
    auth.check("jira", function(adapter, message)
      checked_answer = { adapter, message }
    end)
    restore_guard()
    restore_run()
    answers[#answers + 1] = { ready = ready, check = checked_answer }
  end
  eq(answers[1].check, { jira }, "signed in, the adapter and no message")
  eq(answers[2].check, answers[2].ready, "signed out, ready()'s message word for word")
  eq(answers[2].check[2]:find("^jira: not signed in; run :Docket login jira") ~= nil, true, answers[2].check[2])
  local unknown
  auth.check("svn", function(adapter, message)
    unknown = { adapter, message }
  end)
  eq(unknown, { nil, select(2, adapters.get("svn")) }, "answered before check returned")
end)

test("auth: a check answered after a login for its backend is refused, and one for another backend's login is not", function()
  -- Holds the check's `auth status`, runs the login, and then answers it.
  local function across(login_backend)
    local held, answer, restore_run = stub_run_held()
    local got
    auth.check("jira", function(adapter, message)
      got = { adapter, message }
    end)
    local _, restore_acli = stub_acli({ signed_in = true, glab = true, login = function(argv)
      return done(argv, "")
    end })
    local _, restore_prompts = stub_prompts({ input = "x", secret = "tok" })
    config.configure({ jira = { site = "example.atlassian.net" } })
    local logged_in, message = auth.login(login_backend, { force = true })
    config.configure({})
    restore_prompts()
    restore_acli()
    eq(logged_in, true, message)
    eq(got, nil, "the check is still out")
    answer(1, done(held[1].argv, STATUS_SIGNED_IN))
    restore_run()
    return got
  end
  eq(across("jira"), {
    nil,
    "jira: a login ran while the state check was in flight, so its answer is not shown; refresh to ask again",
  })
  eq(across("glab"), { jira }, "a login to GitLab leaves Jira's answer standing")
  glab.forget()
end)

-- the item buffer ---------------------------------------------------------------------------

-- vim.notify replaced for a test, recording each message with its level, and
-- put back after it.
--
-- nvim's own `log:` notice is left out. Where `~/.local/state/nvim` cannot be
-- written -- the harness's sandbox is such a place -- nvim logs to `nvim.log`
-- in the working directory instead and announces that through vim.notify, on
-- a scheduled callback, the first time its Lua side logs; the wipe of a
-- `bufhidden=wipe` buffer is what first makes it do so here. A test counting
-- notices would otherwise count the environment.
local function stub_notify()
  local saved, notices = vim.notify, {}
  vim.notify = function(message, level)
    if tostring(message):find("^log: ") then
      return
    end
    notices[#notices + 1] = { message = message, level = level }
  end
  return notices, function()
    vim.notify = saved
  end
end

-- A scratch buffer holding the ticket, as the read command leaves it.
local function loaded_buffer(overrides)
  local name = buffer.name("jira", (overrides or {}).id or "PROJ-142")
  -- buffer.named rather than bufnr(), which matches its argument as a pattern.
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  buffer.populate(buf, ticket(overrides), { now = NOW })
  return buf
end

-- An item buffer of that name before anything has prepared or read it:
-- named, unlisted and empty, so a window showing it carries none of
-- buffer.WINDOW. An earlier test's buffer of the name is deleted first.
local function unread_buffer(id)
  local name = buffer.name("jira", id)
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  return buf
end

-- `wrap`, `linebreak` and `breakindent` in a window, which are buffer.WINDOW.
local function wrapping(win)
  return { vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent }
end
local WRAPS, NO_WRAP = { true, true, true }, { false, false, false }

-- Runs `body` in a tab of its own and closes the tab after, answering as
-- pcall does. With `nowrap` set it runs under the global `nowrap` the
-- configuration sets, and puts back the value it found. A window showing a
-- buffer for the first time takes the global value, and the suite's `-u NONE`
-- leaves it on, so a window asserted to wrap under it wraps whatever docket
-- does. The value is set before the tab opens, because a new window takes
-- its global values from the window it was made from.
local function in_tab(body, nowrap)
  local saved = vim.o.wrap
  if nowrap then
    vim.o.wrap = false
  end
  vim.cmd.tabnew()
  local tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(body)
  if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(tab))
  end
  vim.o.wrap = saved
  return ok, err
end

-- The region marks as `{ [id] = { first_row, end_row } }`, 0-based, end
-- exclusive, with `invalid` where the mark is.
local function ranges(buf)
  local marks = vim.b[buf].docket.marks
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, buffer.REGIONS, 0, -1, { details = true })) do
    local known = marks[tostring(mark[1])]
    found[known.id] = { mark[2], mark[4].end_row, invalid = mark[4].invalid }
  end
  return found
end

test("buffer: the name carries the source, the project where the source numbers items within one, and the identifier, and parses back", function()
  eq(buffer.name("jira", "PROJ-142"), "docket://jira/PROJ-142")
  eq({ buffer.parse("docket://jira/PROJ-142") }, { "jira", "PROJ-142" }, "a Jira key names its project already")
  eq(buffer.name("glab", "!482", "acme/payments"), "docket://glab/acme/payments/!482")
  eq({ buffer.parse("docket://glab/acme/payments/!482") }, { "glab", "!482", "acme/payments" })
  eq(
    { buffer.parse(buffer.name("glab", "!482", "acme/sub/payments")) },
    { "glab", "!482", "acme/sub/payments" },
    "a subgroup's slashes stay in the project, and the identifier is the last part"
  )
  eq({ buffer.parse("docket://glab/!482") }, { "glab", "!482" }, "a name typed with no project parses to none")
  eq(buffer.BY_PROJECT, { glab = true })
  eq({ buffer.parse("/tmp/notes.txt") }, {})
  eq({ buffer.parse("docket://jira") }, {})
end)

test("repo: the project path is read off origin's URL over scp, https and ssh, and a URL naming no host names none", function()
  for _, url in ipairs({
    "git@gitlab.example.test:acme/payments.git",
    "https://gitlab.example.test/acme/payments.git/",
    "https://gitlab.example.test/acme/payments",
    "ssh://git@gitlab.example.test:2222/acme/payments.git",
  }) do
    eq(repo.project_of(url), "acme/payments", url)
  end
  eq(repo.project_of("git@gitlab.example.test:acme/sub/payments.git"), "acme/sub/payments", "a subgroup is part of the path")
  eq(repo.project_of("/srv/git/x.git"), nil, "a local path names no host")
  eq(repo.project_of("https://gitlab.example.test"), nil, "nor a project")
  eq(repo.project_of("https://gitlab.example.test/"), nil)
end)

test("repo: the remotes are read off `git remote -v` by their fetch URLs, and the set-url remedy is made from an address's site", function()
  eq(
    repo.parse_remotes(table.concat({
      "origin\tgit@github.com:me/payments.git (fetch)",
      "origin\tgit@github.com:me/payments.git (push)",
      "upstream\thttps://github.com/acme/payments.git (fetch)",
      "upstream\tgit@github.com:acme/payments-push.git (push)",
      "",
    }, "\n")),
    {
      { name = "origin", url = "git@github.com:me/payments.git" },
      { name = "upstream", url = "https://github.com/acme/payments.git" },
    },
    "each remote once, by the URL it fetches from"
  )
  eq(repo.parse_remotes(""), {}, "a clone with no remote")
  eq(
    repo.set_url_remedy("https://gitlab.example.test/gitlab/acme/payments/-/merge_requests/482", "gitlab/acme/payments"),
    "; where origin spells this project another way -- an ssh URL without the instance's path prefix, or the path the project had before a move or a rename -- git remote set-url origin https://gitlab.example.test/gitlab/acme/payments.git makes the two agree"
  )
  eq(
    repo.set_url_remedy("http://github.com/acme/payments/pull/12", "acme/payments"),
    "; where origin spells this project another way -- an ssh URL without the instance's path prefix, or the path the project had before a move or a rename -- git remote set-url origin http://github.com/acme/payments.git makes the two agree",
    "the address's own scheme"
  )
  eq(repo.set_url_remedy(nil, "acme/payments"), nil, "no address, no URL to point origin at")
  eq(repo.set_url_remedy("acme/payments!482", "acme/payments"), nil, "nor from a reference with no site")
end)

test("buffer: the options that route :w, keep the buffer switchable and list it", function()
  local buf = loaded_buffer()
  eq(vim.bo[buf].buftype, "acwrite")
  eq(vim.bo[buf].bufhidden, "hide")
  eq(vim.bo[buf].buflisted, true)
  eq(vim.bo[buf].swapfile, false)
  eq(vim.bo[buf].filetype, "docket")
  eq(vim.bo[buf].modified, false, "the read is not an edit")
  -- docket.complete is part of this build, so the read names its omnifunc
  -- and makes it mini.completion's fallback.
  eq(vim.bo[buf].omnifunc, buffer.OMNIFUNC)
  eq(vim.b[buf].minicompletion_config, { fallback_action = "<C-x><C-o>" })
  -- Where the module does not load, both are left unset: mini.completion
  -- would run an omnifunc naming a missing module after every keystroke.
  local bare = vim.api.nvim_create_buf(false, false)
  local saved_loaded, saved_preload = package.loaded[buffer.COMPLETE], package.preload[buffer.COMPLETE]
  package.loaded[buffer.COMPLETE] = nil
  package.preload[buffer.COMPLETE] = function()
    error("module 'docket.complete' not found")
  end
  buffer.prepare(bare)
  package.loaded[buffer.COMPLETE], package.preload[buffer.COMPLETE] = saved_loaded, saved_preload
  eq(vim.bo[bare].omnifunc, "", "unset when the module does not load")
  eq(vim.b[bare].minicompletion_config, nil)
  vim.api.nvim_buf_delete(bare, { force = true })

  -- A buffer made unlisted, as nvim_create_buf() makes one, is listed by the
  -- read. It turns undo off for the lines it sets and back on after, so the
  -- edits that follow the read can be undone.
  local previous = buffer.named(buffer.name("jira", "PROJ-77"))
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local fresh = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(fresh, buffer.name("jira", "PROJ-77"))
  eq(vim.bo[fresh].buflisted, false)
  local undolevels = vim.bo[fresh].undolevels
  buffer.populate(fresh, ticket({ id = "PROJ-77" }), { now = NOW })
  eq(vim.bo[fresh].buflisted, true)
  eq(vim.bo[fresh].undolevels, undolevels, "the read turns undo off for itself alone")
  vim.api.nvim_buf_set_text(fresh, 3, 0, 3, 0, { "X" })
  vim.api.nvim_buf_call(fresh, function()
    vim.cmd("silent! undo")
  end)
  eq(vim.api.nvim_buf_get_lines(fresh, 3, 4, false), { "The retry loop re-enters" }, "an edit after the read is undone")
  vim.api.nvim_buf_delete(fresh, { force = true })
end)

test("buffer: the read turns on wrap, linebreak and breakindent in every window showing the buffer, and the options stay with the buffer", function()
  local made = {}
  local ok, err = in_tab(function()
    local file = vim.api.nvim_get_current_buf()
    local item = unread_buffer("PROJ-901")
    made[#made + 1] = item
    local a = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(a, item)
    vim.cmd("split")
    local b = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local c = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(c, file)
    eq(wrapping(a), NO_WRAP, "unread, the item's window has the editor's nowrap")
    buffer.populate(item, ticket({ id = "PROJ-901" }), { now = NOW })
    eq({ wrapping(a), wrapping(b), wrapping(c) }, { WRAPS, WRAPS, NO_WRAP }, "both of the item's windows, and not the file's")
    eq(vim.go.wrap, false, "the global value is left as it was")

    vim.api.nvim_set_current_win(a)
    vim.cmd("buffer " .. file)
    eq(wrapping(a), NO_WRAP, "the file shown in the item's window keeps nowrap")
    vim.cmd("buffer " .. item)
    eq(wrapping(a), WRAPS, "and the item shown there again wraps")
    vim.cmd("split")
    local d = vim.api.nvim_get_current_win()
    eq(wrapping(d), WRAPS, ":split from the item's window")
    vim.cmd("buffer " .. file)
    eq(wrapping(d), NO_WRAP, "the file in that split")
    -- A buffer shown before takes the values it had where it was last shown,
    -- so the file's nowrap above is its own; a new buffer has none, and
    -- takes the window's.
    vim.cmd("enew")
    eq(wrapping(d), NO_WRAP, "a new buffer in a window that showed the item")
    vim.cmd("new")
    local e = vim.api.nvim_get_current_win()
    vim.cmd("buffer " .. item)
    eq(wrapping(e), WRAPS, "a window that never showed the item takes the values from where it was shown last")
    eq(wrapping(c), NO_WRAP, "the file's window is untouched throughout")
    vim.api.nvim_win_close(d, true)
    vim.api.nvim_win_close(e, true)

    -- A window that showed the item before its read gets back the values it
    -- had then, nowrap, until the next read.
    local unread = unread_buffer("PROJ-902")
    made[#made + 1] = unread
    vim.api.nvim_win_set_buf(c, unread)
    eq(wrapping(c), NO_WRAP, "shown unread")
    vim.api.nvim_set_current_win(c)
    vim.cmd("buffer " .. file)
    vim.cmd("new")
    local f = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(f, unread)
    buffer.populate(unread, ticket({ id = "PROJ-902" }), { now = NOW })
    eq(wrapping(f), WRAPS, "read in another window")
    vim.api.nvim_set_current_win(c)
    vim.cmd("buffer " .. unread)
    eq(wrapping(c), NO_WRAP, "the first window has the nowrap it had before the read")
  end, true)
  for _, buf in ipairs(made) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  assert(ok, err)
end)

test("buffer: a restored session's item window wraps, and a read turns wrapping on where the session did not", function()
  local name = buffer.name("jira", "PROJ-903")
  local saved = vim.o.sessionoptions
  local session, file = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.writefile({ "a file" }, file)
  local ok, err = in_tab(function()
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.cmd("split")
    local item = unread_buffer("PROJ-903")
    vim.api.nvim_win_set_buf(0, item)
    buffer.populate(item, ticket({ id = "PROJ-903" }), { now = NOW })
    -- The session is written for this tab alone and without `curdir`, so
    -- that sourcing it closes no other tab and moves no directory. `blank`
    -- is what records the item's window at all: the editor writes a window
    -- whose buffer names no file, which an `acwrite` buffer counts as, only
    -- under it. The item buffer is wiped before the session is sourced,
    -- because the session names a new buffer after it, which E95 refuses
    -- while it exists.
    local function restored(options)
      vim.o.sessionoptions = options
      vim.cmd("mksession! " .. vim.fn.fnameescape(session))
      vim.api.nvim_buf_delete(buffer.named(name), { force = true })
      vim.cmd("source " .. vim.fn.fnameescape(session))
      local item_win, file_win
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == name then
          item_win = win
        else
          file_win = win
        end
      end
      return item_win, file_win
    end
    local item_win, file_win = restored("blank,winsize,localoptions")
    eq(item_win ~= nil and file_win ~= nil, true, "both windows are restored")
    eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(item_win), 0, -1, false), { "" }, "the item is not read")
    eq(wrapping(item_win), WRAPS, "localoptions restores the item window's wrap options")
    eq(wrapping(file_win), NO_WRAP, "and the file's nowrap")

    item_win, file_win = restored("blank,winsize")
    eq(wrapping(item_win), NO_WRAP, "without localoptions the item window has the editor's nowrap")
    buffer.populate(vim.api.nvim_win_get_buf(item_win), ticket({ id = "PROJ-903" }), { now = NOW })
    eq(wrapping(item_win), WRAPS, "until the item is read")
    eq(wrapping(file_win), NO_WRAP)
  end, true)
  vim.o.sessionoptions = saved
  local left = buffer.named(name)
  if left then
    vim.api.nvim_buf_delete(left, { force = true })
  end
  local file_buf = vim.fn.bufnr(file)
  if file_buf ~= -1 then
    vim.api.nvim_buf_delete(file_buf, { force = true })
  end
  vim.fn.delete(session)
  vim.fn.delete(file)
  assert(ok, err)
end)

test("buffer: named finds the buffer of exactly that name, where bufnr would match a prefix", function()
  local long = loaded_buffer({ id = "PAY-142" })
  local short = loaded_buffer({ id = "PAY-1" })
  eq(buffer.named(buffer.name("jira", "PAY-1")), short)
  eq(buffer.named(buffer.name("jira", "PAY-142")), long)
  eq(buffer.named(buffer.name("jira", "PAY-14")), nil)
  eq(vim.fn.bufnr(buffer.name("jira", "PAY-14")) ~= -1, true, "bufnr answers a buffer for a name that none has")
  vim.api.nvim_buf_delete(long, { force = true })
  vim.api.nvim_buf_delete(short, { force = true })
end)

test("buffer: a line added below a region's last line by o, a linewise p or :put stays inside it, on the body, the last comment and a new comment", function()
  local function added(command, row, region)
    local buf = loaded_buffer()
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setreg("a", "added\n", "l")
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.cmd(command)
    local got = { buffer.current(buf)[region].lines, #buffer.plan(buf).calls }
    vim.api.nvim_buf_delete(buf, { force = true })
    return got
  end
  local body = { "The retry loop re-enters", "before the final attempt.", "added" }
  local comment = { "Fix is in review.", "added" }
  for _, command in ipairs({ "normal! oadded", 'normal! "ap', "put a" }) do
    eq(added(command, 5, "body"), { body, 1 }, command .. " on the body's last line")
    eq(added(command, 11, "10002"), { comment, 1 }, command .. " on the buffer's last line")
  end
  -- A new comment, whose line is the buffer's last, and whose region the
  -- author line compose() appends does not join.
  for _, command in ipairs({ "normal! osecond", 'normal! "ap' }) do
    local buf = loaded_buffer()
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setreg("a", "second\n", "l")
    local row = buffer.compose(buf)
    vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "first" })
    vim.cmd(command)
    local plan = buffer.plan(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(vim.tbl_map(function(call)
      return { call.kind, call.text }
    end, plan.calls), { { diff.COMMENT_CREATE, "first\nsecond" } }, command .. " on a new comment's line")
  end
end)

test("buffer: a comment opened below the last region leaves that region where it ended", function()
  local buf = loaded_buffer()
  local before = ranges(buf)["10002"]
  local row = buffer.compose(buf)
  eq(ranges(buf)["10002"], before, "the author line compose() appends is not the last comment's")
  eq(ranges(buf)[diff.NEW], { row - 1, row })
  eq(buffer.current(buf)["10002"].lines, { "Fix is in review." })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("buffer: undo right after the read leaves the buffer as the read left it", function()
  local buf = loaded_buffer()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! undo")
  end)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
  eq(vim.bo[buf].modified, false)
  eq(ranges(buf).body, { 3, 5 })
end)

test("buffer: one mark per region, from column 0 of its first line to column 0 of the line after", function()
  local buf = loaded_buffer()
  eq(ranges(buf), { body = { 3, 5 }, ["10001"] = { 7, 8 }, ["10002"] = { 10, 11 } })
  eq(vim.api.nvim_buf_line_count(buf), 11, "the last region ends the buffer, and its end mark sits past the last line")
  local state = vim.b[buf].docket
  eq(state.source, "jira")
  eq(state.id, "PROJ-142")
  eq(state.title, "Retry backoff drops the last attempt")
  local kinds, edges = {}, {}
  for _, known in pairs(state.marks) do
    kinds[known.id] = { kind = known.kind, owner = known.owner }
    edges[known.id] = vim.api.nvim_buf_get_extmark_by_id(buf, buffer.EDGES, known.edge, {})
  end
  eq(edges, { body = { 5, 0 }, ["10001"] = { 8, 0 }, ["10002"] = { 11, 0 } }, "each edge where its range ends")
  eq(kinds, {
    body = { kind = diff.BODY },
    ["10001"] = { kind = diff.COMMENT, owner = "acc-ana" },
    ["10002"] = { kind = diff.COMMENT, owner = "acc-me" },
  })
end)

test("buffer: the snapshot is diff's contract, and the marks unedited yield no calls", function()
  local buf = loaded_buffer()
  local _, regions = render.render(ticket(), { now = NOW })
  local expected = { regions = {} }
  for _, region in ipairs(regions) do
    expected.regions[region.id] = {
      kind = region.kind,
      owner = region.owner,
      editable = region.editable,
      reason = region.reason,
      lines = region.lines,
    }
  end
  expected.frame = { "PROJ-142   In Progress   me   updated 2h ago", "# Retry backoff drops the last attempt", "ana   3 days ago", "me   yesterday" }
  eq(buffer.snapshot(buf), expected)
  local _, frame = buffer.current(buf)
  eq(frame, {
    { row = 1, text = expected.frame[1] },
    { row = 2, text = expected.frame[2] },
    { row = 7, text = expected.frame[3] },
    { row = 10, text = expected.frame[4] },
  }, "the text outside the regions, by line")
  eq(buffer.current(buf), {
    body = { lines = { "The retry loop re-enters", "before the final attempt." } },
    ["10001"] = { lines = { "Repros on staging." } },
    ["10002"] = { lines = { "Fix is in review." } },
  })
  eq(buffer.plan(buf), { calls = {}, skipped = {}, refused = {} })
end)

test("buffer: typing at the start or the end of a region stays inside it", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local last = #vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
  vim.api.nvim_buf_set_text(buf, 4, last, 4, last, { "Y" })
  eq(ranges(buf).body, { 3, 5 })
  eq(buffer.current(buf).body.lines, { "XThe retry loop re-enters", "before the final attempt.Y" })
  eq(#buffer.plan(buf).calls, 1, "one body update")
  eq(buffer.plan(buf).calls[1].kind, diff.BODY_UPDATE)
end)

test("buffer: a line opened below a region stays inside, and so does text typed on the blank line after it", function()
  local buf = loaded_buffer()
  -- <CR> at the end of the body's last line
  local last = #vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1]
  vim.api.nvim_buf_set_text(buf, 4, last, 4, last, { "", "" })
  eq(ranges(buf).body, { 3, 6 })
  eq(buffer.current(buf).body.lines, { "The retry loop re-enters", "before the final attempt.", "" })
  eq(buffer.plan(buf), { calls = {}, skipped = {}, refused = {} }, "a trailing blank line is not an edit")
  -- typing on the blank line that separates the body from the first author
  -- line, where the end of the body's mark sits
  vim.api.nvim_buf_set_text(buf, 6, 0, 6, 0, { "Z" })
  eq(ranges(buf).body, { 3, 6 }, "the end is part-way along the line now")
  eq(buffer.current(buf).body.lines, { "The retry loop re-enters", "before the final attempt.", "", "Z" })
  eq(buffer.plan(buf).calls, {
    { kind = diff.BODY_UPDATE, id = "body", text = "The retry loop re-enters\nbefore the final attempt.\n\nZ" },
  })
  -- the same at the end of the buffer, where the last region is
  local n = vim.api.nvim_buf_line_count(buf)
  last = #vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
  vim.api.nvim_buf_set_text(buf, n - 1, last, n - 1, last, { "", "more" })
  eq(buffer.current(buf)["10002"].lines, { "Fix is in review.", "more" })
end)

test("buffer: a line opened above a region joins it, which the trim makes harmless", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "", "" })
  eq(ranges(buf).body, { 3, 6 })
  eq(buffer.plan(buf), { calls = {}, skipped = {}, refused = {} })
end)

test("buffer: deleting every line of a region leaves an empty range, which the save skips as emptied", function()
  local buf = loaded_buffer()
  local range = ranges(buf)["10001"]
  vim.api.nvim_buf_set_lines(buf, range[1], range[2], false, {})
  eq(ranges(buf)["10001"], { 7, 7 })
  eq(buffer.current(buf)["10001"], { lines = {} })
  local plan = buffer.plan(buf)
  eq(plan.skipped, { { id = "10001", reason = "empty; nothing sent" } })
  eq(plan.refused, {})
  eq(ranges(buf)["10002"], { 9, 10 }, "the region after it moved up with the text")
end)

-- The item buffer's edit operations. Each test makes an edit the way a
-- person would, with the keys or the Ex command, and asserts what :w would
-- then plan: each call with its text, each region skipped and each refusal.
-- The body and the account's own comment are two lines each, out of order,
-- so that a sort or a filter over either changes it. The lines, numbered as
-- the commands below number them:
--
--    1  PROJ-142   In Progress   me   updated 2h ago
--    2  # Retry backoff drops the last attempt
--    3
--    4  charlie                  body
--    5  alpha                    body
--    6
--    7  ana   3 days ago
--    8  Repros on staging.       10001, ana's
--    9
--   10  me   yesterday
--   11  zulu                     10002, the account's own
--   12  bravo                    10002
local function unsorted_buffer()
  local buf = loaded_buffer({
    body = doc(paragraph(text("charlie"), { type = "hardBreak" }, text("alpha"))),
    comments = {
      { id = 10001, author = { id = "acc-ana", name = "ana" }, created = "2024-04-30T12:00:00.000+0000", body = doc(paragraph(text("Repros on staging."))) },
      {
        id = 10002,
        author = { id = "acc-me", name = "Me Myself" },
        created = "2024-05-02T09:00:00.000+0000",
        body = doc(paragraph(text("zulu"), { type = "hardBreak" }, text("bravo"))),
      },
    },
  })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

-- A plan as the tests below compare it: each call as `{ kind, id, text }`,
-- then each region skipped and each refusal as the save reports it.
local function listed(plan)
  local found = {}
  for _, call in ipairs(plan.calls) do
    found[#found + 1] = { call.kind, call.id, call.text }
  end
  for _, entry in ipairs(plan.skipped) do
    found[#found + 1] = ("%s: %s"):format(entry.id, entry.reason)
  end
  for _, entry in ipairs(plan.refused) do
    found[#found + 1] = ("%s: refused: %s"):format(entry.id, entry.reason)
  end
  return found
end

-- What :w would do after `edit` runs in `buf`, which is then deleted.
local function planned_in(buf, edit)
  vim.api.nvim_set_current_buf(buf)
  edit(buf)
  local plan = buffer.plan(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  return listed(plan)
end

-- The same, in a fresh unsorted_buffer().
local function planned_after(edit)
  return planned_in(unsorted_buffer(), edit)
end

-- The edit as the keys that make it, from line `row`.
local function keys(row, typed)
  return function()
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(typed, true, false, true), "x", false)
  end
end

-- The same, as an Ex command.
local function ex(command)
  return function()
    vim.cmd(command)
  end
end

-- Runs fn as an undo block of its own, as each command typed separately is.
local function own_block(fn)
  vim.cmd("let &g:undolevels = &g:undolevels")
  fn()
  vim.cmd("let &g:undolevels = &g:undolevels")
end

-- The keys, typed where the cursor is, as their own undo block.
local function typed(sequence)
  own_block(function()
    vim.cmd("silent normal! " .. vim.api.nvim_replace_termcodes(sequence, true, false, true))
  end)
end

-- The refusal for a line no region holds.
local function stray(row, line)
  return ('%s: refused: line %d, "%s", is outside every region, where a save sends nothing; move it into a region, or u undoes the edit that put it there'):format(
    diff.OUTSIDE,
    row,
    line
  )
end

-- The refusal for a line gone from outside the regions.
local function gone(line)
  return ('%s: refused: "%s" is no longer outside the regions, so an edit deleted it or moved it into one, and a save cannot tell which; u undoes that edit'):format(
    diff.OUTSIDE,
    line
  )
end

local NOTHING = {}

test("buffer edits: o and O on a region's first and last lines put the new line inside it", function()
  eq(planned_after(keys(4, "onew<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nnew\nalpha" } }, "o on the first line")
  eq(planned_after(keys(5, "onew<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\nnew" } }, "o on the last line")
  eq(planned_after(keys(4, "Onew<Esc>")), { { diff.BODY_UPDATE, "body", "new\ncharlie\nalpha" } }, "O on the first line")
  eq(planned_after(keys(5, "Onew<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nnew\nalpha" } }, "O on the last line")
  -- The comment ends the buffer, so its end sits past the last line.
  eq(planned_after(keys(11, "Onew<Esc>")), { { diff.COMMENT_UPDATE, "10002", "new\nzulu\nbravo" } }, "O on a comment's first line")
  eq(planned_after(keys(12, "onew<Esc>")), { { diff.COMMENT_UPDATE, "10002", "zulu\nbravo\nnew" } }, "o on the buffer's last line")
end)

test("buffer edits: p, P and :put of one line and of several, below and above a region's last line, put them inside it", function()
  local function put(lines, command, row)
    return function()
      vim.fn.setreg("a", lines, "l")
      vim.api.nvim_win_set_cursor(0, { row or 5, 0 })
      vim.cmd(command)
    end
  end
  local one, several = { "one" }, { "one", "two" }
  eq(planned_after(put(one, 'normal! "ap')), { { diff.BODY_UPDATE, "body", "charlie\nalpha\none" } }, "p of one line")
  eq(planned_after(put(several, 'normal! "ap')), { { diff.BODY_UPDATE, "body", "charlie\nalpha\none\ntwo" } }, "p of several")
  eq(planned_after(put(one, 'normal! "aP')), { { diff.BODY_UPDATE, "body", "charlie\none\nalpha" } }, "P of one line")
  eq(planned_after(put(several, 'normal! "aP')), { { diff.BODY_UPDATE, "body", "charlie\none\ntwo\nalpha" } }, "P of several")
  eq(planned_after(put(one, "5put a")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\none" } }, ":put of one line")
  eq(planned_after(put(several, "5put a")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\none\ntwo" } }, ":put of several")
  eq(planned_after(put(one, "5put! a")), { { diff.BODY_UPDATE, "body", "charlie\none\nalpha" } }, ":put! of one line")
  eq(planned_after(put(several, "5put! a")), { { diff.BODY_UPDATE, "body", "charlie\none\ntwo\nalpha" } }, ":put! of several")
  eq(planned_after(put(several, 'normal! "aP', 4)), { { diff.BODY_UPDATE, "body", "one\ntwo\ncharlie\nalpha" } }, "P above the first line")
  eq(planned_after(put(several, 'normal! "ap', 12)), { { diff.COMMENT_UPDATE, "10002", "zulu\nbravo\none\ntwo" } }, "p below the buffer's last line")
end)

test("buffer edits: dd then p swaps a region's lines, and from its last line carries that line out, which refuses the save", function()
  eq(planned_after(keys(4, "ddp")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "from the first line")
  -- dd leaves the cursor on the blank line after the body, and p puts the
  -- line below that, where no region reaches.
  eq(planned_after(keys(5, "ddp")), { stray(6, "alpha") }, "from the last line")
  -- At the end of the buffer dd leaves the cursor on the line above, and p
  -- puts the line back where it was.
  eq(planned_after(keys(12, "ddp")), NOTHING, "from the buffer's last line")
end)

test("buffer edits: :sort over a region's lines sends them sorted", function()
  eq(planned_after(ex("4,5sort")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } })
  eq(planned_after(ex("11,12sort")), { { diff.COMMENT_UPDATE, "10002", "bravo\nzulu" } }, "the comment that ends the buffer")
end)

test("buffer edits: :sort over a range crossing a region's boundary takes blank lines in, and refuses the save when it takes an author line or the title", function()
  eq(planned_after(ex("4,6sort")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "with the blank line after")
  eq(planned_after(ex("3,5sort")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "with the blank line before")
  -- The body, the blank line and the next author line: the body and ana's
  -- comment now both start where the sort put its first line.
  local recover = "u undoes that edit; otherwise yank the text, then :e! reads the item again"
  eq(planned_after(ex("4,7sort")), {
    ("10001: refused: its text runs into body's, so which lines are whose is lost; %s"):format(recover),
    ("body: refused: its text runs into 10001's, so which lines are whose is lost; %s"):format(recover),
    gone("ana   3 days ago"),
  }, "into the next comment's author line")
  eq(planned_after(ex("2,5sort")), { gone("# Retry backoff drops the last attempt") }, "with the title above")
  eq(planned_after(ex("10,12sort")), { gone("me   yesterday") }, "with the comment's own author line")
end)

test("buffer edits: J joining a region's last line to the line after keeps its text, and so does joining the line after that", function()
  eq(planned_after(keys(5, "J")), NOTHING, "with the blank line after")
  -- The second J joins the author line onto the body's last line; the end of
  -- the body's mark stays where the author line begins.
  eq(planned_after(keys(5, "JJ")), NOTHING, "and then with the author line")
  eq(planned_after(keys(10, "J")), NOTHING, "an author line joined with the comment below it")
  eq(planned_after(keys(4, "J")), { { diff.BODY_UPDATE, "body", "charlie alpha" } }, "the region's own two lines")
end)

test("buffer edits: text typed where a J joined an author line onto the comment below it is an edit to the author line, and refuses the save", function()
  -- J leaves the cursor on the space it inserts, so `i` types in front of it,
  -- at the end of the author line's words, and `a` types after it.
  eq(planned_after(keys(10, "JiX<Esc>")), { stray(10, "me   yesterdayX") }, "at the end of the author line's words")
  eq(planned_after(keys(10, "JaY<Esc>")), { stray(10, "me   yesterday Y") }, "after the space J inserts")
  eq(planned_after(keys(10, "gJiX<Esc>")), { stray(10, "me   yesterdayX") }, "where gJ joined the two with no space")
  eq(planned_after(keys(10, "JiX<CR><Esc>")), { stray(10, "me   yesterdayX") }, "and broken onto a line of its own after")
  -- The same on the author line compose() writes above a new comment.
  local buf = unsorted_buffer()
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "hello" })
  eq(planned_in(buf, keys(row - 1, "JiX<Esc>")), { stray(row - 1, "me   not postedX") }, "a comment not yet posted")
end)

test("buffer edits: a J of an author line onto a comment whose first line was edited, or opened above, still sends the comment", function()
  local function after(first, second)
    return function()
      keys(first[1], first[2])()
      keys(second[1], second[2])()
    end
  end
  eq(
    planned_after(after({ 11, "iX<Esc>" }, { 10, "J" })),
    { { diff.COMMENT_UPDATE, "10002", "Xzulu\nbravo" } },
    "text typed at the start of the comment's first line is the comment's"
  )
  eq(
    planned_after(after({ 11, "Onew<Esc>" }, { 10, "J" })),
    { { diff.COMMENT_UPDATE, "10002", "new\nzulu\nbravo" } },
    "a line opened above the comment's first line is the comment's"
  )
  local buf = unsorted_buffer()
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "hello" })
  eq(planned_in(buf, keys(row - 1, "J")), { { diff.COMMENT_CREATE, diff.NEW, "hello" } }, "a comment not yet posted")
  -- The body's head is at the title's end, not on the blank line between,
  -- which a `dd` removes: on that line it would fall to the body's first
  -- column and move with the text typed there, and the title's `J` would
  -- then read that text as the title's and refuse the save.
  eq(
    planned_after(function()
      keys(3, "dd")()
      keys(3, "iX<Esc>")()
      keys(2, "J")()
    end),
    { { diff.BODY_UPDATE, "body", "Xcharlie\nalpha" } },
    "text typed at the start of the body, with the blank line above it deleted, then the title joined onto it"
  )
end)

test("buffer: each region's head sits at the end of the nearest line above its first line that holds text, one per region, and compose() replaces an emptied comment's", function()
  local function heads(buf)
    local found = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, buffer.HEADS, 0, -1, {})) do
      found[#found + 1] = { mark[2], mark[3] }
    end
    return found
  end
  local buf = loaded_buffer()
  local by_region = {}
  for key, known in pairs(vim.b[buf].docket.marks) do
    local at = vim.api.nvim_buf_get_extmark_by_id(buf, buffer.HEADS, known.head, {})
    by_region[known.id] = { at[1], at[2] }
  end
  eq(by_region, { body = { 1, 38 }, ["10001"] = { 6, 16 }, ["10002"] = { 9, 14 } }, "the title's end above the body, and each author line's end")
  eq(#heads(buf), 3)
  buffer.populate(buf, ticket({ comments = {}, total = 0 }), { now = NOW })
  eq(heads(buf), { { 1, 38 } }, "a populate clears the heads of the item read before")
  local row = buffer.compose(buf)
  eq(#heads(buf), 2, "a composed comment has a head of its own")
  vim.api.nvim_buf_set_lines(buf, row - 3, row, false, {})
  buffer.compose(buf)
  eq(#heads(buf), 2, "compose() over an emptied comment drops its head with its marks")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("buffer edits: gq on a region sends it reflowed, and over a comment's paragraph leaves its author line outside", function()
  local function gq(row, width)
    return function()
      vim.bo.textwidth = width
      keys(row, "gqip")()
    end
  end
  eq(planned_after(gq(4, 79)), { { diff.BODY_UPDATE, "body", "charlie alpha" } }, "the body")
  -- A comment's paragraph starts at its author line, which has no blank line
  -- between it and the comment.
  eq(planned_after(gq(11, 79)), { { diff.COMMENT_UPDATE, "10002", "zulu bravo" } }, "the author line joined in")
  eq(planned_after(gq(11, 10)), { { diff.COMMENT_UPDATE, "10002", "zulu bravo" } }, "the author line broken apart")
end)

test("buffer edits: cc on one line of a region sends that line changed", function()
  eq(planned_after(keys(5, "ccomega<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nomega" } })
  eq(planned_after(keys(4, "ccomega<Esc>")), { { diff.BODY_UPDATE, "body", "omega\nalpha" } })
end)

test("buffer edits: :m inside a region sends the new order, out of it into another sends both, and out to where no region reaches refuses the save", function()
  eq(planned_after(ex("4m5")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "the first line below the last")
  eq(planned_after(ex("5m3")), { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "the last line above the first")
  eq(planned_after(ex("4m11")), {
    { diff.COMMENT_UPDATE, "10002", "zulu\ncharlie\nbravo" },
    { diff.BODY_UPDATE, "body", "alpha" },
  }, "into the account's comment")
  eq(planned_after(ex("4m6")), { stray(6, "charlie") }, "below the blank line after the region")
  eq(planned_after(ex("12m0")), { stray(1, "bravo") }, "above the header")
  -- The blank line above the body and its first line, moved below the next
  -- comment: the mark's start goes with them and its end stays.
  eq(planned_after(ex("3,4m9")), {
    "body: refused: an edit moved its first line below its last, so its mark no longer spans its text; u undoes that edit; otherwise yank the text, then :e! reads the item again",
    stray(3, "alpha"),
  }, "the start below the end")
end)

test("buffer edits: ! through a filter over a region's lines sends what the filter printed", function()
  local shell = vim.o.shell
  vim.o.shell = "sh"
  local sorted = planned_after(ex("4,5!sort"))
  -- sed's idiom for printing lines last first, which tac does where it is
  -- installed.
  local reversed = planned_after(ex([[4,5!sed -n '1\!G;h;$p']]))
  local comment = planned_after(ex([[11,12!sed -n '1\!G;h;$p']]))
  vim.o.shell = shell
  eq(sorted, { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "sort")
  eq(reversed, { { diff.BODY_UPDATE, "body", "alpha\ncharlie" } }, "reversed")
  eq(comment, { { diff.COMMENT_UPDATE, "10002", "bravo\nzulu" } }, "the comment that ends the buffer, reversed")
end)

test("buffer edits: a region emptied where the next one starts is emptied, not overlapping, and the author line deleted with it refuses the save", function()
  -- ana's comment, the blank line after it and the next author line: the
  -- emptied mark and the next region's start are then one position.
  eq(planned_after(ex("silent 8,10d")), { "10001: empty; nothing sent", gone("me   yesterday") })
end)

test("buffer edits: deleting every line of a region and then undo sends nothing, and the mark is where it was", function()
  local buf = unsorted_buffer()
  vim.cmd("4,5d")
  eq(buffer.plan(buf).skipped, { { id = "body", reason = "empty; nothing sent" } }, "emptied until the undo")
  vim.cmd("silent undo")
  eq(ranges(buf).body, { 3, 5 })
  eq(buffer.plan(buf), { calls = {}, skipped = {}, refused = {} })
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(planned_after(ex("11,12d | silent undo")), NOTHING, "the comment that ends the buffer")
end)

test("buffer edits: deleting every line of a region and then putting them back with P sends nothing, and other lines put there are sent", function()
  eq(planned_after(keys(4, "2ddP")), NOTHING, "the same lines back")
  eq(planned_after(keys(4, "2ddkp")), NOTHING, "with p from the line above")
  eq(planned_after(keys(11, "2ddp")), NOTHING, "the comment that ends the buffer")
  eq(planned_after(function()
    keys(4, "2dd")()
    vim.fn.setreg("a", { "one", "two", "three" }, "l")
    vim.cmd('silent normal! "aP')
  end), { { diff.BODY_UPDATE, "body", "one\ntwo\nthree" } }, "other lines")
end)

test("buffer edits: typing on the blank line after a region puts the text inside it, with and without <CR>, and after another account's it is refused", function()
  eq(planned_after(keys(6, "iafter<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\nafter" } }, "without <CR>")
  eq(planned_after(keys(6, "iafter<CR><Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\nafter" } }, "<CR> after it")
  eq(planned_after(keys(6, "i<CR>after<Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\n\nafter" } }, "<CR> before it")
  -- Only a join's blank is dropped at a line's end, where one sits between
  -- a region and the text after it; the spaces typed here are the text.
  eq(planned_after(keys(6, "iafter  <Esc>")), { { diff.BODY_UPDATE, "body", "charlie\nalpha\nafter  " } }, "trailing spaces typed")
  eq(planned_after(keys(9, "iafter<Esc>")), { "10001: refused: written by ana; " .. render.WEB_HINT }, "after ana's comment")
  -- The blank line above the body is the title's, and no region reaches it.
  eq(planned_after(keys(3, "ibefore<Esc>")), { stray(3, "before") }, "on the blank line before a region")
end)

test("buffer edits: text typed at the start of an author line whose blank line above is gone is outside every region, and refuses the save", function()
  -- The end of the region above sits where the author line starts and takes
  -- in what is typed there; the region's edge stays in front of it.
  eq(planned_after(keys(6, "ddIoops <Esc>")), { stray(6, "oops ana   3 days ago") }, "the blank line deleted")
  eq(planned_after(keys(6, "JIoops <Esc>")), { stray(6, "oops ana   3 days ago") }, "the blank line joined")
  eq(planned_after(function()
    keys(4, "capomega<Esc>")()
    keys(5, "iX<Esc>")()
  end), { stray(5, "Xana   3 days ago") }, "the body rewritten with cap, which takes the blank line with it")
  eq(planned_after(ex("silent 6d | 6s/^/> /")), { stray(6, "> ana   3 days ago") }, ":s at the start of the line")
  -- Below ana's comment it is refused as text outside, not as an edit to hers.
  eq(planned_after(keys(9, "ddIhello <Esc>")), { stray(9, "hello me   yesterday") }, "the account's own author line")
  -- Nor does it go into the comment above the one compose() opened.
  local buf = unsorted_buffer()
  local row = buffer.compose(buf)
  eq(planned_in(buf, keys(row - 2, "ddIhello <Esc>")), {
    "new: empty; nothing sent",
    stray(row - 2, "hello me   not posted"),
  }, "the author line compose() wrote")
end)

test("buffer edits: a join at a region's end or start keeps the region's own spaces, and only the space J inserts is dropped", function()
  local function edges()
    return loaded_buffer({
      body = "first\nhard break  ",
      comments = {
        {
          id = 10002,
          author = { id = "acc-me", name = "Me Myself" },
          created = "2024-05-02T09:00:00.000+0000",
          body = "    indented code\nplain",
        },
      },
      total = 1,
    })
  end
  --    4  first
  --    5  hard break␣␣           the body, ending in two spaces
  --    6
  --    7  me   yesterday
  --    8  ␣␣␣␣indented code      10002, indented
  --    9  plain
  eq(planned_in(edges(), keys(5, "gJgJ")), NOTHING, "the body's last line onto the author line, with gJ")
  eq(planned_in(edges(), keys(5, "JJ")), NOTHING, "the same with J, which inserts no space after trailing spaces")
  eq(planned_in(edges(), keys(7, "gJ")), NOTHING, "the author line onto an indented comment, with gJ")
  -- J takes the joined line's indentation off, as it does inside a region.
  eq(planned_in(edges(), keys(7, "J")), { { diff.COMMENT_UPDATE, "10002", "indented code\nplain" } }, "the same with J")
  -- A comment opening with one space, which is the region's own: a gJ leaves
  -- the head where the start is, and nothing there is the space a J inserts.
  local function spaced()
    return loaded_buffer({
      comments = {
        {
          id = 10002,
          author = { id = "acc-me", name = "Me Myself" },
          created = "2024-05-02T09:00:00.000+0000",
          body = " one space\nplain",
        },
      },
      total = 1,
    })
  end
  eq(planned_in(spaced(), keys(7, "gJ")), NOTHING, "the author line onto a comment opening with one space, with gJ")
  eq(
    planned_in(spaced(), keys(7, "gJAX<Esc>")),
    { { diff.COMMENT_UPDATE, "10002", " one spaceX\nplain" } },
    "and typed at its end, the space is still the comment's"
  )
end)

test("buffer: an empty range overlaps nothing, whether it sits where another region starts or inside one", function()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "head", "", "one", "two", "", "tail" })
  local function mark(id, from, to)
    vim.api.nvim_buf_set_extmark(buf, buffer.REGIONS, from[1], from[2], { id = id, end_row = to[1], end_col = to[2] })
  end
  mark(1, { 2, 0 }, { 4, 0 })
  mark(2, { 2, 0 }, { 2, 0 })
  mark(3, { 3, 0 }, { 3, 0 })
  vim.b[buf].docket = { marks = { ["1"] = { id = "whole" }, ["2"] = { id = "at_start" }, ["3"] = { id = "inside" } } }
  local current, frame = buffer.current(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(current, { whole = { lines = { "one", "two" } }, at_start = { lines = {} }, inside = { lines = {} } })
  eq(frame, { { row = 1, text = "head" }, { row = 6, text = "tail" } })
end)

test("buffer: a region whose ends cross on one line reads as empty, and the frame reads that line once", function()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "head", "ab x cd" })
  -- The start, part-way along before one space and a word, moves past the
  -- space; the end, part-way along before text, moves back to the edge at
  -- the start of the line.
  vim.api.nvim_buf_set_extmark(buf, buffer.REGIONS, 1, 2, { id = 1, end_row = 1, end_col = 4 })
  vim.api.nvim_buf_set_extmark(buf, buffer.EDGES, 1, 0, { id = 1 })
  vim.b[buf].docket = { marks = { ["1"] = { id = "crossed", edge = 1 } } }
  local current, frame = buffer.current(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(current, { crossed = { lines = {} } })
  eq(frame, { { row = 1, text = "head" }, { row = 2, text = "ab x cd" } })
end)

test("buffer: an edit in another account's region is refused before any call", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 7, 0, 7, 0, { "not mine: " })
  local plan = buffer.plan(buf)
  eq(plan.calls, {})
  eq(#plan.refused, 1)
  eq(plan.refused[1].id, "10001")
  eq(plan.refused[1].reason, "written by ana; " .. render.WEB_HINT)
end)

test("buffer: the write command starts a write that reports through on_done, and says why when it sends nothing", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  -- The check read is held, so the write is still in flight when write()
  -- returns; its answer is then a failure, which writes nothing.
  local held
  local saved_item = jira.item
  jira.item = function(_, on_done)
    held = on_done
  end
  local notices, restore = stub_notify()
  local finished
  local sent, message = buffer.write(buf, function(ok, reported)
    finished = { ok, reported }
  end)
  local pending_notices, writing_then = vim.deepcopy(notices), buffer.writing(buf)
  held(nil, "acli exited 1")
  vim.wait(1000, function()
    return finished ~= nil
  end)
  jira.item = saved_item
  restore()
  eq(sent, true, "the edit starts a write")
  eq(message, nil)
  eq(pending_notices, {}, "nothing is reported until the client answers")
  eq(writing_then, true)
  eq(finished[1], false)
  eq(finished[2]:find("nothing written, because the item could not be read to check it for changes:\nacli exited 1", 1, true) ~= nil, true, finished[2])
  eq(buffer.writing(buf), false, "the failure ends the write")
  eq(#notices, 1)
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "XThe retry loop re-enters" })
  eq(vim.bo[buf].modified, true)
  -- BufWriteCmd discards what the write command returns, so the notice is
  -- the only report `:w` makes on a buffer nothing was read into.
  local empty = vim.api.nvim_create_buf(false, false)
  notices, restore = stub_notify()
  sent, message = buffer.write(empty)
  restore()
  eq(sent, false)
  eq(message, "nothing loaded in this buffer; :e reads the item")
  eq(notices, { { message = message, level = vim.log.levels.WARN } })
  -- Nothing edited: not a count of nothing.
  buf = loaded_buffer()
  notices, restore = stub_notify()
  _, message = buffer.write(buf)
  restore()
  eq(message, "nothing changed")
  -- A refusal empties the calls, so no count is stated beside it.
  vim.api.nvim_buf_set_text(buf, 7, 0, 7, 0, { "not mine: " })
  notices, restore = stub_notify()
  _, message = buffer.write(buf)
  restore()
  eq(message, "10001: refused: written by ana; " .. render.WEB_HINT)
end)

test("buffer: a read populates again and the marks are made afresh", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  buffer.populate(buf, ticket({ comments = {} }), { now = NOW })
  eq(ranges(buf), { body = { 3, 5 } })
  eq(#vim.api.nvim_buf_get_extmarks(buf, buffer.REGIONS, 0, -1, {}), 1, "no stale mark")
  eq(#vim.api.nvim_buf_get_extmarks(buf, buffer.EDGES, 0, -1, {}), 1, "no stale edge")
  eq(vim.bo[buf].modified, false)
end)

test("buffer: editable lines carry DocketEditable one mark per line, and the runs are highlighted", function()
  local buf = loaded_buffer()
  local lines, runs = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, buffer.DECOR, 0, -1, { details = true })) do
    if mark[4].line_hl_group then
      lines[#lines + 1] = mark[2]
    else
      runs[#runs + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
    end
  end
  table.sort(lines)
  eq(lines, { 3, 4, 10 }, "the body's two lines and the own comment; not the other account's")
  table.sort(runs, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  eq(runs, {
    { 0, 11, 22, "DocketStatePending" },
    { 0, 25, 27, "DocketUser" },
    { 6, 0, 3, "DocketUser" },
    { 9, 0, 2, "DocketUser" },
  })
end)

test("buffer: the header's state is a configured status's group when setup{} colours it", function()
  highlight.define({ ["In Review"] = "#f9e2af" })
  local buf = loaded_buffer({ state = "In Review" })
  highlight.define({})
  local found
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, buffer.DECOR, { 0, 0 }, { 0, -1 }, { details = true })) do
    if mark[4].hl_group == "DocketStatusIn_Review" then
      found = { mark[2], mark[4].end_col - mark[3] }
    end
  end
  eq(found, { 0, #"In Review" }, "over the category the ticket carries")
end)

test("highlight: a Jira state is coloured by its category alone, and a review's by its fixed word", function()
  -- The category decides, whatever the name holds: `Renewal` carries `new`
  -- and `Newly done` carries both `new` and `done`.
  eq(highlight.state_group("Renewal", "indeterminate"), "DocketStatePending")
  eq(highlight.state_group("Newly done", "indeterminate"), "DocketStatePending")
  eq(highlight.state_group("In Progress", "indeterminate"), "DocketStatePending")
  eq(highlight.state_group("To Do", "new"), "DocketStateOpen")
  eq(highlight.state_group("x", "done"), "DocketStateClosed")
  eq(highlight.state_group("Open", "undefined"), "DocketLabel", "a category outside Jira's three is not guessed at from the name")
  -- With no category, which is every GitLab and GitHub state, the word is
  -- matched whole and in any case; anything else is a label.
  eq(highlight.state_group("opened"), "DocketStateOpen", "GitLab's")
  eq(highlight.state_group("open"), "DocketStateOpen", "GitHub's, lower-cased")
  eq(highlight.state_group("MERGED"), "DocketStateMerged")
  eq(highlight.state_group("closed"), "DocketStateClosed")
  for _, state in ipairs({ "draft", "locked", "In Progress", "Done", "Renewal", "reopened" }) do
    eq(highlight.state_group(state), "DocketLabel", state)
  end
end)

-- Runs `:highlight clear` on each group named. `:highlight clear` empties a
-- group that holds a value of its own, and puts back the default link of one
-- that had one, so a linked group comes back as an earlier define() left it;
-- a test asserting what define() links records the nvim_set_hl() call
-- instead. DocketEditable holds a value of its own, and a test clears it so
-- that define() chooses it from the colour scheme as it stands, whatever an
-- earlier test left there. nvim_set_hl(0, group, {}) does not serve: a group
-- that has held a link refuses a `default` definition afterwards.
local function clear_groups(groups)
  for _, group in ipairs(groups) do
    vim.cmd.highlight("clear", group)
  end
end

-- A group's own definition, links not followed.
local function own_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = true })
end

-- A group's background, links followed.
local function bg_of(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }).bg
end

test("highlight: each group links to a built-in group whether or not octo.nvim is loaded, and keeps a definition made before define()", function()
  local linked = {
    DocketUser = "Identifier",
    DocketLabel = "Label",
    DocketStateOpen = "DiagnosticOk",
    DocketStateClosed = "DiagnosticError",
    DocketStateMerged = "Special",
    DocketStatePending = "DiagnosticWarn",
  }
  local saved = package.loaded["octo"]
  package.loaded["octo"] = {}
  vim.api.nvim_set_hl(0, "OctoStateOpen", { fg = "#00ff00" })
  vim.api.nvim_set_hl(0, "OctoEditable", { bg = "#222222" })
  clear_groups({ "DocketEditable" })
  -- Each definition this define() makes, recorded as it is made: reading the
  -- groups afterwards finds the links an earlier define() left whether or not
  -- this one set any.
  local set, real = {}, vim.api.nvim_set_hl
  vim.api.nvim_set_hl = function(ns, name, spec)
    set[name] = spec
    return real(ns, name, spec)
  end
  local ok, err = pcall(highlight.define)
  vim.api.nvim_set_hl = real
  assert(ok, err)
  local got, want = {}, {}
  for name, target in pairs(linked) do
    got[name], want[name] = set[name], { link = target, default = true }
  end
  local editable = own_hl("DocketEditable")
  vim.api.nvim_set_hl(0, "DocketStateOpen", { fg = "#ff0000" })
  highlight.define()
  local kept = own_hl("DocketStateOpen")
  package.loaded["octo"] = saved
  clear_groups({ "OctoStateOpen", "OctoEditable", "DocketStateOpen" })
  highlight.define()
  eq(got, want, "the octo.nvim loaded and its groups defined")
  eq(editable, { bg = bg_of("NormalFloat") }, "DocketEditable follows no Octo* group")
  eq(kept, { fg = tonumber("ff0000", 16) }, "a group defined before define() keeps its definition")
end)

test("highlight: DocketEditable takes the first background that differs from Normal's, with its terminal colour, and links to CursorLine when none does", function()
  local normal = bg_of("Normal")
  local float, cursorline, column = bg_of("NormalFloat"), bg_of("CursorLine"), bg_of("ColorColumn")
  if
    normal == nil
    or float == nil
    or float == normal
    or cursorline == nil
    or cursorline == normal
    or column == nil
    or column == normal
  then
    error("the default colour scheme no longer gives NormalFloat, CursorLine and ColorColumn backgrounds of their own")
  end
  local function pick()
    clear_groups({ "DocketEditable" })
    highlight.define()
    return own_hl("DocketEditable")
  end
  local picked = {}
  picked.float = pick()
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = float, ctermbg = 237 })
  picked.terminal = pick()
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = normal })
  picked.cursorline = pick()
  vim.api.nvim_set_hl(0, "CursorLine", { bg = normal })
  picked.column = pick()
  vim.api.nvim_set_hl(0, "ColorColumn", { bg = normal })
  picked.none = pick()
  vim.cmd.colorscheme("default")
  local restored = { bg_of("NormalFloat"), bg_of("CursorLine"), bg_of("ColorColumn") }
  clear_groups({ "DocketEditable" })
  highlight.define()
  eq(picked, {
    float = { bg = float },
    terminal = { bg = float, ctermbg = 237 },
    cursorline = { bg = cursorline },
    column = { bg = column },
    none = { link = "CursorLine" },
  })
  eq(restored, { float, cursorline, column }, "the colour scheme puts the backgrounds back")
end)

test("highlight: define() chooses DocketEditable again while it holds define()'s own choice, and keeps a definition it did not make", function()
  clear_groups({ "DocketEditable" })
  highlight.define()
  local float = bg_of("NormalFloat")
  -- What a colour scheme that loads without :hi clear leaves: NormalFloat
  -- changed, and DocketEditable as define() set it.
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#123456" })
  highlight.define()
  local followed = own_hl("DocketEditable")
  vim.api.nvim_set_hl(0, "DocketEditable", { bg = "#ff00ff" })
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#654321" })
  highlight.define()
  local kept = own_hl("DocketEditable")
  -- A colour scheme's :hi clear empties it, and define() chooses it again.
  vim.cmd.colorscheme("default")
  highlight.define()
  local cleared = own_hl("DocketEditable")
  eq(followed, { bg = tonumber("123456", 16) }, "the background chosen before is replaced")
  eq(kept, { bg = tonumber("ff00ff", 16) }, "the configuration's own is kept")
  eq(cleared, { bg = float }, "after :hi clear")
end)

test("highlight: a status setup{} colours has a group of its own, set from a colour, a group's name or a table", function()
  eq(highlight.status_group("In Review"), "DocketStatusIn_Review")
  eq(highlight.status_group("Won't do / État"), "DocketStatusWon_t_do_tat", "each run of other characters is one _")
  local function hl(name)
    return vim.api.nvim_get_hl(0, { name = name, link = true })
  end
  eq(highlight.define({ ["In Review"] = { fg = "#f9e2af", bold = true }, Blocked = "DiagnosticError" }), {})
  local set = hl("DocketStatusIn_Review")
  eq({ set.fg, set.bold }, { tonumber("f9e2af", 16), true }, "a table as it is")
  eq(hl("DocketStatusBlocked"), { link = "DiagnosticError" }, "a group's name as a link")
  eq(highlight.state_group("Blocked", "indeterminate", "jira"), "DocketStatusBlocked")
  eq(highlight.define({ ["In Review"] = "#f9e2af" }), {})
  eq(hl("DocketStatusIn_Review"), { fg = tonumber("f9e2af", 16) }, "a # string as the foreground, not as a link")
  eq(highlight.state_group("Blocked", "indeterminate", "jira"), "DocketStatePending", "the table given replaces the last one")
  eq(({ highlight.configured() })[1], { { name = "In Review", group = "DocketStatusIn_Review" } })
  highlight.define({})
end)

test("highlight: a Jira state of a configured status renders in its group whatever its category, and no other source's does", function()
  highlight.define({ ["In Review"] = "#f9e2af", Closed = "DiagnosticHint" })
  eq(highlight.state_group("In Review", "indeterminate", "jira"), "DocketStatusIn_Review", "over its category")
  eq(highlight.state_group("in review", nil, "jira"), "DocketStatusIn_Review", "in any case")
  eq(highlight.state_group("In Review", nil, "jira"), "DocketStatusIn_Review", "with no category")
  eq(highlight.state_group("In Progress", "indeterminate", "jira"), "DocketStatePending", "a status not configured keeps its category's")
  eq(highlight.state_group("Closed", "done", "jira"), "DocketStatusClosed")
  eq(highlight.state_group("closed", nil, "glab"), "DocketStateClosed", "GitLab's closed is its own fixed word")
  eq(highlight.state_group("In Review", "indeterminate"), "DocketStatePending", "with no source, the category")
  -- With no argument, as the ColorScheme autocommand calls it, the statuses
  -- are kept and set again.
  vim.cmd("highlight clear DocketStatusIn_Review")
  eq(highlight.define(), {})
  eq(vim.api.nvim_get_hl(0, { name = "DocketStatusIn_Review" }).fg, tonumber("f9e2af", 16), "set again")
  eq(highlight.state_group("In Review", nil, "jira"), "DocketStatusIn_Review", "kept")
  highlight.define({})
end)

test("highlight: a status whose value cannot be set is named and keeps its category's group", function()
  -- A table's link to a name neovim cannot use, as to a colour, prints E5248
  -- from nvim_set_hl() without raising, and a number is taken as a group's id.
  local problems = highlight.define({
    Bad = "#zzz",
    Spaced = "Diagnostic Error",
    Number = 5,
    Typo = { fgg = "#ffffff" },
    Linked = { link = "Diagnostic Error" },
    Hashed = { link = "#f9e2af" },
    Numbered = { link = 5 },
    Fine = "#ffffff",
  })
  local because = "the status %s keeps its category's colour, because "
  eq(problems, {
    because:format("Bad") .. "nvim_set_hl() refused it: Invalid highlight color: '#zzz'",
    because:format("Hashed") .. "its link is not a highlight group's name",
    because:format("Linked") .. "its link is not a highlight group's name",
    because:format("Number") .. "its value is a number, where a colour, a group's name or a table goes",
    because:format("Numbered") .. "its link is not a highlight group's name",
    because:format("Spaced") .. "its value is neither a #rrggbb colour nor a highlight group's name",
    because:format("Typo") .. "nvim_set_hl() refused it: invalid key: fgg",
  })
  for _, name in ipairs({ "Bad", "Spaced", "Number", "Typo", "Linked", "Hashed", "Numbered" }) do
    eq(highlight.state_group(name, "new", "jira"), "DocketStateOpen", name)
  end
  eq({ highlight.configured() }, { { { name = "Fine", group = "DocketStatusFine" } }, problems })
  eq(highlight.define(), {}, "a define() that keeps the table reports nothing new")
  eq(({ highlight.configured() })[2], problems, "and leaves the last report in place")
  eq(
    highlight.define({ "In Review" }),
    { "the status 1 keeps its category's colour, because its key is no status name; each key is the status as Jira prints it" },
    "a list where a table of names goes"
  )
  highlight.define({})
  eq({ highlight.configured() }, { {}, {} })
end)

test("highlight: of two statuses that would share a group, the first in byte order takes it, and keeps it after a colour scheme change", function()
  -- status_group() makes each pair one group, and neovim matches a group's
  -- name in any case. Several pairs, so that an order other than the sorted
  -- one shows in at least one of them.
  local configured = {
    ["To Do"] = "#111111",
    ["To-Do"] = "#222222",
    Done = "#444444",
    DONE = "#333333",
    ["In Review"] = "#111111",
    ["In-Review"] = "#222222",
    ["Ready for QA"] = "#111111",
    ["Ready-for-QA"] = "#222222",
    ["Won't do"] = "#111111",
    ["Won t do"] = "#222222",
  }
  local because = "the status %s keeps its category's colour, because %s already renders in %s"
  eq(highlight.define(configured), {
    because:format("Done", "DONE", "DocketStatusDONE"),
    because:format("In-Review", "In Review", "DocketStatusIn_Review"),
    because:format("Ready-for-QA", "Ready for QA", "DocketStatusReady_for_QA"),
    because:format("To-Do", "To Do", "DocketStatusTo_Do"),
    because:format("Won't do", "Won t do", "DocketStatusWon_t_do"),
  })
  local groups = { "DocketStatusTo_Do", "DocketStatusDONE", "DocketStatusIn_Review", "DocketStatusReady_for_QA", "DocketStatusWon_t_do" }
  local function colours()
    local found = {}
    for _, group in ipairs(groups) do
      found[#found + 1] = ("%06x"):format(vim.api.nvim_get_hl(0, { name = group }).fg or 0)
    end
    return found
  end
  local expected = { "111111", "333333", "111111", "111111", "222222" }
  eq(colours(), expected)
  eq(
    vim.tbl_map(function(status)
      return status.name
    end, ({ highlight.configured() })[1]),
    { "DONE", "In Review", "Ready for QA", "To Do", "Won t do" },
    "one name for each group"
  )
  eq(highlight.state_group("To-Do", "new", "jira"), "DocketStateOpen", "the name refused keeps its category's group")
  eq(highlight.state_group("To Do", "new", "jira"), "DocketStatusTo_Do")
  eq(highlight.state_group("done", "done", "jira"), "DocketStatusDONE", "matched in any case")
  for _, group in ipairs(groups) do
    vim.cmd.highlight("clear", group)
  end
  eq(highlight.define(), {})
  eq(colours(), expected, "the ColorScheme re-set gives each group the colour setup gave it")
  -- A value nvim_set_hl() refuses takes no group, so the next name does.
  eq(highlight.define({ ["To Do"] = "#zzz", ["To-Do"] = "#222222" }), {
    "the status To Do keeps its category's colour, because nvim_set_hl() refused it: Invalid highlight color: '#zzz'",
  })
  eq(vim.api.nvim_get_hl(0, { name = "DocketStatusTo_Do" }).fg, tonumber("222222", 16))
  highlight.define({})
end)

test("buffer: open reads the item through its adapter after the state check, and clears modified", function()
  jira.forget()
  local wait_calls, restore_wait = stub_acli({ signed_in = true })
  local calls, restore_run = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local notices, restore_notify = stub_notify()
  local finished, ok, message
  local adapter = auth.ready("jira")
  local status_calls = #wait_calls
  local buf = buffer.open("jira", "TIG-1001", function(read_ok, read_message)
    finished, ok, message = true, read_ok, read_message
  end, adapter)
  vim.wait(1000, function()
    return finished
  end)
  eq(#wait_calls, status_calls, "the adapter handed down means the read asks for the state no second time")
  local first_ok, first_message = ok, message
  finished = false
  local second = buffer.open("jira", "TIG-1001", function()
    finished = true
  end)
  vim.wait(1000, function()
    return finished
  end)
  restore_run()
  restore_wait()
  restore_notify()
  eq(first_ok, true, first_message)
  eq(first_message, nil)
  eq(notices, {})
  eq(second, buf, "a second open is the same buffer")
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(vim.api.nvim_buf_get_name(buf), "docket://jira/TIG-1001")
  eq(calls[#calls].argv, argv_of("workitem", "view", "TIG-1001", "--fields", jira.VIEW_FIELDS, "--json"))
  eq(vim.api.nvim_buf_get_lines(buf, 0, 2, false)[2], "# Retry backoff drops the last attempt")
  eq(vim.bo[buf].modified, false)
  eq(vim.b[buf].docket.id, "TIG-1001")
  eq(vim.tbl_count(vim.b[buf].docket.snapshot.regions), 3)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("buffer: a read on a backend not signed in reports the login command and reads nothing", function()
  local _, restore_wait = stub_acli({ signed_in = false })
  local calls, restore_run = stub_run(function(argv)
    return done(argv, {})
  end)
  local notices, restore_notify = stub_notify()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, buffer.name("jira", "PROJ-9"))
  local finished, ok, message
  buffer.read(buf, function(read_ok, read_message)
    finished, ok, message = true, read_ok, read_message
  end)
  vim.wait(200, function()
    return finished
  end)
  restore_run()
  restore_wait()
  restore_notify()
  eq(ok, false)
  eq(message:find(":Docket login jira", 1, true) ~= nil, true, message)
  eq(#calls, 0, "no client call after the state check")
  eq(#notices, 1)
  eq(notices[1].level, vim.log.levels.ERROR)
  eq(vim.bo[buf].buftype, "acwrite", "the options are set even so")
end)

test("buffer: a buffer holding unsaved edits is not read into, whether they came before the read or while the client ran", function()
  jira.forget()
  local name = buffer.name("jira", "TIG-1001")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local _, restore_wait = stub_acli({ signed_in = true })
  local runs, restore_run = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local notices, restore_notify = stub_notify()
  local answers = {}
  local function record(ok, message)
    answers[#answers + 1] = { ok, message }
  end
  local refusal = "docket://jira/TIG-1001 holds unsaved edits, so the item is not read into it; :e! discards them and reads it"

  local buf = buffer.open("jira", "TIG-1001", record)
  vim.wait(1000, function()
    return #answers == 1
  end)
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local asked = #runs
  eq(buffer.open("jira", "TIG-1001", record), buf)
  eq(answers[2], { false, refusal }, "refused at once")
  eq(#runs, asked, "the client is not asked for the item")
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "XThe retry loop re-enters" }, "the edit is kept")
  eq(vim.bo[buf].modified, true)
  restore_run()
  vim.api.nvim_buf_delete(buf, { force = true })

  -- The edit is typed while the client runs: the answer lands on a buffer
  -- that has changed since the read was asked for.
  local pending, saved = {}, spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  buf = buffer.open("jira", "TIG-1001", record)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "typed while the client ran" })
  while #pending > 0 do
    local call = table.remove(pending, 1)
    call.on_done(done(call.argv, call.argv[4] == "search" and { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) } or view_payload()))
  end
  spawn.run = saved
  vim.wait(1000, function()
    return #answers == 3
  end)
  restore_notify()
  restore_wait()
  eq(answers[1], { true, nil })
  eq(answers[3], { false, refusal })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "typed while the client ran" })
  eq(vim.bo[buf].modified, true)
  eq(vim.b[buf].docket, nil, "nothing was loaded over the edit")
  eq(notices, { { message = refusal, level = vim.log.levels.WARN }, { message = refusal, level = vim.log.levels.WARN } })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- the commands ----------------------------------------------------------------------------

test("commands: an identifier's shape names its adapter", function()
  eq({ commands.source_of("PROJ-142") }, { "jira" })
  eq({ commands.source_of("A1-7") }, { "jira" })
  eq({ commands.source_of("!482") }, { "glab" })
  eq({ commands.source_of("#12") }, { "gh" })
  local source, err = commands.source_of("proj-142")
  eq(source, nil)
  eq(err:find("PROJ-142", 1, true) ~= nil, true, err)
  eq(err:find("#12", 1, true) ~= nil, true, "the refusal names every shape: " .. err)
  eq(commands.source_of("PROJ-142abc"), nil)
end)

test("commands: the launcher's warning is printed beside the path, never dropped", function()
  local base = { path = "/w/PROJ-1-x", branch = "PROJ-1-x", window = "PROJ-1-x" }
  local message, level = commands.describe(vim.tbl_extend("force", base, { how = "tmux", editor = "PROJ-1-x", shell = "PROJ-1-x-sh" }))
  eq(message, "worktree /w/PROJ-1-x on PROJ-1-x\ntmux windows PROJ-1-x and PROJ-1-x-sh")
  eq(level, vim.log.levels.INFO)
  -- Every warning a launch with no companion comes back with: the listing held
  -- none, it held two, or a step addressed to it failed. The line before the
  -- warning holds for each, so none of them is contradicted.
  for _, warning in ipairs({
    "tmux lists no window named PROJ-1-x-sh after new-window -S made it; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    "tmux lists more than one window named PROJ-1-x-sh: @4, @9; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds",
    "tmux exited 1\ncan't find window: @4",
  }) do
    message, level = commands.describe(vim.tbl_extend("force", base, {
      how = "tmux",
      editor = "PROJ-1-x",
      shell = nil,
      warning = warning,
    }))
    eq(
      message,
      "worktree /w/PROJ-1-x on PROJ-1-x\n"
        .. "tmux window PROJ-1-x; the companion window is not confirmed, and the warning below names what went wrong first\n"
        .. "warning: "
        .. warning
    )
    eq(level, vim.log.levels.WARN)
  end
  message, level = commands.describe(vim.tbl_extend("force", base, {
    how = "tab",
    script = "tmux new-window -S -n 'PROJ-1-x' -c '/w/PROJ-1-x' 'nvim'",
    warning = "E492: Not an editor command: Docket review !4",
  }))
  eq(message:find("a tab of this editor is at the worktree", 1, true) ~= nil, true, message)
  eq(message:find("tmux new-window -S -n 'PROJ-1-x'", 1, true) ~= nil, true, "the script follows the path")
  eq(message:find("warning: E492", 1, true) ~= nil, true, message)
  eq(level, vim.log.levels.WARN)
end)

test("commands: :Docket review opens the review mode on the merge request's adapter, and a malformed argument list is refused", function()
  -- The review mode is built, and `:Docket review !4` is the command the
  -- launcher's editor window runs for R, so it reaches review.open() with the
  -- adapter the identifier names. No adapter is handed down: review.open()
  -- makes the state check itself, after the check that diffview is there.
  local opened, saved_open = {}, review.open
  review.open = function(source, id, adapter)
    opened[#opened + 1] = { source = source, id = id, adapter = adapter ~= nil }
  end
  local notices, restore = stub_notify()
  commands.run({ fargs = { "review", "!4" }, bang = false })
  commands.run({ fargs = { "PROJ-1", "PROJ-2" }, bang = false })
  commands.run({ fargs = { "lower-1" }, bang = false })
  restore()
  review.open = saved_open
  eq(opened, { { source = "glab", id = "!4", adapter = false } })
  eq(notices[1].message:find("one identifier", 1, true) ~= nil, true, notices[1].message)
  eq(notices[2].level, vim.log.levels.ERROR)
  eq(#notices, 2)
end)

test("commands: an item on a backend not signed in names the login command", function()
  local _, restore_wait = stub_acli({ signed_in = false })
  local notices, restore_notify = stub_notify()
  local buf = commands.item("PROJ-142")
  restore_notify()
  restore_wait()
  eq(buf, nil)
  eq(#notices, 1)
  eq(notices[1].message:find("jira: not signed in; run :Docket login jira", 1, true), 1, notices[1].message)
end)

test("commands: an item asks the client for the state once, and a backend not signed in is one notice", function()
  jira.forget()
  local wait_calls, restore_wait = stub_acli({ signed_in = true })
  local run_calls, restore_run = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local notices, restore_notify = stub_notify()
  local buf = commands.item("TIG-1001")
  vim.wait(1000, function()
    return vim.b[buf].docket ~= nil
  end)
  commands.item("!482")
  restore_notify()
  restore_run()
  restore_wait()
  local status = 0
  for _, call in ipairs(wait_calls) do
    if call.argv[4] == "status" then
      status = status + 1
    end
  end
  eq(status, 1, "one auth status for the open")
  eq(run_calls[#run_calls].argv[4], "view")
  eq(notices, {
    { message = "glab: not signed in; run :Docket login glab\nglab exited 1\nx glab: no token", level = vim.log.levels.ERROR },
  })
  eq(adapters.get("gh"), require("docket.adapters.gh"), "the registry loads and verifies the GitHub adapter")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("commands: the launcher from an item buffer refuses a merge request whose read stored no branch, and a buffer with nothing loaded, before git runs", function()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.b[buf].docket = { source = "glab", id = "!482", title = "Bump the pin" }
  local notices, restore = stub_notify()
  commands.work(buf)
  commands.review_item(buf)
  commands.work(vim.api.nvim_create_buf(false, false))
  restore()
  eq(notices, {
    { message = "!482 carries no branch, so no worktree is made for it", level = vim.log.levels.ERROR },
    { message = "!482 carries no branch, so no worktree is made for it", level = vim.log.levels.ERROR },
    { message = "nothing loaded in this buffer; :e reads the item", level = vim.log.levels.ERROR },
  })
end)

test("commands: login names the backend given, or Jira and the remote's client", function()
  local asked = {}
  local saved_login = auth.login
  auth.login = function(name, opts)
    asked[#asked + 1] = { name, opts.force }
    return true, name .. ": signed in"
  end
  local saved_root, saved_url = repo.root, repo.remote_url
  repo.root = function()
    return { root = "/w/repo", bare = true }
  end
  repo.remote_url = function()
    return "git@gitlab.example.test:acme/payments.git"
  end
  local notices, restore_notify = stub_notify()
  commands.run({ fargs = { "login", "jira" }, bang = true })
  commands.run({ fargs = { "login" }, bang = false })
  restore_notify()
  auth.login, repo.root, repo.remote_url = saved_login, saved_root, saved_url
  eq(asked, { { "jira", true }, { "jira", false }, { "glab", false } })
  eq(#notices, 3)
  eq(notices[1].level, vim.log.levels.INFO)
  local _, restore_wait = stub_wait(function(argv)
    return { argv = argv, ok = false, code = 128, stdout = "", stderr = "fatal: not a git repository\n", timed_out = false }
  end)
  local outside = commands.backends("/w/outside")
  restore_wait()
  eq(outside, { "jira" }, "outside a clone, Jira alone")
end)

test("commands: gx opens the adapter's url, and completion offers the subcommands then the backends", function()
  local _, restore_wait = stub_acli({ signed_in = true })
  jira.auth_status()
  restore_wait()
  local asked, restore_prompts = stub_prompts({})
  local buf = loaded_buffer()
  commands.browse(buf)
  restore_prompts()
  eq(asked, { "open https://example.atlassian.net/browse/PROJ-142" })
  local saved_open = vim.ui.open
  vim.ui.open = function()
    return nil, "vim.ui.open: no handler found"
  end
  local notices, restore_notify = stub_notify()
  commands.browse(buf)
  restore_notify()
  vim.ui.open = saved_open
  eq(notices, { { message = "vim.ui.open: no handler found", level = vim.log.levels.WARN } })
  eq(commands.complete("", "Docket "), { "create", "login", "review" })
  eq(commands.complete("r", "Docket r"), { "review" })
  eq(commands.complete("", "Docket login "), row.SOURCES)
  eq(commands.complete("g", "Docket! login g"), { "glab", "gh" })
end)

-- the in-flight join ----------------------------------------------------------------------

-- A join of its own, with every request it starts and every answer each
-- waiter receives recorded. `accept` records the key and the values it is
-- given, and runs the function `raise` names when that is set.
local function recorded_flight(refusal)
  local log = { requests = {}, accepted = {}, order = {} }
  local joined = flight.new({
    refusal = refusal or "refused",
    accept = function(key, ...)
      log.order[#log.order + 1] = "accept"
      if log.raise then
        error(log.raise, 0)
      end
      log.accepted[#log.accepted + 1] = { key, ... }
    end,
  })
  log.request = function(settle)
    log.requests[#log.requests + 1] = settle
  end
  log.waiter = function(name)
    log[name] = {}
    return function(...)
      log.order[#log.order + 1] = name
      log[name][#log[name] + 1] = { n = select("#", ...), ... }
    end
  end
  return joined, log
end

test("flight: a second caller joins the request in flight, and every waiter gets every value once, after accept", function()
  local joined, log = recorded_flight()
  eq(joined:pending("k"), false)
  eq(joined:join("k", log.request, log.waiter("first")), true, "the first caller starts the request")
  eq(joined:join("k", log.request, log.waiter("second")), false, "the second joins it")
  eq(#log.requests, 1)
  eq(joined:pending("k"), true)
  eq(joined:join("other", log.request, log.waiter("elsewhere")), true, "another key is a request of its own")
  eq(#log.requests, 2)
  -- A nil in the middle and one at the end are values like any other.
  log.requests[1]({ "row" }, nil, "a warning", nil)
  eq(log.first, { { { "row" }, nil, "a warning", nil, n = 4 } })
  eq(log.second, log.first)
  eq(log.accepted, { { "k", { "row" }, nil, "a warning" } })
  eq(log.order, { "accept", "first", "second" }, "what accept keeps is in place before any waiter sees it")
  eq(joined:pending("k"), false, "the answer frees the key")
  eq(joined:pending("other"), true)
  eq(joined:join("k", log.request, log.waiter("third")), true, "and the next caller starts afresh")
  eq(#log.requests, 3)
end)

test("flight: a settle called twice answers once", function()
  local joined, log = recorded_flight()
  joined:join("k", log.request, log.waiter("first"))
  log.requests[1]("once")
  log.requests[1]("twice")
  eq(log.first, { { "once", n = 1 } })
  eq(log.accepted, { { "k", "once" } }, "and accept is not run again")
  -- The second settle of a request is no answer to the one after it.
  joined:join("k", log.request, log.waiter("later"))
  log.requests[1]("late")
  eq(log.later, {}, "a request's settle answers its own waiters alone")
  eq(joined:pending("k"), true)
end)

test("flight: an answer landing after an invalidate is refused, and accept never sees it", function()
  local joined, log = recorded_flight(function(key)
    return key .. ": moved on"
  end)
  joined:join("k", log.request, log.waiter("first"))
  joined:join("k", log.request, log.waiter("second"))
  joined:invalidate("k")
  eq(joined:pending("k"), false, "the request in flight is not one a later caller would join")
  log.requests[1]({ "stale row" })
  eq(log.first, { { nil, "k: moved on", n = 2 } }, "the refusal is a function of the key")
  eq(log.second, log.first, "and it reaches every caller that joined the stale request")
  eq(log.accepted, {})
  -- An invalidate with nothing in flight refuses nothing: the next request
  -- starts in the generation it moved to.
  joined:invalidate("idle")
  joined:join("idle", log.request, log.waiter("idle"))
  log.requests[2]("fresh")
  eq(log.idle, { { "fresh", n = 1 } })
  local plain, plain_log = recorded_flight("a login ran")
  plain:join("k", plain_log.request, plain_log.waiter("first"))
  plain:invalidate("k")
  plain_log.requests[1]("stale")
  eq(plain_log.first, { { nil, "a login ran", n = 2 } }, "or a string")
end)

test("flight: a caller after an invalidate starts its own request, and the stale settle leaves that one's slot alone", function()
  local joined, log = recorded_flight()
  joined:join("k", log.request, log.waiter("stale"))
  joined:invalidate("k")
  eq(joined:join("k", log.request, log.waiter("fresh")), true, "rather than waiting out a request only to be refused")
  eq(joined:join("k", log.request, log.waiter("joined")), false, "and the next caller joins the fresh one")
  eq(#log.requests, 2)
  log.requests[1]("old")
  eq(log.stale, { { nil, "refused", n = 2 } })
  eq({ log.fresh, log.joined }, { {}, {} }, "the fresh request's callers wait for its own answer")
  eq(joined:pending("k"), true, "the stale settle did not clear the fresh request's slot")
  eq(joined:join("k", log.request, log.waiter("later")), false, "so a later caller still joins it")
  eq(#log.requests, 2)
  log.requests[2]("new")
  for _, name in ipairs({ "fresh", "joined", "later" }) do
    eq(log[name], { { "new", n = 1 } }, name)
  end
  eq(log.stale, { { nil, "refused", n = 2 } }, "and the stale caller is not answered again")
  eq(log.accepted, { { "k", "new" } })
  eq(joined:pending("k"), false)
end)

test("flight: invalidate_all moves on every key with a request in flight", function()
  local joined, log = recorded_flight()
  joined:join("a", log.request, log.waiter("a"))
  joined:join("b", log.request, log.waiter("b"))
  joined:invalidate_all()
  eq({ joined:pending("a"), joined:pending("b") }, { false, false })
  log.requests[1]("rows")
  log.requests[2]("rows")
  eq({ log.a, log.b }, { { { nil, "refused", n = 2 } }, { { nil, "refused", n = 2 } } })
  eq(log.accepted, {})
end)

test("flight: a request that raises answers its waiters and frees the slot; one that raises after answering is reported once", function()
  local joined, log = recorded_flight()
  local started = joined:join("k", function()
    error("no client")
  end, log.waiter("first"))
  eq(started, true)
  eq(log.first[1].n, 2)
  eq(log.first[1][1], nil)
  eq(log.first[1][2]:find("no client", 1, true) ~= nil, true, log.first[1][2])
  -- The error is the answer, and accept is handed it as one: the cache and
  -- every whoami() keep nothing when the first value is nil.
  eq(log.accepted, { { "k", nil, log.first[1][2] } })
  eq(joined:pending("k"), false, "the slot is free, where otherwise every later caller would join a request that never answers")
  eq(joined:join("k", log.request, log.waiter("next")), true)

  local notices, restore = stub_notify()
  joined:join("late", function(settle)
    settle("answered")
    error("raised after answering", 0)
  end, log.waiter("late"))
  vim.wait(1000, function()
    return #notices > 0
  end)
  restore()
  eq(log.late, { { "answered", n = 1 } }, "the waiter keeps the answer and is not answered again")
  eq(notices, { { message = "raised after answering", level = vim.log.levels.ERROR } }, "there is nobody left to hand the error to")
end)

test("flight: an accept that raises gives every waiter nil and what it raised", function()
  local joined, log = recorded_flight()
  log.raise = "disk full"
  joined:join("k", log.request, log.waiter("first"))
  joined:join("k", log.request, log.waiter("second"))
  log.requests[1]({ "row" })
  eq(log.first, { { nil, "disk full", n = 2 } })
  eq(log.second, log.first)
  eq(joined:pending("k"), false)
end)

test("flight: a waiter that raises is reported, and the waiters behind it are still answered", function()
  local joined, log = recorded_flight()
  joined:join("k", log.request, function()
    error("the first caller raised", 0)
  end)
  joined:join("k", log.request, log.waiter("second"))
  -- The settle runs where a spawn callback would, in a fast event, where
  -- vim.notify is refused; the report is scheduled out of it. The stand-in
  -- records where it was called from, since it would not refuse itself.
  local notices, saved = {}, vim.notify
  vim.notify = function(message, level)
    -- nvim's own notice, which stub_notify leaves out for the reason it states.
    if not tostring(message):find("^log: ") then
      notices[#notices + 1] = { message = message, level = level, fast = vim.in_fast_event() }
    end
  end
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    timer:close()
    log.requests[1]("answer")
  end)
  vim.wait(1000, function()
    return #notices > 0
  end)
  vim.notify = saved
  eq(log.second, { { "answer", n = 1 } })
  eq(notices, { { message = "the first caller raised", level = vim.log.levels.ERROR, fast = false } })
end)

-- the cache -------------------------------------------------------------------------------

-- Points the cache at a directory of its own for one test, and hands back the
-- function that restores the configured one and removes the directory.
local function scratch_cache()
  local saved = config.options.cache_dir
  local dir = vim.fn.tempname()
  config.options.cache_dir = dir
  return dir, function()
    config.options.cache_dir = saved
    vim.fn.delete(dir, "rf")
  end
end

local ROWS = {
  row.new({ source = "jira", id = "PAY-9", state = "To Do", title = "Nine" }),
  row.new({ source = "jira", id = "PAY-10", state = "In Progress", title = "Ten" }),
}

test("cache: the key is the adapter, the clone a client resolves in, and the query", function()
  eq(cache.key("jira", "project IN (PAY)" .. OPEN), "jira project IN (PAY)" .. OPEN)
  eq(cache.key("glab", { "mr", "list", "--reviewer=@me" }), "glab mr list --reviewer=@me")
  eq(cache.key("glab", { "mr", "list", "--reviewer=@me" }, "/w/payments"), "glab /w/payments mr list --reviewer=@me")
  eq(
    cache.key("glab", { "mr", "list" }, "/w/a") ~= cache.key("glab", { "mr", "list" }, "/w/b"),
    true,
    "one query in two clones is two keys, because the client reads the project from the working directory"
  )
  eq(cache.name("a") ~= cache.name("b"), true, "two keys, two files")
  eq(cache.name("a"), "0002b60600000061", "a key's file is the same in every release, so an upgrade does not orphan the cache")
  eq(#cache.name("jira project IN (PAY)" .. OPEN), 16)
  eq(cache.path("k"), config.options.cache_dir .. "/" .. cache.name("k") .. ".json")
end)

test("cache: rows round-trip with the moment they were written, under a private mode", function()
  local dir, restore = scratch_cache()
  local key = cache.key("jira", "project IN (PAY)" .. OPEN)
  eq(cache.read(key), nil, "a miss before any write")
  eq(cache.write(key, ROWS, 1000), true)
  eq(cache.read(key), { rows = ROWS, written = 1000 })
  -- An adapter adds fields beyond the ones row.new returns -- `updated` on
  -- every row, a merge request's `url` -- and read() holds each entry to
  -- row.new rather than replacing it with what row.new built.
  local extra = vim.tbl_extend("error", ROWS[1], { updated = "2024-05-03T10:00:00.000+0000", url = "https://jira.example.test/browse/PAY-9" })
  eq(cache.write(key, { extra }, 1500), true)
  eq(cache.read(key), { rows = { extra }, written = 1500 }, "what the adapter added beyond the rendered fields comes back")
  eq(cache.write(key, {}, 2000), true)
  eq(cache.read(key), { rows = {}, written = 2000 }, "an empty section is cached too")
  local file = vim.uv.fs_stat(cache.path(key))
  eq(bit.band(file.mode, 511), 384, "0600")
  eq(bit.band(vim.uv.fs_stat(dir).mode, 511), 448, "0700")
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(cache.path(key)), "\n"))
  eq(decoded.key, key, "the key is inside the file")
  eq(decoded.format, 2, "and so is the format, which the read below holds it to")
  eq(#vim.fn.glob(dir .. "/*.tmp", false, true), 0, "no temporary file left")
  cache.drop(key)
  eq(cache.read(key), nil, "dropped")
  restore()
end)

test("cache: an absent directory, one that cannot be written, a file that is not JSON, and one of another format are each a miss", function()
  local dir, restore = scratch_cache()
  local key = "jira q"
  config.options.cache_dir = dir .. "/absent/deeper"
  eq(cache.read(key), nil, "absent directory")
  eq(cache.write(key, ROWS), true, "the directory is made on the first write")
  eq(cache.read(key).rows, ROWS)

  vim.fn.mkdir(dir .. "/sealed", "p")
  vim.uv.fs_chmod(dir .. "/sealed", tonumber("555", 8))
  config.options.cache_dir = dir .. "/sealed/inside"
  eq(cache.write(key, ROWS), false, "a directory that cannot be made")
  config.options.cache_dir = dir .. "/sealed"
  eq(cache.write(key, ROWS), false, "a directory that cannot be written into")
  eq(cache.read(key), nil)
  vim.uv.fs_chmod(dir .. "/sealed", tonumber("755", 8))

  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "" }, dir .. "/afile")
  config.options.cache_dir = dir .. "/afile"
  eq(cache.write(key, ROWS), false, "a cache directory that exists as a file")
  eq(cache.read(key), nil)

  config.options.cache_dir = dir
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "not json" }, cache.path(key))
  eq(cache.read(key), nil, "not JSON")
  vim.fn.writefile({ "[1, 2]" }, cache.path(key))
  eq(cache.read(key), nil, "JSON of the wrong shape")
  -- The format is spelled out rather than read off the module: a file of
  -- the shape the module writes today is what has to be read, and one of
  -- another shape, or of none, has to be a miss, so that a row cached under
  -- an older shape is fetched again rather than shown without a field the
  -- current shape carries.
  vim.fn.writefile({ vim.json.encode({ format = 2, key = key, written = 1, rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), { rows = ROWS, written = 1 }, "a file of the current format is read")
  vim.fn.writefile({ vim.json.encode({ key = key, written = 1, rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), nil, "a file of no format")
  vim.fn.writefile({ vim.json.encode({ format = 1, key = key, written = 1, rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), nil, "a file of another format")
  vim.fn.writefile({ vim.json.encode({ format = "2", key = key, written = 1, rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), nil, "a format that is not a number")
  vim.fn.writefile({ vim.json.encode({ format = 2, key = "jira other", written = 1, rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), nil, "another key's rows under this key's name")
  vim.fn.writefile({ vim.json.encode({ format = 2, key = key, written = "1", rows = ROWS }) }, cache.path(key))
  eq(cache.read(key), nil, "a written moment that is not a number")
  vim.fn.writefile({ '{"format":2,"key":"jira q","written":1,"rows":{"PAY-1":{"id":"PAY-1"}}}' }, cache.path(key))
  eq(cache.read(key), nil, "rows as an object, which ipairs reads as none at all")
  vim.fn.writefile({ vim.json.encode({ format = 2, key = key, written = 1, rows = { { source = "jira", id = "PAY-1" } } }) }, cache.path(key))
  eq(cache.read(key), nil, "a row with none of the fields the dashboard renders")
  local unknown = vim.tbl_extend("force", ROWS[1], { source = "bitbucket" })
  vim.fn.writefile({ vim.json.encode({ format = 2, key = key, written = 1, rows = { ROWS[1], unknown } }) }, cache.path(key))
  eq(cache.read(key), nil, "one row from no adapter, which would kill the render inside :Docket")
  cache.clear()
  eq(#vim.fn.glob(dir .. "/*.json", false, true), 0, "clear removes every row file")
  restore()
end)

test("cache: a write that stops part way is reported and leaves nothing behind", function()
  local dir, restore = scratch_cache()
  local key = "jira q"
  local saved = vim.uv.fs_write
  -- A file system that fills part way through: fs_write answers with the
  -- bytes it took, and the rest of the rows never reach the file.
  vim.uv.fs_write = function(fd, data)
    return saved(fd, data:sub(1, math.floor(#data / 2)))
  end
  local ok = cache.write(key, ROWS)
  vim.uv.fs_write = saved
  eq(ok, false)
  eq(cache.read(key), nil, "the short file is not renamed into place")
  eq(#vim.fn.glob(dir .. "/*.tmp", false, true), 0, "and it is not left beside the name it would have taken")

  local saved_rename = vim.uv.fs_rename
  vim.uv.fs_rename = function()
    return nil
  end
  ok = cache.write(key, ROWS)
  vim.uv.fs_rename = saved_rename
  eq(ok, false, "a rename that fails is not a write either")
  eq(#vim.fn.glob(dir .. "/*.tmp", false, true), 0, "and the file it wrote is removed")

  eq(cache.write(key, ROWS), true, "the next write answers as usual")
  eq(cache.read(key).rows, ROWS)
  restore()
end)

test("cache: one request in flight per key, and a second ask joins the first", function()
  local _, restore = scratch_cache()
  local key = "jira q"
  local asked, deliver = 0, nil
  local function request(hand)
    asked = asked + 1
    deliver = hand
  end
  local got = {}
  local function waiter(name)
    return function(rows, err, warning)
      got[#got + 1] = { name, rows, err, warning }
    end
  end
  eq(cache.fetch(key, request, waiter("first")), true)
  eq(cache.fetch(key, request, waiter("second")), false, "the second ask joins")
  eq(asked, 1, "one request")
  eq(cache.pending(key), true)
  eq(got, {}, "nothing delivered yet")
  deliver(ROWS, nil, "one row was left out")
  eq(cache.pending(key), false)
  eq(got, { { "first", ROWS, nil, "one row was left out" }, { "second", ROWS, nil, "one row was left out" } })
  deliver(ROWS, nil, "one row was left out")
  eq(#got, 2, "an adapter that hands its rows over twice answers each waiter once")
  eq(cache.read(key).rows, ROWS, "a successful answer is written")
  eq(cache.fetch(key, request, waiter("third")), true, "after the answer, a new request starts")
  eq(asked, 2)
  deliver(nil, "acli exited 1")
  eq(got[3], { "third", nil, "acli exited 1" })
  eq(cache.read(key).rows, ROWS, "a failed answer leaves the cached rows")
  eq(cache.fetch("jira other", function()
    error("no client")
  end, waiter("raised")), true)
  eq(got[4][1], "raised")
  eq(got[4][2], nil)
  eq(got[4][3]:find("no client", 1, true) ~= nil, true, got[4][3])
  eq(cache.pending("jira other"), false, "a request that raised frees its key")
  restore()
end)

test("cache: a waiter that raises is reported, and the rows are still written and reach the waiters behind it", function()
  local _, restore = scratch_cache()
  local key = "jira q"
  local deliver
  cache.fetch(key, function(hand)
    deliver = hand
  end, function()
    error("a section's paint raised", 0)
  end)
  local got
  cache.fetch(key, function()
    error("the second ask joins; its request is never called")
  end, function(rows)
    got = rows
  end)
  local notices, restore_notify = stub_notify()
  deliver(ROWS)
  vim.wait(1000, function()
    return #notices > 0
  end)
  restore_notify()
  eq(got, ROWS)
  eq(cache.read(key).rows, ROWS)
  eq(notices, { { message = "a section's paint raised", level = vim.log.levels.ERROR } })
  eq(cache.pending(key), false)
  restore()
end)

test("cache: a caller arriving after a drop asks the client itself rather than joining the abandoned request", function()
  local _, restore = scratch_cache()
  local key = "jira q"
  local hands = {}
  local function request(hand)
    hands[#hands + 1] = hand
  end
  local got = {}
  local function waiter(name)
    return function(rows, err)
      got[#got + 1] = { name, rows, err }
    end
  end
  eq(cache.fetch(key, request, waiter("before")), true)
  cache.drop(key)
  eq(cache.pending(key), false, "the request in flight is not one a later ask would join")
  eq(cache.fetch(key, request, waiter("after")), true, "so the later ask spawns its own")
  eq(#hands, 2)
  hands[1](ROWS, nil, "a warning")
  eq(#got, 1, "the abandoned request answers the caller that started it and nobody else")
  eq(got[1][1], "before")
  eq(got[1][2], nil)
  eq(got[1][3]:find("dropped while the request was in flight", 1, true) ~= nil, true, got[1][3])
  eq(cache.read(key), nil, "and nothing it fetched is written")
  eq(cache.pending(key), true, "the request that started after the drop is the one in flight")
  eq(cache.fetch(key, request, waiter("later")), false, "so a third caller joins that one rather than spawning again")
  eq(#hands, 2)
  hands[2](ROWS)
  eq(got[2], { "after", ROWS, nil }, "the caller that asked after the drop gets the rows")
  eq(got[3], { "later", ROWS, nil }, "and so does the one that joined it")
  eq(cache.read(key).rows, ROWS)
  eq(cache.pending(key), false)
  restore()
end)

test("cache: an answer landing after its key was dropped is neither written nor shown", function()
  local _, restore = scratch_cache()
  local key = "jira q"
  local deliver
  local got
  cache.fetch(key, function(hand)
    deliver = hand
  end, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  cache.drop(key)
  deliver(ROWS, nil, "a warning")
  eq(got[1], nil)
  eq(got[2]:find("dropped while the request was in flight", 1, true) ~= nil, true, got[2])
  eq(got[3], nil, "the warning goes with the rows")
  eq(cache.read(key), nil, "not written")
  eq(cache.pending(key), false)

  cache.fetch(key, function(hand)
    deliver = hand
  end, function(rows)
    got = { rows }
  end)
  cache.clear()
  deliver(ROWS)
  eq(got[1], nil, "clear supersedes a request in flight too")

  cache.fetch(key, function(hand)
    deliver = hand
  end, function(rows)
    got = { rows }
  end)
  deliver(ROWS)
  eq(got[1], ROWS, "the next request answers as usual")
  eq(cache.read(key).rows, ROWS)
  restore()
end)

test("cache: a write to an item drops the keys whose rows hold it, and every answer in flight, which may predate it", function()
  local _, restore = scratch_cache()
  cache.write("jira holding", ROWS)
  cache.write("jira other", { row.new({ source = "jira", id = "PAY-11", state = "To Do", title = "Eleven" }) })
  local deliver
  local got
  cache.fetch("jira no file yet", function(hand)
    deliver = hand
  end, function(rows, err)
    got = { rows, err }
  end)
  local dropped = cache.drop_item("jira", "PAY-10")
  -- The search started before the write answers with the item as it was.
  deliver({ row.new({ source = "jira", id = "PAY-10", state = "To Do", title = "Ten" }) })
  eq(dropped, { "jira holding" })
  eq(cache.read("jira holding"), nil)
  eq(cache.read("jira other") ~= nil, true, "a key whose rows do not hold it is kept")
  eq(got[1], nil, "the answer in flight is not shown")
  eq(tostring(got[2]):find("dropped while the request was in flight", 1, true) ~= nil, true, got[2])
  eq(cache.read("jira no file yet"), nil, "nor written")
  restore()
end)

test("cache: a login drops every key, because the key names no account", function()
  local dir, restore = scratch_cache()
  local mine = cache.key("jira", "assignee = currentUser()" .. OPEN)
  local reviews = cache.key("glab", { "mr", "list", "--reviewer=@me" }, "/w/repo")
  eq(cache.write(mine, ROWS), true)
  eq(cache.write(reviews, ROWS), true)
  local restore_acli = select(2, stub_acli({ signed_in = false, login = function(argv)
    return done(argv, "")
  end }))
  local restore_prompts = select(2, stub_prompts({ input = "me@example.test", secret = "tok", confirm = 2 }))
  -- The scratch directory is passed through configure(), which rebuilds the
  -- options from the defaults: the login would otherwise clear the directory
  -- the environment names and these reads would answer from a third one.
  config.configure({ jira = { site = "example.atlassian.net" }, cache_dir = dir })
  local ok, message = auth.login("jira")
  restore_prompts()
  restore_acli()
  eq(ok, true, message)
  eq(config.options.cache_dir, dir, "the login read the keys these assertions read")
  eq(cache.read(mine), nil, "the rows the account that signed out fetched")
  eq(cache.read(reviews), nil, "and every other backend's, since none of the keys says whose they are")
  config.configure({})
  restore()
end)

-- the dashboard ---------------------------------------------------------------------------

-- The clone the dashboard is opened on: repo's lookups run git through
-- spawn.wait, and the tests give the clone its binding and its remote directly.
local function stub_clone(binding, url)
  local saved = { root = repo.root, binding = repo.binding, remote_url = repo.remote_url }
  repo.root = function()
    return { root = "/w/repo", bare = true }
  end
  repo.binding = function()
    return binding
  end
  repo.remote_url = function()
    return url
  end
  return function()
    repo.root, repo.binding, repo.remote_url = saved.root, saved.binding, saved.remote_url
  end
end

-- A search row for the dashboard: a status of nil is a row the client left
-- without one, which row.new refuses.
local function dash_row(key, status, summary)
  return found(key, {
    summary = summary,
    status = status and { name = status } or nil,
    assignee = user("acc-me", "Me Myself"),
    reporter = user("acc-ana", "Ana"),
    updated = "2024-05-03T10:00:00.000+0000",
  })
end

-- Runs every callback already scheduled: one scheduled here is queued behind
-- them, and vim.wait pumps the loop until it has run.
local function drained()
  local ran = false
  vim.schedule(function()
    ran = true
  end)
  return vim.wait(2000, function()
    return ran
  end)
end

-- Waits for every section's state check and then its request to answer. The
-- callbacks already queued are run first, because a check's answer is
-- settled from a scheduled callback even when the client answered at once.
local function settled(buf)
  if not drained() then
    return false
  end
  return vim.wait(2000, function()
    for _, section in ipairs(list.state(buf).sections) do
      if section.status == "checking" or section.status == "fetching" then
        return false
      end
    end
    return true
  end)
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

test("list: the lines carry each section's count, age, reason, error and warning, and the row on each line", function()
  local now = 10000
  local reason = "rows come from every project; bind this repository with\n  git config --add dotfiles.jira.project <KEY>\nacli jira project list lists the keys"
  local state = {
    root = "/w/repo",
    sections = {
      { def = { title = "All open tickets", query = "q" }, key = "k", rows = ROWS, written = now - 180 },
      { def = { title = "Assigned to me (unbound)", query = "q", reason = reason }, key = "k", rows = { ROWS[1] }, written = now - 300, status = "fetching" },
      { def = { title = "Mine", query = "q" }, key = "k", status = "fetching" },
      { def = { title = "Also mine", query = "q" }, key = "k", error = "jira: not signed in; run :Docket login jira\n✗ Not authenticated" },
      { def = { title = "Review requested", query = "q" }, key = "k", rows = { ROWS[2] }, written = now, warning = "row: PAY-8 needs a non-empty string for state" },
      { def = { title = "Reviews", reason = "origin is on bitbucket.example.test, which is neither GitLab nor GitHub, so there are no review sections" } },
      { def = { title = "Stale", query = "q" }, key = "k", rows = { ROWS[1] }, written = now - 7200, error = "acli exited 1\nconnection refused" },
    },
  }
  local lines, at, marks, heads = list.lines(state, now)
  eq(lines, {
    "Docket · /w/repo",
    "",
    "All open tickets (2) · 3m ago",
    "  PAY-9    To Do         Nine",
    "  PAY-10   In Progress   Ten",
    "",
    "Assigned to me (unbound) (1) · 5m ago, refreshing",
    "  rows come from every project; bind this repository with",
    "    git config --add dotfiles.jira.project <KEY>",
    "  acli jira project list lists the keys",
    "  PAY-9   To Do   Nine",
    "",
    "Mine · fetching",
    "",
    "Also mine · error",
    "  jira: not signed in; run :Docket login jira",
    "  ✗ Not authenticated",
    "",
    "Review requested (1) · just now",
    "  PAY-10   In Progress   Ten",
    "  warning: row: PAY-8 needs a non-empty string for state",
    "",
    "Reviews",
    "  origin is on bitbucket.example.test, which is neither GitLab nor GitHub, so there are no review sections",
    "",
    "Stale (1) · 2h ago, refresh failed",
    "  acli exited 1",
    "  connection refused",
    "  PAY-9   To Do   Nine",
    "",
    list.KEYS,
  })
  eq(at[4].row, ROWS[1])
  eq(at[5].row, ROWS[2])
  eq(at[4].section, state.sections[1])
  eq(at[11].row, ROWS[1])
  eq(at[20].row, ROWS[2])
  eq(vim.tbl_count(at), 5, "a line that is not a row is on no row")
  eq(marks[1], { 0, 0, #"Docket · /w/repo", "Title" })
  eq(marks[2], { 2, 0, #"All open tickets (2)", "Title" })
  eq(marks[3], { 2, #"All open tickets (2) · ", #lines[3], "Comment" })
  eq(marks[4], { 3, 2, 2 + #"PAY-9", "Identifier" })
  eq(marks[5], { 3, #"  PAY-9    ", #"  PAY-9    To Do", "DocketLabel" }, "the state column, after the padded identifier")
  local header_lines = {}
  for index, st in ipairs(state.sections) do
    header_lines[index] = heads[st]
  end
  eq(header_lines, { 3, 7, 13, 15, 19, 23, 26 }, "each section's header line, which a dropped row's cursor goes to")
  local groups = {}
  for _, mark in ipairs(marks) do
    groups[mark[4]] = (groups[mark[4]] or 0) + 1
  end
  eq(groups.ErrorMsg, 4, "each error line")
  eq(groups.WarningMsg, 1)
end)

test("list: a row's state is a configured status's group on a Jira row alone", function()
  local state = {
    root = "/w/repo",
    sections = {
      {
        def = { title = "Tickets", query = "q" },
        key = "k",
        rows = { row.new({ source = "jira", id = "PAY-9", state = "In Review", title = "Nine", category = "indeterminate" }) },
        written = 0,
      },
      { def = { title = "Reviews", query = "q" }, key = "k", rows = { row.new({ source = "glab", id = "!4", state = "In Review", title = "Four" }) }, written = 0 },
    },
  }
  highlight.define({ ["In Review"] = "#f9e2af" })
  local lines, _, marks = list.lines(state, 0)
  highlight.define({})
  local states = {}
  for _, mark in ipairs(marks) do
    if lines[mark[1] + 1]:sub(mark[2] + 1, mark[3]) == "In Review" then
      states[#states + 1] = { lines[mark[1] + 1], mark[4] }
    end
  end
  eq(states, {
    { "  PAY-9   In Review   Nine", "DocketStatusIn_Review" },
    { "  !4   In Review   Four", "DocketLabel" },
  })
end)

test("list: open shows cached rows at once with their age and refreshes behind them, in a nofile buffer kept when hidden and listed", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  -- The dashboard holds the editor for no client, so nothing reaches the
  -- blocking form; the state checks go through spawn.run with the searches.
  local waits, restore_wait = stub_wait(function(argv)
    error("the dashboard waited on " .. table.concat(argv, " "))
  end)
  local runs, restore_run = stub_run(checked({ signed_in = true }, function(argv)
    local jql = jql_of(argv)
    if jql:find("assignee = currentUser()", 1, true) then
      return done(argv, { dash_row("PAY-7", "To Do", "Seven") })
    end
    if jql:find("reporter = currentUser()", 1, true) then
      return done(argv, { dash_row("PAY-8", nil, "Eight"), dash_row("PAY-2", "Done", "Two") })
    end
    return done(argv, { dash_row("PAY-10", "In Progress", "Ten"), dash_row("PAY-9", "To Do", "Nine") })
  end))
  local notices, restore_notify = stub_notify()
  local all_key = cache.key("jira", "project IN (PAY)" .. OPEN)
  -- Written in the order the client answered in, which row.compare would
  -- invert: the cached rows are shown as they were fetched.
  cache.write(all_key, {
    row.new({ source = "jira", id = "PAY-3", state = "To Do", title = "Cached three" }),
    row.new({ source = "jira", id = "PAY-1", state = "To Do", title = "Cached one" }),
  }, os.time() - 600)

  local buf = list.open({ root = "/w/repo", bare = true })
  local before = lines_of(buf)
  eq(settled(buf), true, "every section answered")
  local after = lines_of(buf)
  restore_notify()
  restore_run()
  restore_wait()
  restore_clone()

  eq(vim.api.nvim_get_current_buf(), buf)
  eq(vim.api.nvim_buf_get_name(buf), list.NAME, "the name the editor keeps verbatim, which no file can take")
  eq(vim.bo[buf].buftype, "nofile")
  eq(vim.bo[buf].bufhidden, "hide")
  eq(vim.bo[buf].buflisted, true)
  eq(vim.bo[buf].swapfile, false)
  eq(vim.bo[buf].modifiable, false)
  eq(vim.bo[buf].filetype, list.FILETYPE)

  eq(before[1], "Docket · /w/repo")
  eq(
    before[3],
    "All open tickets (2) · 10m ago, checking sign-in",
    "the cached rows are on screen before any state check answers"
  )
  eq(before[4], "  PAY-3   To Do   Cached three", "in the order they were fetched in")
  eq(before[5], "  PAY-1   To Do   Cached one")
  eq(before[7], "Assigned to me · checking sign-in", "no cached rows, so neither a count nor an age")

  eq(after[3], "All open tickets (2) · just now", "the count is the rows fetched")
  eq(after[4], "  PAY-10   In Progress   Ten", "the client's order, which the query asked for; columns aligned")
  eq(after[5], "  PAY-9    To Do         Nine")
  eq(after[7], "Assigned to me (1) · just now")
  eq(after[8], "  PAY-7   To Do   Seven")
  eq(after[10], "Mine (1) · just now", "the row without a status is left out of the count")
  eq(after[11], "  PAY-2   Done   Two")
  eq(after[12]:find("^  warning: .*row: PAY%-8 needs a non%-empty string for state") ~= nil, true, after[12])
  eq(after[14], "Review requested · error")
  eq(after[15], "  glab: not signed in; run :Docket login glab", "a backend not signed in names the login command")
  eq(after[16], "  glab exited 1", "and carries the client's own words")
  eq(after[17], "  x glab: no token")
  eq(after[19], "My open reviews · error")
  eq(after[20], "  glab: not signed in; run :Docket login glab")
  eq(after[#after], list.KEYS)
  eq(notices, {})

  eq(#waits, 0, "nothing held the editor")
  eq(vim.tbl_map(function(call)
    return table.concat(call.argv, " ")
  end, vim.tbl_filter(is_status, runs)), { "acli jira auth status", "glab auth status" }, "the state check runs once per backend")
  local searches = vim.tbl_filter(function(call)
    return not is_status(call)
  end, runs)
  eq(#searches, 3, "one search per Jira section")
  for _, run in ipairs(searches) do
    eq(has(run.argv, "--paginate"), true)
  end
  eq(#cache.read(all_key).rows, 2, "the fetched rows replace the cached ones")

  local sections = list.state(buf).sections
  eq(sections[1].def.title, "All open tickets")
  eq(sections[1].key, all_key, "a JQL query names its own projects, so its rows are the same in every clone")
  eq(sections[4].def.title, "Review requested")
  eq(
    sections[4].key,
    cache.key("glab", sections[4].def.query, "/w/repo"),
    "a review client reads the project from the working directory, so the clone is in its key"
  )

  local r, section = list.row_at(buf, 5)
  eq(r.id, "PAY-9")
  eq(section.def.title, "All open tickets")
  eq(list.row_at(buf, 3), nil)
  restore_cache()
end)

test("list: with no backend signed in every section carries the login command and no client is asked for rows", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local runs, restore_run = stub_run(checked({ signed_in = false }, function(argv)
    error("no rows are asked of a client that has no account: " .. table.concat(argv, " "))
  end))
  local notices, restore_notify = stub_notify()

  local buf = list.open({ root = "/w/repo", bare = true })
  eq(drained(), true, "the state checks' answers, settled from scheduled callbacks, have landed")
  local lines = lines_of(buf)
  restore_notify()
  restore_run()
  restore_clone()
  restore_cache()

  -- No section fetches, so the paint each backend's answer makes is the last
  -- one that puts these lines on screen.
  eq(lines, {
    "Docket · /w/repo",
    "",
    "All open tickets · error",
    "  jira: not signed in; run :Docket login jira",
    "  acli exited 1",
    "  ✗ Not authenticated",
    "",
    "Assigned to me · error",
    "  jira: not signed in; run :Docket login jira",
    "  acli exited 1",
    "  ✗ Not authenticated",
    "",
    "Mine · error",
    "  jira: not signed in; run :Docket login jira",
    "  acli exited 1",
    "  ✗ Not authenticated",
    "",
    "Review requested · error",
    "  glab: not signed in; run :Docket login glab",
    "  glab exited 1",
    "  x glab: no token",
    "",
    "My open reviews · error",
    "  glab: not signed in; run :Docket login glab",
    "  glab exited 1",
    "  x glab: no token",
    "",
    list.KEYS,
  })
  eq(vim.tbl_map(function(call)
    return call.argv[1]
  end, runs), { "acli", "glab" }, "one state check per backend, and nothing else was asked of a client")
  eq(notices, {})
end)

test("list: unbound, the account's rows sit under the binding command, an unknown remote states its reason, and w refuses with the reason", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "unbound" }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_wait = stub_wait(function(argv)
    if argv[1] == "git" then
      return done(argv, "worktree /w/repo\nbare\n\n")
    end
    return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
  end)
  local _, restore_run = stub_run(checked({ signed_in = true }, function(argv)
    return done(argv, { dash_row("PAY-7", "To Do", "Seven") })
  end))
  local notices, restore_notify = stub_notify()
  -- Silenced: the launcher's progress line is not what this test reads.
  local saved_echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() end

  local buf = commands.dash()
  eq(settled(buf), true)
  local lines = lines_of(buf)
  for _, lhs in ipairs({ "<CR>", "w", "r", "R" }) do
    eq(vim.fn.maparg(lhs, "n", false, true).buffer, 1, lhs .. " is a buffer-local map")
  end
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  commands.work_row(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  commands.work_row(buf)
  vim.api.nvim_echo = saved_echo
  restore_notify()
  restore_run()
  restore_wait()
  restore_clone()
  restore_cache()

  eq(lines[3], "Assigned to me (unbound) (1) · just now")
  eq(lines[4], "  rows come from every project; bind this repository with")
  eq(lines[5], "    " .. repo.BIND_COMMAND)
  eq(lines[6], "  " .. repo.LIST_COMMAND .. " lists the keys")
  eq(lines[7], "  PAY-7   To Do   Seven")
  eq(lines[9], "Reviews")
  eq(lines[10], "  origin is on bitbucket.example.test, which is neither GitLab nor GitHub, so there are no review sections")
  eq(#notices, 2)
  eq(notices[1].level, vim.log.levels.ERROR)
  eq(notices[1].message:find("bound to no Jira project", 1, true) ~= nil, true, notices[1].message)
  eq(notices[1].message:find(repo.BIND_COMMAND, 1, true) ~= nil, true, "the refusal carries the binding command")
  eq(notices[2].message, "no item on this line")
end)

test("commands: :Docket opens the dashboard, <CR> opens the row's item, R refuses a ticket, and outside a clone it says so", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@github.com:acme/payments.git")
  -- The dashboard checks the state through spawn.run, and <CR> through
  -- spawn.wait, as :Docket <id> does.
  local _, restore_wait = stub_acli({ signed_in = true })
  local _, restore_run = stub_run(checked({ signed_in = true }, function(argv)
    if argv[4] == "view" then
      return done(argv, view_payload())
    end
    if jql_of(argv) == "assignee = currentUser()" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, { dash_row("PAY-3", "To Do", "Three") })
  end))
  local notices, restore_notify = stub_notify()

  commands.run({ fargs = {}, bang = false })
  local buf = vim.api.nvim_get_current_buf()
  eq(list.state(buf) ~= nil, true, ":Docket made the dashboard current")
  eq(settled(buf), true)
  eq(lines_of(buf)[4], "  PAY-3   To Do   Three")
  eq(lines_of(buf)[12], "Review requested · error")
  eq(lines_of(buf)[13], "  gh: not signed in; run :Docket login gh")
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  commands.review_row(buf)
  commands.open_row(buf)
  vim.wait(1000, function()
    return vim.b[vim.api.nvim_get_current_buf()].docket ~= nil
  end)
  local opened = vim.api.nvim_get_current_buf()
  restore_notify()
  restore_run()
  restore_wait()
  restore_clone()
  restore_cache()

  eq(vim.api.nvim_buf_get_name(opened), "docket://jira/PAY-3")
  eq(
    { vim.api.nvim_buf_is_valid(buf), vim.fn.win_findbuf(buf), vim.bo[buf].buflisted },
    { true, {}, true },
    "the dashboard is kept, hidden and listed"
  )
  eq(#notices, 1)
  eq(notices[1].message, "PAY-3 is a ticket; R starts a review on a merge request")
  eq(notices[1].level, vim.log.levels.ERROR)
  vim.api.nvim_buf_delete(opened, { force = true })

  local saved_root = repo.root
  repo.root = function()
    return nil, "git exited 128\nfatal: not a git repository"
  end
  notices, restore_notify = stub_notify()
  eq(commands.dash(), nil)
  restore_notify()
  repo.root = saved_root
  eq(#notices, 1)
  eq(notices[1].message:find("the dashboard opens inside a clone; git exited 128", 1, true), 1, notices[1].message)
end)

-- The dashboard's row under the cursor and the clone it shows, replaced, with
-- the launcher, the progress line and the redraw that puts it on screen
-- recorded in the order they ran. Returns what the launcher was asked, the
-- events, and the restore.
local function stub_dash_row(r)
  local saved = { row_at = list.row_at, state = list.state, launch = env.launch, echo = vim.api.nvim_echo, redraw = vim.cmd.redraw }
  local asked, events = {}, {}
  list.row_at = function()
    return r, {}
  end
  list.state = function()
    return { root = "/w/repo", binding = { kind = "projects", projects = { "PROJ" } } }
  end
  env.launch = function(opts)
    asked[#asked + 1] = opts
    events[#events + 1] = "launch"
    return nil, "launched no further"
  end
  vim.api.nvim_echo = function(chunks, history)
    events[#events + 1] = { chunks[1][1], history }
  end
  vim.cmd.redraw = function()
    events[#events + 1] = "redraw"
  end
  return asked, events, function()
    list.row_at, list.state, env.launch, vim.api.nvim_echo = saved.row_at, saved.state, saved.launch, saved.echo
    vim.cmd.redraw = saved.redraw
  end
end

test("commands: R on a merge request row launches its branch with the review, after a progress line kept out of the history", function()
  local asked, events, restore = stub_dash_row({ source = "glab", id = "!4", branch = "feature/x" })
  local notices, restore_notify = stub_notify()
  commands.review_row(0)
  restore_notify()
  restore()
  eq(asked, { { root = "/w/repo", binding = { kind = "projects", projects = { "PROJ" } }, branch = "feature/x", review = "!4" } })
  eq(events, {
    { "docket: preparing the worktree for feature/x; when git has to ask origin, the editor waits up to 60 s", false },
    "redraw",
    "launch",
  }, "the line is drawn before git holds the editor, and kept out of :messages")
  eq(notices, { { message = "launched no further", level = vim.log.levels.ERROR } }, "a refusal is the launcher's own words")
end)

test("commands: w and R refuse a row from a fork, whose branch on origin is somebody else's", function()
  for _, act in ipairs({ commands.work_row, commands.review_row }) do
    -- The row carries no address, so nothing says the clone is the fork the
    -- branch lives in, and no git runs before the refusal.
    local asked, events, restore = stub_dash_row({ source = "gh", id = "#12", branch = "main", fork = true })
    local notices, restore_notify = stub_notify()
    act(0)
    restore_notify()
    restore()
    eq(asked, {}, "the launcher is not reached")
    eq(events, {}, "nor is the progress line drawn")
    eq(notices, {
      {
        message = "#12 comes from a fork, so origin's main is not its branch and no worktree is made for it",
        level = vim.log.levels.ERROR,
      },
    })
  end
end)

test("list: the dash's name is the editor's verbatim, so a file of that name does not stop it opening", function()
  -- The editor allows one buffer per name and raises E95 on a second, and a
  -- name carrying no `://` is resolved against the working directory: this is
  -- the buffer a file called `docket-dash`, opened, would leave behind.
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(other):find("docket%-dash") then
      vim.api.nvim_buf_delete(other, { force = true })
    end
  end
  local squatter = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(squatter, vim.fn.getcwd() .. "/docket-dash")
  local buf = list.buffer()
  eq(vim.api.nvim_buf_get_name(buf), list.NAME)
  vim.api.nvim_buf_delete(squatter, { force = true })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Replaces the Jira adapter's rows() with one that records the callback and
-- answers nothing, so a test decides when each section's answer lands.
local function stub_jira_rows()
  local hands, saved = {}, jira.rows
  jira.rows = function(_, on_done)
    hands[#hands + 1] = on_done
  end
  return hands, function()
    jira.rows = saved
  end
end

local function one_row(id)
  return { row.new({ source = "jira", id = id, state = "To Do", title = "Ticket " .. id }) }
end

test("list: an answer from before the dashboard was reopened paints nothing", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()

  local buf = list.open({ root = "/w/first", bare = true })
  eq(drained(), true, "the state check has answered")
  eq(#hands, 3, "one request per Jira section, none of them answered yet")
  local again = list.open({ root = "/w/second", bare = true })
  eq(again, buf, "the same buffer, holding a state of its own")
  eq(drained(), true)
  eq(#hands, 3, "the reopened sections join the requests already in flight")

  -- Every paint from here belongs to one of the two states, and only the one
  -- the buffer holds may paint.
  local painted, saved_set_lines = 0, vim.api.nvim_buf_set_lines
  vim.api.nvim_buf_set_lines = function(...)
    painted = painted + 1
    return saved_set_lines(...)
  end
  for index, hand in ipairs(hands) do
    hand(one_row("PAY-" .. index))
  end
  eq(settled(buf), true)
  vim.api.nvim_buf_set_lines = saved_set_lines
  local lines = lines_of(buf)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()

  eq(painted, 3, "one paint per section answered, and none from the state the reopen replaced")
  eq(lines[1], "Docket · /w/second")
  eq(lines[3], "All open tickets (1) · just now")
  eq(lines[4], "  PAY-1   To Do   Ticket PAY-1")
  eq(notices, {})
end)

test("list: r asks the client again, and a repaint replaces the highlights rather than adding to them", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local asked, saved_rows = 0, jira.rows
  jira.rows = function(_, on_done)
    asked = asked + 1
    on_done(one_row("PAY-" .. asked))
  end
  local notices, restore_notify = stub_notify()

  local buf = commands.dash()
  eq(settled(buf), true)
  local first = asked
  local marks = #vim.api.nvim_buf_get_extmarks(buf, list.NS, 0, -1, {})
  list.render(buf)
  local repainted = #vim.api.nvim_buf_get_extmarks(buf, list.NS, 0, -1, {})
  vim.fn.maparg("r", "n", false, true).callback()
  eq(settled(buf), true)
  local lines = lines_of(buf)
  restore_notify()
  jira.rows = saved_rows
  restore_checks()
  restore_clone()
  restore_cache()

  eq(first, 3, "one request per Jira section")
  eq(repainted, marks, "the namespace is cleared before the marks are set again")
  eq(asked, 6, "r asks each section again rather than painting what is on screen")
  eq(lines[4], "  PAY-4   To Do   Ticket PAY-4", "and shows what the client answered this time")
  eq(notices, {})
end)

test("list: a repaint keeps the cursor on its row as rows arrive above it, and on the section's header once the row is gone", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local function rows_of(...)
    return vim.tbl_map(function(id)
      return row.new({ source = "jira", id = id, state = "To Do", title = "Ticket " .. id })
    end, { ... })
  end
  local function answer_all(first)
    local asked = #hands
    list.refresh(list.buffer())
    -- The state check's answer is settled from a scheduled callback, and the
    -- rows are asked for only once it has run.
    drained()
    for index = asked + 1, #hands do
      hands[index](index == asked + 1 and first or rows_of("OPS-1"))
    end
    return settled(list.buffer())
  end

  local buf = list.open({ root = "/w/repo", bare = true })
  eq(drained(), true)
  for _, hand in ipairs(hands) do
    hand(rows_of("PAY-2", "PAY-3"))
  end
  eq(settled(buf), true)
  eq(lines_of(buf)[5], "  PAY-3   To Do   Ticket PAY-3")
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  local answered = answer_all(rows_of("PAY-1", "PAY-2", "PAY-3"))
  local moved = { vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_get_current_line() }
  local answered_again = answer_all(rows_of("PAY-1"))
  local dropped = { vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_get_current_line() }
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  eq({ answered, answered_again }, { true, true })
  eq(moved, { 6, "  PAY-3   To Do   Ticket PAY-3" }, "a row added above moves the row, and the cursor with it")
  eq(dropped, { 3, "All open tickets (1) · just now" }, "a row gone leaves the cursor where no key acts on a row")
  eq(notices, {})
end)

test("list: a restored session's dashboard buffer is taken over rather than named a second time", function()
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(other) == list.NAME then
      vim.api.nvim_buf_delete(other, { force = true })
    end
  end
  -- What :mksession writes for a dashboard on screen, under 'sessionoptions'
  -- holding localoptions, while before_session_save() has it off the list.
  vim.cmd("enew")
  vim.cmd("file " .. list.NAME)
  vim.cmd("setlocal nobuflisted")
  local restored = vim.api.nvim_get_current_buf()
  local ok, buf = pcall(list.buffer)
  eq(ok, true, "no E95: " .. tostring(buf))
  eq(buf, restored)
  eq(
    { vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].buflisted, vim.bo[buf].filetype },
    { "nofile", "hide", true, list.FILETYPE },
    "taken over, and listed again"
  )
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Wipes the dash an earlier test left, so that the next open() makes one no
-- window has shown, which carries no window option of an earlier test's.
local function no_dash()
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(other) == list.NAME then
      vim.api.nvim_buf_delete(other, { force = true })
    end
  end
end

-- The dash's fold options in a window, and its `wrap`.
local function dash_window(win)
  local wo = vim.wo[win]
  return { wo.foldmethod, wo.foldexpr, wo.foldtext, wo.foldlevel, wo.wrap }
end

-- Whether each section of the dash is closed in the current window, in the
-- order the state holds them, read at each one's header line.
local function closed_sections(buf)
  local state = list.state(buf)
  local heads = select(4, list.lines(state, os.time()))
  return vim.tbl_map(function(st)
    return vim.fn.foldclosed(heads[st]) == heads[st]
  end, state.sections)
end

-- Closes one section of the dash in the current window, as `za` on its
-- header does.
local function close_section(buf, index)
  local state = list.state(buf)
  local heads = select(4, list.lines(state, os.time()))
  vim.cmd(heads[state.sections[index]] .. "foldclose")
end

test("list: the lines give each line its fold level: a section from its header to the blank line that ends it, the title and the footer in none", function()
  local now = 10000
  local state = {
    root = "/w/repo",
    sections = {
      { def = { title = "Mine", query = "q", reason = "a note\nof two lines" }, key = "k", rows = { ROWS[1] }, written = now },
      { def = { title = "Reviews", query = "q" }, key = "k", rows = { ROWS[2] }, written = now, warning = "row: PAY-8 needs a non-empty string for state" },
    },
  }
  local lines, _, _, heads, folds = list.lines(state, now)
  eq(lines, {
    "Docket · /w/repo",
    "",
    "Mine (1) · just now",
    "  a note",
    "  of two lines",
    "  PAY-9   To Do   Nine",
    "",
    "Reviews (1) · just now",
    "  PAY-10   In Progress   Ten",
    "  warning: row: PAY-8 needs a non-empty string for state",
    "",
    list.KEYS,
  })
  eq(folds, { "0", "0", ">1", "1", "1", "1", "1", ">1", "1", "1", "1", "0" })
  eq({ folds[heads[state.sections[1]]], folds[heads[state.sections[2]]] }, { ">1", ">1" }, "each header opens its section's fold")
  eq(list.KEYS:find("za fold", 1, true) ~= nil, true, "the footer names the key")
end)

test("list: the footer names every dash key", function()
  -- Each entry's first word, as a set: a substring check would pass with a
  -- key missing, since `R` occurs inside `<CR>` and `w` inside `review`.
  local named = {}
  for _, entry in ipairs(vim.split(list.KEYS, "   ", { plain = true })) do
    named[entry:match("^(%S+)")] = true
  end
  local expected = { za = true, ["g?"] = true }
  for _, key in ipairs(commands.DASH_KEYS) do
    expected[key.lhs] = true
  end
  eq(named, expected)
end)

test("list: the dash's windows do not wrap", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local ok, err = in_tab(function()
    local file = vim.api.nvim_get_current_buf()
    local a = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local b = vim.api.nvim_get_current_win()
    -- A buffer of the dash's name as a restored session leaves it, which
    -- open() takes over: it carries none of the dash's autocommands yet, so
    -- what dresses this window is open() alone.
    local restored = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(restored, list.NAME)
    vim.api.nvim_win_set_buf(b, restored)
    local before = vim.wo[b].wrap
    vim.api.nvim_set_current_win(a)
    local buf = list.open({ root = "/w/repo", bare = true })
    local opened = { vim.wo[a].wrap, vim.wo[b].wrap }
    vim.cmd("buffer " .. file)
    local file_wraps = vim.wo[a].wrap
    vim.cmd("enew")
    local new_wraps = vim.wo[a].wrap
    -- Answered before anything is asserted, so that a failure leaves no
    -- request in flight for a later test to join.
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    eq(before, true, "shown before open(), under the suite's global wrap")
    eq(opened, { false, false }, "every window showing the dash")
    eq(file_wraps, true, "a file then shown in one of them wraps, as the global value has it")
    eq(new_wraps, true, "and so does a new buffer there")
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(notices, {})
end)

test("list: the dash's window carries the fold options and nowrap, and :enew in that window carries none of them", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local ok, err = in_tab(function()
    local win = vim.api.nvim_get_current_win()
    local before = dash_window(win)
    local buf = list.open({ root = "/w/repo", bare = true })
    local opened = dash_window(win)
    local levels = { list.fold(buf, 1), list.fold(buf, 3), list.fold(buf, 10000) }
    vim.cmd("enew")
    local elsewhere = dash_window(win)
    vim.api.nvim_set_current_buf(buf)
    local again = dash_window(win)
    -- Answered before anything is asserted, so that a failure leaves no
    -- request in flight for a later test to join.
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    local dash_values = { "expr", ("v:lua.require'docket.list'.fold(%d, v:lnum)"):format(buf), "", 99, false }
    eq(opened, dash_values, "a fold per section through fold(), a closed one shown as its header line, every section open, and no wrap")
    eq(levels, { "0", ">1", "0" }, "fold() answers the last paint's level: the title line, the first header, and past the last line")
    eq(elsewhere, before, "another buffer in that window has the window's own values")
    eq(again, dash_values, "and the dash has its own again")
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(notices, {})
end)

test("list: a paint that adds a row to a section keeps the sections a window had closed closed, and every other open", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local ok, err = in_tab(function()
    local buf = list.open({ root = "/w/repo", bare = true })
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    local state = list.state(buf)
    eq(closed_sections(buf), { false, false, false, false }, "every section starts open")
    close_section(buf, 1)
    eq(closed_sections(buf), { true, false, false, false })
    table.insert(state.sections[2].rows, one_row("PAY-20")[1])
    list.render(buf)
    eq(closed_sections(buf), { true, false, false, false }, "the paint moved the closed fold onto the second section, and the record put it back")
    -- Each line's level is the one lines() gives it, which needs the levels
    -- stored before the lines are replaced: the paint evaluates them as it
    -- replaces the lines.
    local folds = select(5, list.lines(state, os.time()))
    local want, have = {}, {}
    for lnum, level in ipairs(folds) do
      want[lnum] = level == "0" and 0 or 1
      have[lnum] = vim.fn.foldlevel(lnum)
    end
    eq(have, want, "every line at its level after the paint")

    -- Two sections carrying one title are told apart by their order.
    vim.cmd("%foldopen!")
    state.sections[3].def = vim.tbl_extend("force", state.sections[3].def, { title = state.sections[2].def.title })
    list.render(buf)
    close_section(buf, 2)
    table.insert(state.sections[1].rows, one_row("PAY-21")[1])
    list.render(buf)
    eq(closed_sections(buf), { false, true, false, false }, "the second of two sections with one title stays open")
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(notices, {})
end)

test("list: a second :Docket whose cached rows add a row to a section leaves the closed section closed and every other open", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local found = { root = "/w/repo", bare = true }
  -- Puts one row more in the first section's cache than the screen shows,
  -- which the cache can hold because it keeps a Jira query's rows for every
  -- clone and editor, then opens the dash again and answers its requests
  -- with one row each. Answered before anything is asserted, so that a
  -- failure leaves no request in flight for a later test to join.
  local function reopen(buf)
    local answered, shown = #hands, #lines_of(buf)
    cache.write(list.state(buf).sections[1].key, { one_row("PAY-1")[1], one_row("PAY-30")[1] }, os.time())
    local again = list.open(found)
    local seen = {
      buf = again,
      added = #lines_of(buf) - shown,
      checked = drained(),
      painted = closed_sections(buf),
    }
    for index = answered + 1, #hands do
      hands[index](one_row("PAY-" .. index))
    end
    seen.settled = settled(buf)
    seen.answered = closed_sections(buf)
    return seen
  end
  local ok, err = in_tab(function()
    local buf = list.open(found)
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    close_section(buf, 2)
    local below = reopen(buf)
    vim.cmd("%foldopen!")
    close_section(buf, 1)
    local within = reopen(buf)
    eq({ below.buf, below.added, below.checked, below.settled }, { buf, 1, true, true }, "the cached rows add a row to the first section")
    eq(below.painted, { false, true, false, false }, "a row above the closed section leaves it closed and the others open")
    eq(below.answered, { false, true, false, false }, "and so after the answers that drop the row again")
    eq({ within.buf, within.added, within.checked, within.settled }, { buf, 1, true, true })
    eq(within.painted, { true, false, false, false }, "a row in the closed section leaves it closed and the others open")
    eq(within.answered, { true, false, false, false })
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(notices, {})
end)

test("list: a paint keeps a window's cursor on the header of the section it was on, closed or open", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local ok, err = in_tab(function()
    local buf = list.open({ root = "/w/repo", bare = true })
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    local state = list.state(buf)
    -- A section's header line as the state stands now.
    local function head(index)
      return select(4, list.lines(state, os.time()))[state.sections[index]]
    end
    -- Adds a row to the first section, above the third, and paints.
    local added = 0
    local function grow()
      added = added + 1
      table.insert(state.sections[1].rows, one_row("PAY-" .. (40 + added))[1])
      list.render(buf)
    end

    close_section(buf, 3)
    vim.cmd("normal! gg" .. (head(3) - 1) .. "j")
    eq(vim.fn.line("."), head(3), "j onto the closed section stops on its header")
    grow()
    eq(vim.fn.line("."), head(3), "a closed section reached with j")
    eq(closed_sections(buf), { false, false, true, false })
    vim.cmd("normal! za")
    eq(closed_sections(buf), { false, false, false, false }, "and za there opens that section")

    local blank = head(4) - 1
    vim.api.nvim_win_set_cursor(0, { blank, 0 })
    vim.cmd("normal! zc")
    eq({ vim.fn.line("."), vim.fn.foldclosed(blank) }, { blank, head(3) }, "zc leaves the cursor on the closing blank line, inside the fold")
    grow()
    eq(vim.fn.line("."), head(3), "a closed section the cursor is inside")
    eq(closed_sections(buf), { false, false, true, false })

    vim.cmd("%foldopen!")
    vim.api.nvim_win_set_cursor(0, { head(3), 0 })
    grow()
    eq(vim.fn.line("."), head(3), "an open section's header")
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(notices, {})
end)

test("list: a paint keeps the sections closed in each window showing the dash, whichever window is current", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local seen, other_tab = {}, nil
  local ok, err = in_tab(function()
    local file = vim.api.nvim_get_current_buf()
    vim.cmd("split")
    local a = vim.api.nvim_get_current_win()
    local buf = list.open({ root = "/w/repo", bare = true })
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    close_section(buf, 1)
    -- A second window on the dash, in a tab of its own, with another section
    -- closed. A window the dash enters while another shows it copies that
    -- window's folds, so this one opens them before closing its own.
    vim.cmd("tabnew")
    other_tab = vim.api.nvim_get_current_tabpage()
    local b = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(buf)
    vim.cmd("%foldopen!")
    close_section(buf, 3)
    -- The paint happens from the file's window below the first one.
    vim.api.nvim_set_current_win(a)
    vim.cmd("wincmd j")
    seen.current = vim.api.nvim_win_get_buf(0) == file
    table.insert(list.state(buf).sections[2].rows, one_row("PAY-20")[1])
    list.render(buf)
    local function closed_in(win)
      return vim.api.nvim_win_call(win, function()
        return closed_sections(buf)
      end)
    end
    seen.a, seen.b = closed_in(a), closed_in(b)
  end)
  if other_tab and vim.api.nvim_tabpage_is_valid(other_tab) then
    vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(other_tab))
  end
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(seen.current, true, "the window current at the paint shows the file")
  eq(seen.a, { true, false, false, false }, "the first window keeps its first section closed")
  eq(seen.b, { false, false, true, false }, "and the window in the other tab its third")
  eq(notices, {})
end)

test("list: a window that showed the dash before :Docket dressed it carries its options when the dash returns to it", function()
  jira.forget()
  no_dash()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "https://bitbucket.example.test/acme/payments.git")
  local _, restore_checks = stub_checks({ signed_in = true })
  local hands, restore_rows = stub_jira_rows()
  local notices, restore_notify = stub_notify()
  local seen = {}
  local ok, err = in_tab(function()
    local a = vim.api.nvim_get_current_win()
    local file = vim.api.nvim_get_current_buf()
    -- A buffer of the dash's name as a restored session leaves it, shown in
    -- two windows that then move to the file: one with the window's own
    -- values, and one with the fold options the session recorded, whose
    -- 'foldexpr' names the buffer number the dash had before the restore.
    local restored = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(restored, list.NAME)
    vim.cmd("split")
    local c = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(c, restored)
    vim.api.nvim_win_set_buf(c, file)
    vim.cmd("split")
    local d = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(d, restored)
    vim.wo[d][0].foldmethod = "expr"
    vim.wo[d][0].foldexpr = "v:lua.require'docket.list'.fold(9999, v:lnum)"
    vim.wo[d][0].foldlevel = 0
    vim.api.nvim_win_set_buf(d, file)

    vim.api.nvim_set_current_win(a)
    local buf = list.open({ root = "/w/repo", bare = true })
    eq(drained(), true)
    for index, hand in ipairs(hands) do
      hand(one_row("PAY-" .. index))
    end
    eq(settled(buf), true)
    seen.buf, seen.taken = buf, buf == restored
    vim.api.nvim_set_current_win(c)
    vim.cmd("buffer " .. buf)
    seen.c = dash_window(c)
    local first = select(4, list.lines(list.state(buf), os.time()))[list.state(buf).sections[1]]
    local folded, why = pcall(vim.cmd, "normal! " .. first .. "Gza")
    seen.za = folded or why
    seen.closed = closed_sections(buf)
    vim.api.nvim_win_set_buf(d, buf)
    seen.d = dash_window(d)
  end)
  restore_notify()
  restore_rows()
  restore_checks()
  restore_clone()
  restore_cache()
  assert(ok, err)
  eq(seen.taken, true, "open() took the restored buffer over")
  local dash_values = { "expr", ("v:lua.require'docket.list'.fold(%d, v:lnum)"):format(seen.buf), "", 99, false }
  eq(seen.c, dash_values, ":b in the window that showed the restored buffer")
  eq(seen.za, true, "where za folds")
  eq(seen.closed, { true, false, false, false })
  eq(seen.d, dash_values, "and the window whose 'foldexpr' named the old number, with every section open")
  eq(notices, {})
end)

test("list: a review adapter whose module fails to load is the section's error, in the registry's words", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "ignored" }, "git@gitlab.example.test:acme/payments.git")
  -- A registry of its own, whose glab module raises inside its own require:
  -- a defect in the module, which is reported whole rather than as a backend
  -- this build does not carry.
  local saved_registry, saved_glab = package.loaded["docket.adapters"], package.loaded["docket.adapters.glab"]
  package.loaded["docket.adapters"] = nil
  local registry = require("docket.adapters")
  package.loaded["docket.adapters"] = saved_registry
  package.loaded["docket.adapters.glab"] = nil
  package.preload["docket.adapters.glab"] = function()
    return require("docket.adapters.no_such_helper")
  end
  local saved_get = adapters.get
  adapters.get = registry.get
  local notices, restore_notify = stub_notify()
  local buf = list.open({ root = "/w/repo", bare = true })
  local drained_ok = drained()
  local lines = lines_of(buf)
  restore_notify()
  adapters.get = saved_get
  package.preload["docket.adapters.glab"] = nil
  package.loaded["docket.adapters.glab"] = saved_glab
  restore_clone()
  restore_cache()
  eq(drained_ok, true)
  -- The lines under a section's header, up to the blank line that ends it.
  local function under(header)
    local found, inside = {}, false
    for _, line in ipairs(lines) do
      if inside and line == "" then
        break
      end
      if inside then
        found[#found + 1] = line
      end
      inside = inside or line == header
    end
    return found
  end
  local shown = under("Review requested · error")
  eq(shown[1], "  adapter glab: module 'docket.adapters.no_such_helper' not found:", table.concat(lines, "\n"))
  eq(#shown > 1, true, "the loader's own lines follow, since this is a defect to read whole")
  eq(under("My open reviews · error"), shown, "the state check runs once per adapter, and both sections carry it")
  eq(notices, {})
end)

test("list: a binding that could not be read is a section's reason, and w on a row refuses with it", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local saved = {
    root = repo.root,
    binding = repo.binding,
    remote_url = repo.remote_url,
    launch = env.launch,
    status = glab.auth_status,
    rows = glab.rows,
  }
  repo.root = function()
    return { root = "/w/repo", bare = true }
  end
  repo.binding = function()
    return nil, "git exited 1\nfatal: bad config line 3 in .bare/config"
  end
  repo.remote_url = function()
    return "git@gitlab.example.test:acme/payments.git"
  end
  local launched = 0
  env.launch = function()
    launched = launched + 1
    return nil, "the launcher was reached with no binding"
  end
  glab.auth_status = function(on_done)
    local status = { authenticated = true, detail = "✓ Logged in to gitlab.example.test" }
    if on_done then
      return on_done(status)
    end
    return status
  end
  glab.rows = function(_, on_done)
    on_done({ row.new({ source = "glab", id = "!482", state = "needs review", title = "Bump the pinned version", branch = "topic" }) })
  end
  local notices, restore_notify = stub_notify()

  local buf = commands.dash()
  eq(settled(buf), true)
  local lines = lines_of(buf)
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  commands.work_row(buf)
  restore_notify()
  repo.root, repo.binding, repo.remote_url = saved.root, saved.binding, saved.remote_url
  env.launch, glab.auth_status, glab.rows = saved.launch, saved.status, saved.rows
  restore_cache()

  eq(lines[3], "Tickets", "the Jira sections cannot be assembled without the binding")
  eq(lines[4], "  the repository's Jira binding could not be read: git exited 1")
  eq(lines[5], "  fatal: bad config line 3 in .bare/config")
  eq(lines[7], "Review requested (1) · just now", "and the review sections stand")
  eq(lines[8], "  !482   needs review   Bump the pinned version")
  eq(launched, 0, "the launcher is never reached, because it reads the binding")
  eq(#notices, 1)
  eq(notices[1].message, "git exited 1\nfatal: bad config line 3 in .bare/config", "the reason git gave, verbatim")
  eq(notices[1].level, vim.log.levels.ERROR)
end)

-- The headers of the sections the default configuration shows for a clone
-- bound to PAY whose origin is on GitLab, each followed by ` · ` and `meta`.
local function headers(meta)
  return vim.tbl_map(function(title)
    return title .. " · " .. meta
  end, { "All open tickets", "Assigned to me", "Mine", "Review requested", "My open reviews" })
end

-- The lines of `buf` that are section headers, in order.
local function headers_of(buf)
  local titles = {}
  for _, section in ipairs(config.options.sections) do
    titles[#titles + 1] = section.title
  end
  return vim.tbl_filter(function(line)
    for _, title in ipairs(titles) do
      if line:sub(1, #title + 1) == title .. " " or line == title then
        return true
      end
    end
    return false
  end, lines_of(buf))
end

-- The dashboard for /w/repo, bound to PAY, with origin on GitLab, and every
-- call to a client held; the calls are the first return.
local function held_dash()
  jira.forget()
  glab.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local waits, restore_wait = stub_wait(function(argv)
    error("the dashboard held the editor for " .. table.concat(argv, " "))
  end)
  local held, answer, restore_run = stub_run_held()
  local notices, restore_notify = stub_notify()
  local buf = list.open({ root = "/w/repo", bare = true })
  return {
    buf = buf,
    held = held,
    answer = answer,
    waits = waits,
    notices = notices,
    restore = function()
      restore_notify()
      restore_run()
      restore_wait()
      restore_clone()
      -- The calls held here are never answered, so the cache still has a
      -- request in flight for each of the dash's keys; a later test that
      -- opens the same clone joins those and waits on them. clear() moves
      -- every key on.
      cache.clear()
      restore_cache()
    end,
  }
end

-- The held calls from `from` on as `<client> <verb words>`.
local function held_argv(held, from)
  return vim.tbl_map(function(call)
    return table.concat(call.argv, " ", 1, math.min(#call.argv, 4))
  end, vim.list_slice(held, from or 1))
end

test("list: the dash paints every section as checking sign-in before any state check answers, and joins one check per backend", function()
  local dash = held_dash()
  local ok, err = pcall(function()
    local first = lines_of(dash.buf)
    eq(headers_of(dash.buf), headers("checking sign-in"), "painted before open() returned, with nothing answered")
    eq(first[1], "Docket · /w/repo")
    eq(drained(), true)
    eq(held_argv(dash.held), { "acli jira auth status", "glab auth status" }, "three Jira sections and two GitLab ones, one check per backend")
    eq(dash.held[2].opts.cwd, "/w/repo", "glab's check runs in the clone the dash shows, where its rows run")
    eq(dash.held[1].opts and dash.held[1].opts.cwd, nil, "acli's verdict is the account's and runs nowhere in particular")
    -- Jira signed in, GitLab not.
    dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
    dash.answer(2, failed(dash.held[2].argv, 1, "x glab: no token"))
    eq(drained(), true)
    eq(held_argv(dash.held, 3), { "acli jira workitem search", "acli jira workitem search", "acli jira workitem search" }, "Jira's rows are asked for, and GitLab's are not")
    local lines = lines_of(dash.buf)
    eq(headers_of(dash.buf), {
      "All open tickets · fetching",
      "Assigned to me · fetching",
      "Mine · fetching",
      "Review requested · error",
      "My open reviews · error",
    })
    eq(vim.tbl_contains(lines, "  glab: not signed in; run :Docket login glab"), true, table.concat(lines, "\n"))
    for index = 3, 5 do
      dash.answer(index, done(dash.held[index].argv, { dash_row("PAY-" .. index, "To Do", "Row " .. index) }))
    end
    eq(settled(dash.buf), true)
    eq(lines_of(dash.buf)[3], "All open tickets (1) · just now")
    eq(lines_of(dash.buf)[4], "  PAY-3   To Do   Row 3")
    eq(#dash.waits, 0, "nothing held the editor")
    eq(dash.notices, {})
  end)
  dash.restore()
  assert(ok, err)
end)

test("list: a refresh while the state checks are out asks each backend again, and the first round's answers paint nothing", function()
  local dash = held_dash()
  local ok, err = pcall(function()
    eq(drained(), true)
    list.refresh(dash.buf)
    eq(drained(), true)
    eq(held_argv(dash.held), { "acli jira auth status", "glab auth status", "acli jira auth status", "glab auth status" }, "one more check per backend")
    local painted, saved_set_lines = 0, vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(...)
      painted = painted + 1
      return saved_set_lines(...)
    end
    local set_ok, set_err = pcall(function()
      dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
      dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
      eq(drained(), true)
      eq(painted, 0, "the first round's answers paint nothing")
      eq(#dash.held, 4, "and ask for no rows")
      dash.answer(3, done(dash.held[3].argv, STATUS_SIGNED_IN))
      dash.answer(4, failed(dash.held[4].argv, 1, "x glab: no token"))
      eq(drained(), true)
      eq(painted > 0, true, "the second round's answers paint")
    end)
    vim.api.nvim_buf_set_lines = saved_set_lines
    assert(set_ok, set_err)
    eq(#dash.held, 7, "the second round asks for Jira's rows")
    for index = 5, 7 do
      dash.answer(index, done(dash.held[index].argv, { dash_row("PAY-" .. index, "To Do", "Row " .. index) }))
    end
    eq(settled(dash.buf), true)
    eq(headers_of(dash.buf)[1], "All open tickets (1) · just now")
    eq(dash.notices, {})
  end)
  dash.restore()
  assert(ok, err)
end)

test("list: a dash wiped while its state checks are out is left alone when they answer", function()
  local dash = held_dash()
  local ok, err = pcall(function()
    eq(drained(), true)
    vim.api.nvim_buf_delete(dash.buf, { force = true })
    dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
    dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
    eq(drained(), true)
    eq(#dash.held, 2, "no rows are asked for")
    eq(dash.notices, {}, "and nothing raised")
  end)
  dash.restore()
  assert(ok, err)
end)

-- A dashboard whose every call answers before spawn.run returns: the Jira
-- searches with one row, PAY-7, and the review client not signed in.
local function answered_dash()
  jira.forget()
  glab.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local _, restore_wait = stub_wait(function(argv)
    error("the dashboard held the editor for " .. table.concat(argv, " "))
  end)
  local _, restore_run = stub_run(checked({ signed_in = true }, function(argv)
    return done(argv, { dash_row("PAY-7", "To Do", "Seven") })
  end))
  local notices, restore_notify = stub_notify()
  return notices, function()
    restore_notify()
    restore_run()
    restore_wait()
    restore_clone()
    restore_cache()
  end
end

test("list: a deleted dash is remade, and a hidden one is painted", function()
  local notices, restore = answered_dash()
  local found = { root = "/w/repo", bare = true }
  local other = vim.api.nvim_create_buf(true, false)
  local made = { other }
  local ok, err = pcall(function()
    local function painted(buf)
      return vim.tbl_contains(lines_of(buf), "  PAY-7   To Do   Seven")
    end
    -- The answers are painted from scheduled callbacks, after the window has
    -- moved to another buffer.
    local buf = list.open(found)
    made[#made + 1] = buf
    vim.api.nvim_set_current_buf(other)
    eq(settled(buf), true)
    eq({ vim.api.nvim_buf_is_valid(buf), vim.fn.win_findbuf(buf) }, { true, {} }, "kept while hidden")
    eq(painted(buf), true, "and painted there")
    vim.cmd("buffer " .. buf)
    eq(
      { vim.api.nvim_get_current_buf(), painted(buf), list.state(buf) ~= nil },
      { buf, true, true },
      ":b lands on it as it was"
    )

    -- :bdelete leaves it valid and unloaded; open() wipes it and makes the
    -- dash afresh.
    vim.api.nvim_set_current_buf(other)
    vim.cmd("bdelete " .. buf)
    eq({ vim.api.nvim_buf_is_valid(buf), vim.api.nvim_buf_is_loaded(buf) }, { true, false })
    eq(drained(), true)
    eq(list.state(buf), nil, "its state goes with the unload")
    local remade = list.open(found)
    made[#made + 1] = remade
    eq(settled(remade), true)
    eq(remade ~= buf, true, "a dash made afresh")
    eq(vim.api.nvim_buf_is_valid(buf), false, "the deleted one is wiped")
    eq(
      { vim.bo[remade].buftype, vim.bo[remade].bufhidden, vim.bo[remade].buflisted, vim.bo[remade].modified },
      { "nofile", "hide", true, false }
    )
    eq(painted(remade), true)

    -- Entered after :bdelete, it loads as an empty buffer with no buftype,
    -- and the next open() takes it over.
    vim.api.nvim_set_current_buf(other)
    vim.cmd("bdelete " .. remade)
    local own = dash_window(0)
    vim.cmd("buffer " .. remade)
    eq({ vim.api.nvim_buf_is_loaded(remade), vim.bo[remade].buftype }, { true, "" }, "loaded, its options reset")
    eq(dash_window(0), own, "and the window's own values, though the BufWinEnter autocommand :bdelete left still fires")
    eq(drained(), true)
    eq(list.state(remade), nil, "its state goes, though :b loaded it again")
    local taken = list.open(found)
    eq(settled(taken), true)
    eq(taken, remade, "the buffer of that name, taken over")
    local events = vim.tbl_map(function(autocmd)
      return autocmd.event
    end, vim.api.nvim_get_autocmds({ group = "docket/dash", buffer = taken }))
    table.sort(events)
    eq(events, { "BufUnload", "BufWinEnter", "BufWipeout" }, "the take-over replaces the autocommands :bdelete left on it")
    eq(
      { vim.bo[taken].buftype, vim.bo[taken].buflisted, vim.bo[taken].modified },
      { "nofile", true, false },
      "a paint leaves it unmodified"
    )
    eq(painted(taken), true)
    eq(notices, {})
  end)
  restore()
  for _, buf in ipairs(made) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  assert(ok, err)
end)

test("list: a callback paints nothing into an unloaded dash, and the next open makes it the dash again", function()
  -- :bdelete drops the state through BufUnload. An unload that skips
  -- autocommands, as `:noautocmd bdelete` does, leaves it, and so does
  -- :bunload, which keeps the options; the tests in current() are then what
  -- stop the paint.
  for _, how in ipairs({ "bdelete", "noautocmd bdelete", "bunload", "noautocmd bunload" }) do
    local dash = held_dash()
    local other = vim.api.nvim_create_buf(true, false)
    local made = { dash.buf, other }
    local ok, err = pcall(function()
      eq(drained(), true)
      vim.api.nvim_set_current_buf(other)
      vim.cmd(how .. " " .. dash.buf)
      eq(drained(), true)
      eq(list.state(dash.buf) == nil, how == "bdelete", how .. ": the state")
      dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
      dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
      eq(drained(), true)
      eq(vim.api.nvim_buf_is_loaded(dash.buf), false, how .. ": nothing loaded it")
      eq(#dash.held, 2, how .. ": no rows are asked for")
      eq(dash.notices, {}, how .. ": and nothing raised")
      local buf = list.open({ root = "/w/repo", bare = true })
      made[#made + 1] = buf
      eq(drained(), true)
      eq(
        { vim.bo[buf].buftype, vim.bo[buf].modified, list.state(buf) ~= nil },
        { "nofile", false, true },
        how .. ": the next open shows a dash"
      )
    end)
    dash.restore()
    for _, buf in ipairs(made) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    assert(ok, err)
  end
end)

test("list: a callback queued before :bdelete paints nothing into the dash :b then loaded", function()
  -- The answers are queued first, so they run before the look BufUnload
  -- schedules, while the state is still the dash's.
  local dash = held_dash()
  local other = vim.api.nvim_create_buf(true, false)
  local ok, err = pcall(function()
    eq(drained(), true)
    dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
    dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
    vim.api.nvim_set_current_buf(other)
    vim.cmd("bdelete " .. dash.buf)
    vim.cmd("buffer " .. dash.buf)
    eq(drained(), true)
    eq(
      { vim.bo[dash.buf].buftype, vim.bo[dash.buf].modified, lines_of(dash.buf) },
      { "", false, { "" } },
      "loaded by :b, empty and unmodified"
    )
    eq(#dash.held, 2, "no rows are asked for")
    eq(list.state(dash.buf), nil, "and the state is gone")
    eq(dash.notices, {})
  end)
  dash.restore()
  for _, buf in ipairs({ dash.buf, other }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  assert(ok, err)
end)

test("list: :e in the dash keeps it the dash, and r paints it again", function()
  for _, how in ipairs({ "edit", "edit!" }) do
    local notices, restore = answered_dash()
    local buf
    local ok, err = pcall(function()
      buf = commands.dash()
      eq(settled(buf), true)
      local painted = lines_of(buf)
      vim.cmd(how)
      eq(drained(), true)
      eq(
        { lines_of(buf), list.state(buf) ~= nil, vim.bo[buf].buftype },
        { { "" }, true, "nofile" },
        how .. ": blank, and still the dash"
      )
      vim.api.nvim_feedkeys("r", "x", false)
      eq(settled(buf), true)
      eq(lines_of(buf), painted, how .. ": r paints the rows again")
      eq({ vim.bo[buf].modified, list.buffer() }, { false, buf }, how .. ": unmodified, and the one :Docket reuses")
      eq(notices, {})
    end)
    restore()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    assert(ok, err)
  end
end)

test("list: a review section's rows are asked in the clone the dash shows, whichever directory a later state check took", function()
  local saved_getcwd = vim.fn.getcwd
  local dash = held_dash()
  local ok, err = pcall(function()
    eq(drained(), true)
    -- Another mode's entry from a tab in another clone, while the dash's
    -- checks are out.
    vim.fn.getcwd = function()
      return "/w/elsewhere"
    end
    glab.auth_status(function() end)
    vim.fn.getcwd = saved_getcwd
    dash.answer(1, failed(dash.held[1].argv, 1, "✗ Not authenticated"))
    dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
    eq(drained(), true)
    local lists = vim.tbl_filter(function(call)
      return call.argv[1] == "glab" and call.argv[2] == "mr"
    end, dash.held)
    eq(#lists, 2, "both review sections asked")
    for _, call in ipairs(lists) do
      eq(call.opts.cwd, "/w/repo", table.concat(call.argv, " "))
    end
    -- `r` after a `:cd` in the dash's tab: the check runs in the dash's
    -- clone as the rows do, so the state painted is that clone's host's.
    vim.fn.getcwd = function()
      return "/w/elsewhere"
    end
    local from = #dash.held + 1
    list.refresh(dash.buf)
    vim.fn.getcwd = saved_getcwd
    eq(drained(), true)
    eq(held_argv(dash.held, from), { "acli jira auth status", "glab auth status" }, "r asks each backend again")
    eq(dash.held[from + 1].opts.cwd, "/w/repo", "in the clone the dash shows, not the directory the tab moved to")
  end)
  vim.fn.getcwd = saved_getcwd
  dash.restore()
  glab.forget()
  assert(ok, err)
end)

test("list: reopened for another clone while its state checks are out, the dash asks each backend again there, and the first clone's answers paint nothing", function()
  gh.forget()
  local dash = held_dash()
  local ok, err = pcall(function()
    eq(drained(), true)
    eq(held_argv(dash.held), { "acli jira auth status", "glab auth status" })
    -- The clone reopened for is on GitHub, so its review client is gh.
    repo.remote_url = function()
      return "git@github.com:acme/other.git"
    end
    local again = list.open({ root = "/w/b", bare = true })
    eq(again, dash.buf, "the same buffer, holding a state of its own")
    eq(drained(), true)
    eq(held_argv(dash.held, 3), { "acli jira auth status", "gh auth status --active" }, "a fresh check per backend of the clone reopened for")
    eq(dash.held[4].opts.cwd, "/w/b", "in that clone")
    local painted, saved_set_lines = 0, vim.api.nvim_buf_set_lines
    vim.api.nvim_buf_set_lines = function(...)
      painted = painted + 1
      return saved_set_lines(...)
    end
    local set_ok, set_err = pcall(function()
      dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
      dash.answer(2, done(dash.held[2].argv, "✓ Logged in"))
      eq(drained(), true)
      eq(painted, 0, "the first clone's answers paint nothing")
      eq(#dash.held, 4, "and ask for no rows")
      dash.answer(3, failed(dash.held[3].argv, 1, "✗ Not authenticated"))
      dash.answer(4, done(dash.held[4].argv, "github.com\n  ✓ Logged in to github.com account me (keyring)\n"))
      eq(drained(), true)
      eq(painted > 0, true, "the reopened clone's answers paint")
    end)
    vim.api.nvim_buf_set_lines = saved_set_lines
    assert(set_ok, set_err)
    local lines = lines_of(dash.buf)
    eq(lines[1], "Docket · /w/b")
    eq(vim.tbl_contains(lines, "  jira: not signed in; run :Docket login jira"), true, table.concat(lines, "\n"))
    local lists = vim.tbl_filter(function(call)
      return call.argv[1] == "gh" and call.argv[2] == "pr"
    end, dash.held)
    eq(#lists, 2, "both review sections ask gh for rows")
    for _, call in ipairs(lists) do
      eq(call.opts.cwd, "/w/b", table.concat(call.argv, " "))
    end
    eq(#vim.tbl_filter(function(call)
      return call.argv[1] == "glab"
    end, dash.held), 1, "glab was asked nothing past the first clone's check")
    eq(dash.notices, {})
  end)
  dash.restore()
  gh.forget()
  assert(ok, err)
end)

test("list: a state check that raises is its sections' error, carrying what it raised, and is asked once", function()
  local saved, asked = glab.auth_status, 0
  glab.auth_status = function(_)
    asked = asked + 1
    error("glab: the check broke", 0)
  end
  local dash = held_dash()
  local ok, err = pcall(function()
    dash.answer(1, done(dash.held[1].argv, STATUS_SIGNED_IN))
    eq(drained(), true)
    local lines = lines_of(dash.buf)
    eq(vim.list_slice(headers_of(dash.buf), 4), { "Review requested · error", "My open reviews · error" })
    local carried = vim.tbl_filter(function(line)
      return line == "  glab: the check broke"
    end, lines)
    eq(#carried, 2, table.concat(lines, "\n"))
    -- A raise settles the check where it raised, which is before the second
    -- section joins; settled there and then, the second would ask again.
    eq(asked, 1, "one check per backend, though it raised")
  end)
  glab.auth_status = saved
  dash.restore()
  assert(ok, err)
end)

-- the help tags ---------------------------------------------------------------------------

test("init: the help tags are written beside the file, skipped when current, and a failure is reported once", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local help = dir .. "/docket.txt"
  local source = root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/doc/docket.txt"
  vim.uv.fs_copyfile(source, help)
  local notices, restore = stub_notify()
  -- Read-only first: the reported-once flag is module state, and a success
  -- after a failure is the order a fixed permission takes.
  vim.uv.fs_chmod(dir, tonumber("555", 8))
  local ok, outcome = docket.helptags(help)
  local again, outcome_again = docket.helptags(help)
  vim.uv.fs_chmod(dir, tonumber("755", 8))
  eq(ok, false)
  eq(outcome:find("E152", 1, true) ~= nil, true, outcome)
  eq(again, false)
  eq(outcome_again, outcome)
  eq(#notices, 1, "reported once")
  eq(notices[1].level, vim.log.levels.WARN)
  eq(vim.uv.fs_stat(dir .. "/tags"), nil)
  eq({ docket.helptags(help) }, { true, "written" })
  eq(vim.uv.fs_stat(dir .. "/tags") ~= nil, true)
  eq({ docket.helptags(help) }, { true, "current" })
  local absent, outcome_absent = docket.helptags(dir .. "/absent/docket.txt")
  restore()
  eq(absent, false)
  eq(outcome_absent:find("E150", 1, true) ~= nil, true, "an absent directory is helptags' own E150: " .. outcome_absent)
  eq(#notices, 1, "a later failure is not reported again")
  eq({ docket.helptags() }, { false, "missing" }, "isolate() keeps every copy of the package off the runtime path")
  eq(vim.uv.fs_stat(vim.fs.dirname(source) .. "/tags"), nil, "nothing is written in the source tree")
end)

test("init: help_files names the help file and the tags beside it, once they exist", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local help = dir .. "/docket.txt"
  vim.uv.fs_copyfile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/doc/docket.txt", help)
  eq(docket.help_files(help), { help = help })
  eq({ docket.helptags(help) }, { true, "written" })
  eq(docket.help_files(help), { help = help, tags = dir .. "/tags" })
  eq(docket.help_files(), {}, "isolate() keeps every copy of the package off the runtime path")
end)

test("init: setup takes the options, defines the groups, and keeps them across a colour scheme change", function()
  clear_groups({ "DocketEditable" })
  local options = docket.setup({ timeouts = { tmux = 1 } })
  eq(options.timeouts.tmux, 1)
  eq(options.timeouts.client, 30000)
  local float = bg_of("NormalFloat")
  eq(bg_of("DocketEditable"), float)
  local autocmds = vim.api.nvim_get_autocmds({ group = "docket/highlights", event = "ColorScheme" })
  eq(#autocmds, 1)
  eq(#vim.api.nvim_get_autocmds({ group = "docket/highlights", event = "OptionSet", pattern = "background" }), 1)
  eq(#vim.api.nvim_get_autocmds({ group = "docket/highlights", event = "VimEnter" }), 1)
  vim.cmd("highlight clear DocketEditable")
  vim.api.nvim_exec_autocmds("ColorScheme", { group = "docket/highlights" })
  eq(bg_of("DocketEditable"), float, "defined again")
  docket.setup({})
  eq(#vim.api.nvim_get_autocmds({ group = "docket/highlights", event = "ColorScheme" }), 1, "a second setup adds no second autocommand")
  -- :hi clear puts each default link back by itself and empties
  -- DocketEditable, so this is the assertion that needs the autocommand.
  vim.cmd.colorscheme("default")
  eq(bg_of("DocketEditable"), float, "a colour scheme's :hi clear, then the autocommand")
  config.configure()
end)

test("init: setup keeps DocketEditable on the colours shown when 'background' changes, after startup, and after a colour scheme that skips :hi clear", function()
  clear_groups({ "DocketEditable" })
  docket.setup({})
  -- With no colour scheme loaded, neovim's own colours change with
  -- 'background' and no ColorScheme event fires; with one loaded, setting
  -- 'background' loads it again, which fires one.
  vim.g.colors_name = nil
  local fired = 0
  local counter = vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      fired = fired + 1
    end,
  })
  vim.o.background = "light"
  local light = { float = bg_of("NormalFloat"), editable = bg_of("DocketEditable"), fired = fired }
  -- Twice, so that an autocommand deleted after its first run shows.
  vim.o.background = "dark"
  local dark = { float = bg_of("NormalFloat"), editable = bg_of("DocketEditable") }
  vim.api.nvim_del_autocmd(counter)
  -- OptionSet does not fire during startup; VimEnter, at its end, is what
  -- catches a 'background' set after setup by the rest of the configuration's
  -- init.lua. No event fires for the nvim_set_hl() that stands in for it here.
  vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#123456" })
  vim.api.nvim_exec_autocmds("VimEnter", { group = "docket/highlights" })
  local entered = bg_of("DocketEditable")
  -- A colour scheme that runs :hi clear only when another one is loaded.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/colors", "p")
  vim.fn.writefile({
    "if vim.g.colors_name then vim.cmd.highlight('clear') end",
    "vim.g.colors_name = 'noclear'",
    "vim.api.nvim_set_hl(0, 'NormalFloat', { bg = '#181825' })",
  }, dir .. "/colors/noclear.lua")
  vim.opt.runtimepath:prepend(dir)
  vim.g.colors_name = nil
  vim.cmd.colorscheme("noclear")
  local noclear = bg_of("DocketEditable")
  vim.opt.runtimepath:remove(dir)
  vim.cmd.colorscheme("default")
  config.configure()
  eq(light.fired, 0, "no ColorScheme event")
  eq(light.float ~= dark.float, true, "neovim's light colours give NormalFloat another background")
  eq(light.editable, light.float, "'background' set to light")
  eq(dark.editable, dark.float, "and back to dark")
  eq(entered, tonumber("123456", 16), "at the end of startup")
  eq(noclear, tonumber("181825", 16), "a colour scheme loaded without :hi clear")
end)

test("init: setup sets the configured statuses, reports one it cannot set, and sets them again after a colour scheme", function()
  local notices, restore = stub_notify()
  docket.setup({ statuses = { ["In Review"] = "#f9e2af", Bad = 5 } })
  restore()
  eq(notices, {
    {
      message = "docket: the status Bad keeps its category's colour, because its value is a number, where a colour, a group's name or a table goes",
      level = vim.log.levels.WARN,
    },
  })
  vim.cmd.colorscheme("default")
  local fg = vim.api.nvim_get_hl(0, { name = "DocketStatusIn_Review" }).fg
  local after = highlight.state_group("In Review", nil, "jira")
  docket.setup({})
  local replaced = highlight.state_group("In Review", nil, "jira")
  config.configure()
  eq(fg, tonumber("f9e2af", 16), "the colour scheme's :hi clear emptied it, and the autocommand set it again")
  eq(after, "DocketStatusIn_Review")
  eq(replaced, "DocketLabel", "a second setup replaces the statuses")
end)

-- the health report -----------------------------------------------------------------------

-- vim.health's report functions replaced by a recorder, so a test reads the
-- report health.check() makes without running :checkhealth. Returns the
-- report, one `{ kind, message, advice }` per call, and the restore.
local function stub_health()
  local report, saved = {}, {}
  for _, name in ipairs({ "start", "ok", "warn", "error", "info" }) do
    saved[name] = vim.health[name]
    vim.health[name] = function(message, advice)
      report[#report + 1] = { name, message, advice }
    end
  end
  return report, function()
    for name, fn in pairs(saved) do
      vim.health[name] = fn
    end
  end
end

test("health: each backend a configured section needs here, with the login command as the fix, and the rest not run", function()
  local report, restore_health = stub_health()
  -- The default sections: Jira's, and the review sections, which take the
  -- client origin selects, glab here.
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local calls, restore_wait = stub_acli({ signed_in = false })
  health.check()
  restore_wait()
  restore_clone()
  restore_health()
  eq(report[1], { "start", "docket: backends" })
  eq(report[2][1], "error")
  eq(report[2][2], "jira: not signed in")
  eq(report[2][3][1], "run :Docket login jira")
  eq(report[3], { "error", "glab: not signed in", { "run :Docket login glab", "glab exited 1\nx glab: no token" } })
  eq(report[4], { "info", "gh: no configured section needs it here; not checked" })
  eq(
    vim.tbl_map(function(call)
      return call.argv[1]
    end, calls),
    { "acli", "glab" },
    "gh is not run"
  )
  eq(report[5], { "start", "docket: help" })
  eq(report[6][1], "error", "isolate() keeps every copy of the help file off the runtime path")
  eq(report[7], { "start", "docket: configuration" })
  eq(report[8][2]:find("^sections: All open tickets %(jira%)") ~= nil, true, report[8][2])
  eq(report[9][2]:find("^cache directory: ") ~= nil, true, report[9][2])

  -- The help file found, with and without the tags beside it: health reads
  -- init's lookup, so the one lookup is replaced.
  report, restore_health = stub_health()
  local saved_files = docket.help_files
  local _, restore_all = stub_acli({ signed_in = true, glab = true, gh = true })
  docket.help_files = function()
    return { help = "/p/doc/docket.txt" }
  end
  health.check()
  docket.help_files = function()
    return { help = "/p/doc/docket.txt", tags = "/p/doc/tags" }
  end
  health.check()
  docket.help_files = saved_files
  restore_all()
  restore_health()
  local helps = vim.tbl_filter(function(entry)
    return entry[2]:find("/p/doc/", 1, true) ~= nil
  end, report)
  eq(helps, {
    {
      "warn",
      "no tags beside /p/doc/docket.txt, so :help docket does not resolve",
      { "run :lua print(require('docket').helptags()) to write them; it prints false and the reason when they cannot be written" },
    },
    { "ok", "help tags beside /p/doc/docket.txt" },
  })
end)

test("health: a section naming a client has it checked, and a review section that selects none says why", function()
  local NOT_A_CLONE = "fatal: not a git repository (or any of the parent directories): .git\n"
  config.configure({
    sections = {
      { title = "Tickets", adapter = "jira", query = "<projects>" },
      { title = "Reviews", adapter = "review", query = { glab = { "mr", "list" }, gh = { "pr", "list" } } },
      { title = "Tools", adapter = "gh", query = { "pr", "list" } },
      { title = "Typo", adapter = "jria", query = "<projects>" },
    },
  })
  -- Outside a clone: git's own answer, run in the window's directory.
  local outside, restore_health = stub_health()
  local calls, restore_wait = stub_wait(function(argv)
    if argv[1] == "git" then
      return failed(argv, 128, NOT_A_CLONE)
    end
    return status_answer({ signed_in = true, gh = true }, argv)
  end)
  health.check()
  restore_wait()
  restore_health()
  -- In a clone whose origin names no host: adapter_for()'s reason.
  local no_host
  no_host, restore_health = stub_health()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "/srv/git/payments.git")
  _, restore_wait = stub_acli({ signed_in = true, gh = true })
  health.check()
  restore_wait()
  restore_clone()
  restore_health()
  -- In a clone with no origin: remote_url()'s reason.
  local no_origin
  no_origin, restore_health = stub_health()
  restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, nil)
  local saved_url = repo.remote_url
  repo.remote_url = function()
    return nil, "git exited 2\nerror: No such remote 'origin'\n"
  end
  _, restore_wait = stub_acli({ signed_in = true, gh = true })
  health.check()
  restore_wait()
  repo.remote_url = saved_url
  restore_clone()
  restore_health()
  config.configure()

  eq(calls[1].argv[1], "git")
  eq(calls[1].opts.cwd, vim.fn.getcwd(), "the clone is the one the working directory is in")
  local backends = vim.list_slice(outside, 1, 6)
  eq(backends[1], { "start", "docket: backends" })
  eq(backends[2], { "info", "the review sections select no client here: git exited 128\n" .. NOT_A_CLONE })
  eq(backends[3][1], "ok", vim.inspect(backends[3]))
  eq(backends[3][2]:find("^jira: signed in") ~= nil, true, backends[3][2])
  eq(backends[4], { "info", "glab: no configured section needs it here; not checked" })
  eq(backends[5], { "ok", "gh: signed in\n✓ Logged in to gh.example.test as me" }, "named by a section, so checked")
  eq(backends[6], { "error", "no adapter named jria; the adapters are jira, glab, gh" }, "a name the registry refuses")
  eq(no_host[2], {
    "info",
    "the review sections select no client here: origin is /srv/git/payments.git, which names no host, so there are no review sections",
  })
  eq(no_origin[2], { "info", "the review sections select no client here: git exited 2\nerror: No such remote 'origin'\n" })
end)

test("health: a backend no section names is not run, Jira's included, and with no review section git is not run either", function()
  local function argv0(calls)
    return vim.tbl_map(function(call)
      return call.argv[1]
    end, calls)
  end
  -- Review sections alone, in a GitLab clone: glab is checked, and acli is
  -- not run.
  config.configure({
    sections = { { title = "Reviews", adapter = "review", query = { glab = { "mr", "list" }, gh = { "pr", "list" } } } },
  })
  local reviews, restore_health = stub_health()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local review_calls, restore_wait = stub_acli({ signed_in = true, glab = true })
  health.check()
  restore_wait()
  restore_clone()
  restore_health()
  -- A Jira section alone, outside a clone: the clone is never looked for.
  config.configure({ sections = { { title = "Tickets", adapter = "jira", query = "<projects>" } } })
  local tickets
  tickets, restore_health = stub_health()
  local ticket_calls
  ticket_calls, restore_wait = stub_wait(function(argv)
    if argv[1] == "git" then
      return failed(argv, 128, "fatal: not a git repository (or any of the parent directories): .git\n")
    end
    return status_answer({ signed_in = true }, argv)
  end)
  health.check()
  restore_wait()
  restore_health()
  config.configure()

  eq(argv0(review_calls), { "glab" }, "acli is not run")
  eq(vim.list_slice(reviews, 1, 4), {
    { "start", "docket: backends" },
    { "info", "jira: no configured section needs it here; not checked" },
    { "ok", "glab: signed in\n✓ Logged in to glab.example.test as me" },
    { "info", "gh: no configured section needs it here; not checked" },
  })
  eq(argv0(ticket_calls), { "acli" }, "git is not run")
  eq(tickets[1], { "start", "docket: backends" })
  eq(tickets[2][1], "ok", vim.inspect(tickets[2]))
  eq(tickets[2][2]:find("^jira: signed in") ~= nil, true, tickets[2][2])
  eq(vim.list_slice(tickets, 3, 5), {
    { "info", "glab: no configured section needs it here; not checked" },
    { "info", "gh: no configured section needs it here; not checked" },
    { "start", "docket: help" },
  }, "no line says the review sections select no client")
end)

test("health: the configuration names each status with a colour of its own and its group, and warns of one not set", function()
  local report, restore_health = stub_health()
  local _, restore_wait = stub_acli({ signed_in = true, glab = true, gh = true })
  highlight.define({})
  health.check()
  highlight.define({ ["In Review"] = "#f9e2af", Blocked = "DiagnosticError", Bad = 5 })
  local from = #report
  health.check()
  highlight.define({})
  restore_wait()
  restore_health()
  local function lines_after(first)
    local found = {}
    for index = first + 1, #report do
      if report[index][2]:find("status", 1, true) then
        found[#found + 1] = { report[index][1], report[index][2] }
      end
    end
    return found
  end
  eq(lines_after(0)[1], { "info", "statuses with a colour of their own: none" })
  eq(lines_after(from), {
    { "info", "statuses with a colour of their own: Blocked (DocketStatusBlocked), In Review (DocketStatusIn_Review)" },
    { "warn", "the status Bad keeps its category's colour, because its value is a number, where a colour, a group's name or a table goes" },
  })
end)

test("health: a status linked to a group that sets nothing is warned of, directly or through the target's own link", function()
  vim.api.nvim_set_hl(0, "DocketTestChain", { link = "DocketTestNoSuchGroup" })
  highlight.define({
    Typo = "DocketTestNoSuchGroup",
    Chained = { link = "DocketTestChain", bold = true },
    Blocked = "DiagnosticError",
    Coloured = "#f9e2af",
  })
  local report, restore_health = stub_health()
  local _, restore_wait = stub_acli({ signed_in = true, glab = true, gh = true })
  health.check()
  restore_wait()
  restore_health()
  highlight.define({})
  vim.cmd.highlight("clear", "DocketTestChain")
  local advice = { "correct the name in setup{}'s statuses; :highlight lists the groups there are" }
  eq(
    vim.tbl_filter(function(entry)
      return entry[1] == "warn" and entry[2]:find("status", 1, true) ~= nil
    end, report),
    {
      { "warn", "the status Chained renders uncoloured: it links to DocketTestChain, which sets nothing here", advice },
      { "warn", "the status Typo renders uncoloured: it links to DocketTestNoSuchGroup, which sets nothing here", advice },
    }
  )
end)

-- the plugin file -------------------------------------------------------------------------

test("plugin: the command, the map and the autocommands are declared, and :e reads an item", function()
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  eq(vim.g.loaded_docket, true)
  eq(vim.fn.exists(":Docket"), 2)
  eq(vim.fn.maparg("<leader>dd", "n"), "<Cmd>Docket<CR>")
  local events = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "docket" })) do
    events[autocmd.event] = events[autocmd.event] or {}
    table.insert(events[autocmd.event], autocmd.pattern)
  end
  for _, patterns in pairs(events) do
    table.sort(patterns)
  end
  eq(events, {
    BufReadCmd = { "docket-new://*", "docket://*" },
    BufWriteCmd = { "docket-new://*", "docket://*" },
    FileType = { "docket" },
  })

  jira.forget()
  local _, restore_wait = stub_acli({ signed_in = true })
  local run_calls, restore_run = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local notices, restore_notify = stub_notify()
  vim.cmd.edit("docket://jira/TIG-1001")
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(1000, function()
    return vim.b[buf].docket ~= nil
  end)
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  vim.cmd.write()
  -- The write answers later: it reads the item to check the body, sends it,
  -- and reads the item again.
  local writing_then = buffer.writing(buf)
  vim.wait(1000, function()
    return not buffer.writing(buf)
  end)
  restore_notify()
  restore_run()
  restore_wait()
  eq(vim.api.nvim_buf_get_name(buf), "docket://jira/TIG-1001")
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("^TIG%-1001   In Progress   me") ~= nil, true)
  eq(vim.bo[buf].filetype, "docket")
  eq(vim.fn.maparg("gx", "n", false, true).buffer, 1, "the item buffer's keymap")
  eq(vim.fn.maparg("<leader>dw", "n", false, true).buffer, 1)
  eq(writing_then, true, ":w went through the write command")
  eq(notices, { { message = "body: written", level = vim.log.levels.INFO } })
  local edits = vim.tbl_filter(function(call)
    return call.argv[4] == "edit"
  end, run_calls)
  eq(#edits, 1, "one body update")
  eq(vim.list_slice(edits[1].argv, 1, 9), argv_of("workitem", "edit", "--key", "TIG-1001", "--yes", "--json", "--description-file"))
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "The retry loop re-enters" }, "the buffer holds what the client read back")
  eq(vim.bo[buf].modified, false, "and the read after the write clears modified")

  -- `:e!` with a read that fails: the state the last read stored goes with
  -- the text it described, so `:w` says nothing is loaded rather than
  -- planning a save against regions that are gone.
  _, restore_wait = stub_acli({ signed_in = true })
  _, restore_run = stub_run(function(argv)
    return failed(argv, 1, "Error: Issue does not exist or you do not have permission to see it.")
  end)
  notices, restore_notify = stub_notify()
  vim.cmd("edit!")
  vim.wait(1000, function()
    return #notices > 0
  end)
  vim.cmd.write()
  restore_notify()
  restore_run()
  restore_wait()
  eq(vim.b[buf].docket, nil)
  eq(notices, {
    {
      message = "docket://jira/TIG-1001: acli exited 1\nError: Issue does not exist or you do not have permission to see it.",
      level = vim.log.levels.ERROR,
    },
    { message = "nothing loaded in this buffer; :e reads the item", level = vim.log.levels.WARN },
  })
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  -- Its edits would make a later read of the same item refuse.
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Every BufReadCmd that fires on a `docket://` buffer, counted.
local function count_reads()
  local count = { reads = 0 }
  local id = vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "docket://*",
    callback = function()
      count.reads = count.reads + 1
    end,
  })
  return count, function()
    vim.api.nvim_del_autocmd(id)
  end
end

test("buffer: a deleted buffer is remade, so the item is read once", function()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  local name = buffer.name("jira", "TIG-1002")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  jira.forget()
  local waits, restore_wait = stub_acli({ signed_in = true })
  local runs, restore_run = stub_run(function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end)
  local notices, restore_notify = stub_notify()
  local count, restore_count = count_reads()
  local function views()
    return #vim.tbl_filter(function(call)
      return call.argv[4] == "view"
    end, runs)
  end
  local function checks()
    return #vim.tbl_filter(is_status, waits)
  end
  local ok, err = pcall(function()
    local first = buffer.open("jira", "TIG-1002")
    vim.wait(1000, function()
      return vim.b[first].docket ~= nil
    end)
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
    vim.cmd("bdelete " .. first)
    eq(
      { vim.api.nvim_buf_is_valid(first), vim.api.nvim_buf_is_loaded(first), vim.bo[first].buflisted },
      { true, false, false },
      ":bdelete leaves the buffer, unloaded and off the list"
    )
    count.reads = 0
    local checked_before, viewed_before = checks(), views()
    local second = buffer.open("jira", "TIG-1002")
    vim.wait(1000, function()
      return vim.b[second].docket ~= nil
    end)
    eq(vim.api.nvim_buf_is_valid(first), false, "the deleted buffer is wiped")
    eq(second ~= first, true, "and the item opens in a buffer made afresh")
    eq(vim.api.nvim_get_current_buf(), second)
    eq(vim.api.nvim_buf_get_name(second), name)
    eq({ vim.bo[second].buftype, vim.bo[second].buflisted }, { "acwrite", true })
    eq(count.reads, 0, "showing it fires no BufReadCmd")
    eq(checks() - checked_before, 1, "one state check")
    eq(views() - viewed_before, 1, "and one read of the item")
    eq(notices, {})
    vim.api.nvim_buf_delete(second, { force = true })
  end)
  restore_count()
  restore_notify()
  restore_run()
  restore_wait()
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  assert(ok, err)
end)

test("plugin: a restored session's item buffer carries the keys and reads nothing", function()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  local name = buffer.name("jira", "PROJ-1")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local waits, restore_wait = stub_wait(function(argv)
    error("the restore reached spawn.wait: " .. table.concat(argv, " "))
  end)
  local runs, restore_run = stub_run(function(argv)
    error("the restore reached spawn.run: " .. table.concat(argv, " "))
  end)
  local notices, restore_notify = stub_notify()
  local count, restore_count = count_reads()
  local ok, err = pcall(function()
    -- The lines :mksession writes for an item buffer on screen, under
    -- 'sessionoptions' holding localoptions, while before_session_save() has
    -- it off the list.
    vim.cmd("enew")
    vim.cmd("file " .. name)
    vim.cmd("setlocal nobuflisted")
    vim.cmd("setlocal buftype=acwrite")
    vim.cmd("setlocal filetype=docket")
    local buf = vim.api.nvim_get_current_buf()
    eq(vim.bo[buf].buflisted, true, "the FileType autocommand lists it again")
    eq(vim.fn.maparg("gx", "n", false, true).buffer, 1, "the item buffer's keymap")
    eq(vim.fn.maparg("<leader>dw", "n", false, true).buffer, 1)
    vim.cmd.write()
    eq(notices, { { message = "nothing loaded in this buffer; :e reads the item", level = vim.log.levels.WARN } })
    eq(count.reads, 0, "no BufReadCmd")
    eq({ #runs, #waits }, { 0, 0 }, "nothing spawned")

    -- A new ticket's draft on screen is written the same way.
    vim.cmd("enew")
    vim.cmd("file " .. commands.DRAFT .. "jira")
    vim.cmd("setlocal nobuflisted")
    vim.cmd("setlocal buftype=acwrite")
    vim.cmd("setlocal filetype=docket")
    local draft = vim.api.nvim_get_current_buf()
    eq(vim.bo[draft].buflisted, true, "the FileType autocommand lists a draft again")
    eq(vim.fn.maparg("gx", "n", false, true).buffer == 1, false, "a draft carries no item keymap")
    eq(lines_of(draft), { "" }, "and nothing filled it")
    eq({ #runs, #waits }, { 0, 0 }, "nothing spawned for the draft")
  end)
  -- Left behind by a failed assertion, either name would make the next
  -- test's buffer of that name raise E95.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.tbl_contains({ name, commands.DRAFT .. "jira" }, vim.api.nvim_buf_get_name(buf)) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  restore_count()
  restore_notify()
  restore_run()
  restore_wait()
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  assert(ok, err)
end)

test("docket: before_session_save keeps every docket buffer out of the session and lists it again", function()
  eq(docket.NAMES, { buffer.SCHEME, commands.DRAFT, list.NAME }, "the names the modules that make the buffers give them")
  local made = {}
  local function item(id)
    local buf = loaded_buffer({ id = id })
    made[#made + 1] = buf
    return buf
  end
  local saved = { sessionoptions = vim.o.sessionoptions, current = vim.api.nvim_get_current_buf() }
  local session = vim.fn.tempname()
  local ok, err = pcall(function()
    local shown = item("PROJ-801")
    local hidden = item("PROJ-802")
    local deleted = item("PROJ-803")
    local draft = vim.api.nvim_create_buf(false, false)
    made[#made + 1] = draft
    vim.api.nvim_buf_set_name(draft, commands.DRAFT .. "jira")
    buffer.prepare(draft)
    local dash = list.buffer()
    made[#made + 1] = dash
    local file = vim.fn.tempname()
    vim.fn.writefile({ "a file" }, file)
    vim.cmd("badd " .. vim.fn.fnameescape(file))
    local file_buf = vim.fn.bufnr(file)
    made[#made + 1] = file_buf
    vim.api.nvim_set_current_buf(deleted)
    vim.api.nvim_set_current_buf(shown)
    vim.cmd("bdelete " .. deleted)
    eq(vim.bo[deleted].buflisted, false, ":bdelete took it off the list")

    vim.o.sessionoptions = saved.sessionoptions .. ",localoptions"
    local unlisted = docket.before_session_save()
    local during = {}
    for _, buf in ipairs({ shown, hidden, draft, dash }) do
      during[#during + 1] = vim.bo[buf].buflisted
    end
    vim.cmd("mksession! " .. vim.fn.fnameescape(session))
    local lines = vim.fn.readfile(session)
    vim.wait(1000, function()
      return vim.bo[shown].buflisted
    end)

    for _, buf in ipairs({ shown, hidden, draft, dash }) do
      eq(vim.tbl_contains(unlisted, buf), true, vim.api.nvim_buf_get_name(buf) .. " was taken off the list")
    end
    eq(vim.tbl_contains(unlisted, deleted), false, "one already off the list is not touched")
    eq(during, { false, false, false, false }, "off the list while the session is written")
    eq(
      vim.tbl_filter(function(line)
        return line:find("^badd %+%d+ docket[%w-]*://") ~= nil
      end, lines),
      {},
      "no docket buffer is on the session's buffer list"
    )
    eq(
      #vim.tbl_filter(function(line)
        return line:find("^badd ") ~= nil and vim.endswith(line, vim.fn.fnamemodify(file, ":t"))
      end, lines),
      1,
      "a file is, as before"
    )
    local file_line
    for index, line in ipairs(lines) do
      if line == "file " .. buffer.name("jira", "PROJ-801") then
        file_line = index
      end
    end
    eq(file_line ~= nil, true, "the shown buffer's window is recorded")
    eq(lines[file_line - 1], "enew")
    eq(vim.tbl_contains(lines, "setlocal nobuflisted"), true, "with the option as the hook left it")
    for _, buf in ipairs({ shown, hidden, draft, dash }) do
      eq(vim.bo[buf].buflisted, true, vim.api.nvim_buf_get_name(buf) .. " is listed again")
    end
    eq(vim.bo[deleted].buflisted, false, "and the deleted one stays off the list")
    eq(vim.bo[file_buf].buflisted, true)
  end)
  vim.o.sessionoptions = saved.sessionoptions
  if vim.api.nvim_buf_is_valid(saved.current) then
    vim.api.nvim_set_current_buf(saved.current)
  end
  for _, buf in ipairs(made) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.fn.delete(session)
  assert(ok, err)
end)

-- the GitLab adapter ------------------------------------------------------------------------

-- A user as GitLab returns one on an author, an assignee or `api user`.
-- UNVERIFIED: the run against the instance printed a note's own field names
-- and not its `author` object's, and made no `api user` call, so these names
-- come from GitLab's REST reference. `glab api
-- projects/:id/merge_requests/<iid>/notes | jq '.[0].author | keys'` settles
-- the author half.
local function gl_user(username, name)
  return {
    id = #username * 7,
    username = username,
    name = name,
    state = "active",
    avatar_url = "https://gitlab.example.test/uploads/" .. username .. ".png",
    web_url = "https://gitlab.example.test/" .. username,
  }
end

-- A merge request as `mr list -F json` and `mr view -F json` print one.
local function merge_request(overrides)
  return vim.tbl_extend("force", {
    id = 9001,
    iid = 482,
    project_id = 77,
    title = "Bump the pinned acli",
    description = "The pin moves to **1.3.36**.\n\nDigests come from the tap.",
    state = "opened",
    draft = false,
    created_at = "2024-05-01T09:00:00.000Z",
    updated_at = "2024-05-03T10:00:00.000Z",
    source_branch = "feature/acli.bump",
    target_branch = "main",
    author = gl_user("ana", "Ana"),
    assignees = { gl_user("me", "Me Myself") },
    reviewers = { gl_user("me", "Me Myself") },
    web_url = "https://gitlab.example.test/acme/payments/-/merge_requests/482",
    references = { short = "!482", full = "acme/payments!482" },
  }, overrides or {})
end

-- A note as `mr note list -F json` prints one, with every field the run
-- against the instance recorded; `overrides` set the ones a test is about.
local function gl_note(id, author, body, overrides)
  return vim.tbl_extend("force", {
    attachment = vim.NIL,
    author = author,
    body = body,
    commit_id = vim.NIL,
    confidential = false,
    created_at = "2024-05-02T10:00:00.000Z",
    expires_at = vim.NIL,
    file_name = vim.NIL,
    id = id,
    internal = false,
    noteable_id = 9001,
    noteable_iid = 482,
    noteable_type = "MergeRequest",
    position = vim.NIL,
    project_id = 77,
    resolvable = false,
    resolved = vim.NIL,
    resolved_at = vim.NIL,
    resolved_by = vim.NIL,
    system = false,
    title = vim.NIL,
    type = vim.NIL,
    updated_at = "2024-05-02T11:00:00.000Z",
  }, overrides or {})
end

local DIFF_REFS = { base_sha = string.rep("a", 40), start_sha = string.rep("b", 40), head_sha = string.rep("c", 40) }

local function gl_position(new_line, old_line)
  return vim.tbl_extend("force", DIFF_REFS, {
    old_path = "lua/docket/env.lua",
    new_path = "lua/docket/env.lua",
    position_type = "text",
    old_line = old_line or vim.NIL,
    new_line = new_line or vim.NIL,
  })
end

-- The discussions of !482: one GitLab wrote itself, one standalone comment,
-- one diff thread with a system note inside it, and one resolved thread.
local function discussions()
  return {
    { id = string.rep("0", 40), individual_note = true, notes = { gl_note(1, gl_user("ana", "Ana"), "changed the description", { system = true }) } },
    { id = string.rep("1", 40), individual_note = true, notes = { gl_note(2, gl_user("ana", "Ana"), "Repros on staging.") } },
    {
      id = string.rep("2", 40),
      individual_note = false,
      notes = {
        gl_note(3, gl_user("ana", "Ana"), "Why here?", { type = "DiffNote", resolvable = true, resolved = false, position = gl_position(12) }),
        gl_note(4, gl_user("me", "Me Myself"), "Because the window sits in it.", { type = "DiffNote", resolvable = true, resolved = false, position = gl_position(12) }),
        gl_note(5, gl_user("ana", "Ana"), "changed this line in version 2 of the diff", { system = true }),
      },
    },
    {
      id = string.rep("3", 40),
      individual_note = false,
      notes = {
        gl_note(6, gl_user("me", "Me Myself"), "Squash before merging?", {
          type = "DiscussionNote",
          resolvable = true,
          resolved = true,
          resolved_at = "2024-05-03T09:00:00.000Z",
          resolved_by = gl_user("ana", "Ana"),
        }),
      },
    },
  }
end

-- glab as the adapter meets it, answering each verb from the fixtures.
local function glab_answer(overrides)
  return function(argv, opts)
    if argv[2] == "api" and argv[3] == "user" then
      return done(argv, gl_user("me", "Me Myself"))
    end
    if argv[2] == "api" then
      return done(argv, vim.tbl_extend("force", merge_request(), { diff_refs = DIFF_REFS }))
    end
    if argv[2] == "mr" and argv[3] == "list" then
      return done(argv, {
        merge_request(),
        merge_request({ iid = 7, title = "Drop the flag", draft = true, source_branch = "drop-flag" }),
        merge_request({ iid = 9, title = vim.NIL }),
      })
    end
    if argv[2] == "mr" and argv[3] == "view" then
      return done(argv, merge_request(overrides))
    end
    if argv[2] == "mr" and argv[3] == "note" and argv[4] == "list" then
      return done(argv, discussions())
    end
    return done(argv, opts and opts.stdin or "")
  end
end

local function stub_glab(overrides)
  return stub_run(glab_answer(overrides))
end

-- Every client answer below lands in a fast event, as in the editor.

test("fast events: an item opens from answers that land in a fast event, on Jira and on GitLab", function()
  jira.forget()
  glab.forget()
  local _, restore_wait = stub_acli({ signed_in = true, glab = true })
  -- A merge request's buffer is named after the project of the clone the
  -- editor is in, which the open reads off origin.
  local restore_clone = stub_clone(nil, "git@gitlab.example.test:acme/payments.git")
  local projects = { glab = "acme/payments" }
  local jira_answer = function(argv)
    if argv[4] == "search" then
      return done(argv, { found("TIG-7", { assignee = user("acc-me", "Me Myself") }) })
    end
    return done(argv, view_payload())
  end
  local notices, restore_notify = stub_notify()
  local opened = {}
  for _, case in ipairs({ { "jira", "TIG-1001", jira_answer }, { "glab", "!482", glab_answer() } }) do
    -- A buffer an earlier test left may hold edits, which a read refuses.
    local previous = buffer.named(buffer.name(case[1], case[2], projects[case[1]]))
    if previous then
      vim.api.nvim_buf_delete(previous, { force = true })
    end
    local _, restore_run = stub_run_fast(case[3])
    local finished, ok, message
    local buf = buffer.open(case[1], case[2], function(read_ok, read_message)
      finished, ok, message = true, read_ok, read_message
    end)
    vim.wait(2000, function()
      return finished
    end)
    restore_run()
    opened[case[1]] = { ok = ok, message = message, title = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] }
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  restore_notify()
  restore_clone()
  restore_wait()
  eq(opened.jira, { ok = true, title = "# Retry backoff drops the last attempt" })
  eq(opened.glab, { ok = true, title = "# Bump the pinned acli" })
  eq(notices, {})
end)

test("fast events: the dashboard paints rows whose answers land in a fast event", function()
  jira.forget()
  glab.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" } }, "git@gitlab.example.test:acme/payments.git")
  local runs, restore_run = stub_run_fast(checked({ signed_in = true, glab = true }, function(argv)
    if argv[1] == "glab" then
      return glab_answer()(argv)
    end
    return done(argv, { dash_row("PAY-7", "To Do", "Seven") })
  end))
  local notices, restore_notify = stub_notify()
  local buf = list.open({ root = "/w/repo", bare = true })
  local answered = settled(buf)
  local lines = lines_of(buf)
  restore_notify()
  restore_run()
  restore_clone()
  restore_cache()
  eq(answered, true, "every section answered")
  eq(lines[3], "All open tickets (1) · just now")
  eq(lines[4], "  PAY-7   To Do   Seven")
  eq(vim.tbl_contains(lines, "Review requested (2) · just now"), true, table.concat(lines, "\n"))
  eq(vim.tbl_contains(lines, "  !482   opened   Bump the pinned acli"), true, table.concat(lines, "\n"))
  eq(vim.tbl_map(function(call)
    return call.argv[1]
  end, vim.tbl_filter(is_status, runs)), { "acli", "glab" }, "one state check per backend, joined across its sections")
  eq(notices, {})
end)

test("glab: passes the contract and declares every review capability; gh declares none and implements none", function()
  eq(adapters.get("glab"), glab)
  eq(adapters.verify(glab, "glab"), true)
  eq(adapters.verify(gh, "gh"), true)
  eq(gh.capabilities, {})
  for _, call in ipairs(adapters.OPTIONAL) do
    eq(gh[call], nil, "gh implements " .. call .. ", which octo.nvim owns")
  end
  for _, call in ipairs({ "diff", "threads", "line_comment", "thread_resolve", "submit" }) do
    eq(adapters.can(glab, call), true, "glab declares " .. call)
  end
end)

test("glab: both row queries add --per-page and -F json and normalise to rows carrying the source branch", function()
  glab.forget()
  local calls, restore = stub_run(function(argv)
    return done(argv, { merge_request(), merge_request({ iid = 7, title = "Drop the flag", draft = true, source_branch = "drop-flag" }) })
  end)
  local got = {}
  for _, query in ipairs({ config.defaults.sections[4].query.glab, config.defaults.sections[5].query.glab }) do
    glab.rows({ query = query }, function(rows, err, warning)
      got[#got + 1] = { rows = rows, err = err, warning = warning }
    end)
  end
  restore()
  eq(calls[1].argv, { "glab", "mr", "list", "--reviewer=@me", "--per-page", "100", "-F", "json" })
  eq(calls[2].argv, { "glab", "mr", "list", "--assignee=@me", "--per-page", "100", "-F", "json" })
  eq(#got, 2)
  eq(got[1].err, nil)
  eq(got[1].warning, nil)
  local first, second = got[1].rows[1], got[1].rows[2]
  eq({ first.source, first.id, first.state, first.title, first.branch }, { "glab", "!482", "opened", "Bump the pinned acli", "feature/acli.bump" })
  eq({ second.id, second.state, second.branch }, { "!7", "draft", "drop-flag" }, "a draft's state is draft")
  eq(first.target, "main")
  eq(first.author, { id = "ana", name = "Ana" })
  eq(first.assignee, { id = "me", name = "Me Myself" })
  eq(first.url, "https://gitlab.example.test/acme/payments/-/merge_requests/482")
  eq(glab.branch(first), "feature/acli.bump", "the branch is the row's own")
  eq(glab.url({ id = "!482" }), first.url, "the address is remembered by iid")
  eq(row.sort({ second, first })[1].id, "!7")
end)

test("glab: a row whose source project is not its target's is from a fork; one of the same project, or one whose list left either id out, is not, and the mark survives the cache", function()
  glab.forget()
  local _, restore_cache = scratch_cache()
  local _, restore = stub_run(function(argv)
    -- A fork's id on either side of its target's: the pair differing is the
    -- mark, whichever is the larger.
    return done(argv, {
      merge_request({ iid = 482, source_branch = "main", source_project_id = 91, target_project_id = 77 }),
      merge_request({ iid = 15, title = "Older fork", source_branch = "patch-1", source_project_id = 12, target_project_id = 77 }),
      merge_request({ iid = 7, title = "Drop the flag", source_branch = "drop-flag", source_project_id = 77, target_project_id = 77 }),
      merge_request({ iid = 9, title = "No target", source_branch = "patch-1", source_project_id = 91 }),
      merge_request({ iid = 11, title = "No source", source_branch = "patch-1", target_project_id = 77 }),
      merge_request({ iid = 13, title = "Neither", source_branch = "patch-1" }),
    })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err, warning)
    got = { rows = rows, err = err, warning = warning }
  end)
  restore()
  eq(got.err, nil)
  eq(got.warning, nil)
  eq(vim.tbl_map(function(r)
    return { r.id, r.fork }
  end, got.rows), { { "!482", true }, { "!15", true }, { "!7" }, { "!9" }, { "!11" }, { "!13" } }, "only a differing pair marks a row")
  eq(cache.write("fork-rows", got.rows), true)
  eq(vim.tbl_map(function(r)
    return r.fork
  end, cache.read("fork-rows").rows), { true, true }, "the dash renders cached rows, so the mark has to come back off disk")
  restore_cache()
end)

test("glab: a row the client returned that cannot be built is named in the warning, and a client that failed is the error", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { merge_request(), merge_request({ iid = 9, title = vim.NIL }) })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err, warning)
    got = { rows = rows, err = err, warning = warning }
  end)
  restore()
  eq(#got.rows, 1)
  eq(got.warning, "row: !9 needs a non-empty string for title")
  _, restore = stub_run(function(argv)
    return failed(argv, 1, "ERROR: 401 Unauthorized")
  end)
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err)
    got = { rows = rows, err = err }
  end)
  restore()
  eq(got, { err = "glab exited 1\nERROR: 401 Unauthorized" })
end)

test("glab: a row's assignee is its assignee and not its reviewer", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { merge_request({ assignees = { gl_user("bea", "Bea") }, reviewers = { gl_user("me", "Me Myself") } }) })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--reviewer=@me" } }, function(rows)
    got = rows
  end)
  restore()
  eq(got[1].assignee, { id = "bea", name = "Bea" })
end)

test("glab: a section whose every row is refused is the error, not a warning", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { merge_request({ iid = 9, title = vim.NIL }), merge_request({ iid = 11, title = vim.NIL }) })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  restore()
  eq(got[1], nil)
  eq(got[2], "row: !9 needs a non-empty string for title\nrow: !11 needs a non-empty string for title")
  eq(got[3], nil)
end)

test("glab: a row for a closed, a merged and a locked merge request carries that state", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, {
      merge_request({ iid = 5, state = "closed" }),
      merge_request({ iid = 6, state = "merged" }),
      merge_request({ iid = 8, state = "locked" }),
    })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows)
    got = rows
  end)
  restore()
  eq(vim.tbl_map(function(r)
    return r.state
  end, got), { "closed", "merged", "locked" })
end)

test("glab: item completion is in row order whatever order the rows arrived in", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, {
      merge_request({ iid = 482 }),
      merge_request({ iid = 7, title = "Drop the flag" }),
      merge_request({ iid = 33, title = "Third" }),
    })
  end)
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function() end)
  restore()
  eq(vim.tbl_map(function(candidate)
    return candidate.id
  end, glab.complete("item", "")), { "!7", "!33", "!482" })
end)

test("glab: a section that answers after a login is not shown, and its rows are not remembered", function()
  glab.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err)
    got = { rows, err }
  end)
  glab.forget()
  pending[1].on_done(done(pending[1].argv, { merge_request() }))
  spawn.run = saved
  eq(got[1], nil)
  eq(
    got[2],
    "glab: a login ran while this section was in flight, so its rows are not shown; refresh to ask again"
  )
  eq(glab.complete("item", ""), {}, "the previous account's titles are not offered")
  eq(glab.url({ id = "!482" }), nil, "and its addresses are not remembered")
  eq(glab.auth_fields()[1].default, glab.DEFAULT_HOST, "nor its host")
end)

test("glab: diff reads both branches from mr view and the three shas from api, decoded here since api has no --jq", function()
  local calls, restore = stub_glab()
  local got
  glab.diff("!482", function(diff, err)
    got = { diff, err }
  end)
  restore()
  eq(calls[1].argv, { "glab", "mr", "view", "482", "-F", "json" })
  eq(calls[2].argv, { "glab", "api", "projects/:id/merge_requests/482" })
  eq(has(calls[2].argv, "--jq"), false, "api has no --jq")
  eq(got, { { source = "feature/acli.bump", target = "main", refs = DIFF_REFS } })
end)

test("glab: diff takes the branches from mr view and the shas from api", function()
  local _, restore = stub_run(function(argv)
    if argv[2] == "api" then
      return done(
        argv,
        vim.tbl_extend(
          "force",
          merge_request({ source_branch = "stale", target_branch = "stale" }),
          { diff_refs = DIFF_REFS }
        )
      )
    end
    return done(argv, merge_request())
  end)
  local got
  glab.diff("!482", function(diff)
    got = diff
  end)
  restore()
  eq(got, { source = "feature/acli.bump", target = "main", refs = DIFF_REFS })
end)

test("glab: threads leave system notes out, read individual_note, and carry position, resolvable and resolved per note", function()
  local calls, restore = stub_glab()
  local got
  glab.threads("!482", function(threads, err)
    got = { threads, err }
  end)
  restore()
  eq(calls[1].argv, { "glab", "mr", "note", "list", "482", "-F", "json" })
  eq(got[2], nil)
  local threads = got[1]
  eq(#threads, 3, "the discussion GitLab wrote itself is gone")
  eq({ threads[1].id, threads[1].individual, #threads[1].notes }, { string.rep("1", 40), true, 1 }, "a standalone comment")
  eq(threads[1].resolvable, false)
  eq(threads[1].position, nil)
  local thread = threads[2]
  eq({ thread.id, thread.individual, #thread.notes }, { string.rep("2", 40), false, 2 }, "a thread, its system note left out")
  eq(thread.resolvable, true)
  eq(thread.resolved, false)
  eq(thread.position.new_path, "lua/docket/env.lua")
  eq(thread.position.new_line, 12)
  eq(thread.position.old_line, nil)
  eq(thread.position.head_sha, DIFF_REFS.head_sha, "the position is carried as GitLab sent it")
  -- The fixture writes JSON null for the old line, which decodes to nil.
  local position = gl_position(12)
  position.old_line = nil
  eq(thread.notes[1], {
    id = "3",
    author = { id = "ana", name = "Ana" },
    body = "Why here?",
    created = "2024-05-02T10:00:00.000Z",
    updated = "2024-05-02T11:00:00.000Z",
    type = "DiffNote",
    resolvable = true,
    resolved = false,
    position = position,
  })
  eq(thread.notes[2].author.id, "me")
  eq({ threads[3].resolvable, threads[3].resolved, threads[3].notes[1].type }, { true, true, "DiscussionNote" })
  eq(threads[3].individual, false, "one note is still a thread when individual_note says so: the flag is read, not the count")
end)

test("glab: threads take the thread's state and position from the first note", function()
  local mixed = {
    {
      id = string.rep("4", 40),
      individual_note = false,
      notes = {
        gl_note(10, gl_user("ana", "Ana"), "First.", { type = "DiffNote", resolvable = true, resolved = false, position = gl_position(12) }),
        gl_note(11, gl_user("me", "Me Myself"), "Second.", { type = "DiffNote", resolvable = false, resolved = true, position = gl_position(99) }),
      },
    },
  }
  local _, restore = stub_run(function(argv)
    return done(argv, mixed)
  end)
  local got
  glab.threads("!482", function(threads)
    got = threads
  end)
  restore()
  eq({ got[1].resolvable, got[1].resolved }, { true, false }, "the first note's state, not the last")
  eq(got[1].position.new_line, 12, "the first note's position")
  eq({ got[1].notes[2].resolvable, got[1].notes[2].resolved }, { false, true }, "each note keeps its own")
end)

test("glab: an item holds markdown as text, its comments in discussion order, and never touches adf", function()
  glab.forget()
  local touched, saved = 0, {}
  for _, name in ipairs({ "render", "serialise", "editable" }) do
    saved[name] = adf[name]
    adf[name] = function(...)
      touched = touched + 1
      return saved[name](...)
    end
  end
  local calls, restore = stub_glab()
  local got
  glab.item("!482", function(it, err, me_err)
    got = { it, err, me_err }
  end)
  restore()
  for name, fn in pairs(saved) do
    adf[name] = fn
  end
  eq(calls[1].argv, { "glab", "api", "user" })
  eq(calls[2].argv, { "glab", "mr", "view", "482", "-F", "json" })
  eq(calls[3].argv, { "glab", "mr", "note", "list", "482", "-F", "json" })
  eq(got[2], nil)
  eq(got[3], nil)
  local it = got[1]
  eq(touched, 0, "a GitLab body is markdown and goes nowhere near adf")
  eq(it.body, "The pin moves to **1.3.36**.\n\nDigests come from the tap.", "the description is the text glab printed")
  eq({ it.source, it.id, it.title, it.state, it.url }, { "glab", "!482", "Bump the pinned acli", "opened", merge_request().web_url })
  eq(it.assignee, { id = "me", name = "Me Myself" })
  eq(it.reporter, { id = "ana", name = "Ana" })
  eq(it.me, "me")
  eq(vim.tbl_map(function(comment)
    return comment.id
  end, it.comments), { "2", "3", "4", "6" }, "system notes are gone, the rest in discussion order")
  eq(it.comments[3].body, "Because the window sits in it.")
  eq(it.comments[3].updated, "2024-05-02T11:00:00.000Z")
  eq(it.missing, 0)
  local regions = item.regions(it)
  eq(regions[4].editable, true, "the account's own note is editable")
  eq(regions[2].editable, false)
  eq(regions[2].reason, "written by Ana")
end)

test("glab: an item carries the source branch and whether it comes from a fork, from mr view", function()
  glab.forget()
  local function read(overrides)
    local got
    local _, restore = stub_glab(overrides)
    glab.item("!482", function(it, err)
      got = { it, err }
    end)
    restore()
    eq(got[2], nil)
    return got[1]
  end
  local own = read({ source_project_id = 77, target_project_id = 77 })
  eq({ own.branch, own.fork }, { "feature/acli.bump" }, "within its own project")
  local forked = read({ source_branch = "main", source_project_id = 91, target_project_id = 77 })
  eq({ forked.branch, forked.fork }, { "main", true }, "from a fork")
  local unmarked = read()
  eq({ unmarked.branch, unmarked.fork }, { "feature/acli.bump" }, "an answer naming neither project is not marked")
end)

test("glab: an item still opens when the identity is unknown, with the reason beside it", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    if argv[2] == "api" and argv[3] == "user" then
      return failed(argv, 1, "ERROR: 401 Unauthorized")
    end
    if argv[3] == "note" then
      return done(argv, discussions())
    end
    return done(argv, merge_request())
  end)
  local got
  glab.item("!482", function(it, err, me_err)
    got = { it, err, me_err }
  end)
  restore()
  eq(got[2], nil, "the item opens")
  eq(got[1].me, nil)
  eq(got[3], "glab exited 1\nERROR: 401 Unauthorized")
  eq(item.regions(got[1])[2].editable, false, "every note is read-only for want of an ownership test")
end)

test("glab: an item read across a login opens read-only with the reason, and no comment reads as the new account's", function()
  glab.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  glab.item("!482", function(it, err, me_err)
    got = { it, err, me_err }
  end)
  -- The identity answers under the account signing out, and the login runs
  -- before the two reads that follow it land.
  pending[1].on_done(done(pending[1].argv, gl_user("me", "Me Myself")))
  glab.forget()
  pending[2].on_done(done(pending[2].argv, merge_request()))
  pending[3].on_done(done(pending[3].argv, discussions()))
  spawn.run = saved
  eq(got[2], nil, "the item still opens")
  eq(got[1].me, nil)
  eq(got[3], "a login ran while the item was read; open it again")
  local regions = item.regions(got[1])
  eq(regions[4].editable, false, "the note the previous account wrote is not offered for editing")
  eq(regions[4].reason, "the account's own identifier is unknown, so no comment can be told from another account's")
end)

test("glab: whoami asks api user once, joins callers during the query, reports a failure verbatim, and forget drops it", function()
  glab.forget()
  local calls, restore = stub_glab()
  local answers = {}
  glab.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  glab.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  restore()
  eq(answers, { { "me" }, { "me" } })
  eq(#calls, 1)
  eq(calls[1].argv, { "glab", "api", "user" })

  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  glab.forget()
  answers = {}
  glab.whoami(function(id)
    answers[#answers + 1] = id
  end)
  glab.whoami(function(id)
    answers[#answers + 1] = id
  end)
  eq(#pending, 1, "one query in flight for two callers")
  pending[1].on_done(done(pending[1].argv, gl_user("me", "Me Myself")))
  spawn.run = saved
  eq(answers, { "me", "me" })

  glab.forget()
  local got
  _, restore = stub_run(function(argv)
    return failed(argv, 1, "ERROR: 401 Unauthorized")
  end)
  glab.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got, { nil, "glab exited 1\nERROR: 401 Unauthorized" })

  glab.forget()
  _, restore = stub_run(function(argv)
    return done(argv, { id = 14 })
  end)
  glab.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got[1], nil)
  eq(got[2]:find("no `username`", 1, true) ~= nil, true, got[2])
end)

test("glab: an answer landing after forget is not remembered", function()
  glab.forget()
  local pending = {}
  local saved = spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  glab.whoami(function(id, err)
    got = { id, err }
  end)
  glab.forget()
  pending[1].on_done(done(pending[1].argv, gl_user("old", "Old Account")))
  spawn.run = saved
  eq(got[1], nil)
  eq(got[2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, got[2])
  local calls, restore = stub_glab()
  glab.whoami(function(id)
    got = id
  end)
  restore()
  eq(#calls, 1, "the next caller asks again")
  eq(got, "me")
end)

test("whoami: a request that raises is reported and leaves no query in flight, and one waiter that raises answers the rest", function()
  -- What each client prints for the account `me`.
  local answers = {
    jira = { found("TIG-7", { assignee = user("me", "Me Myself") }) },
    glab = gl_user("me", "Me Myself"),
    gh = "me\n",
  }
  for name, adapter in pairs({ jira = jira, glab = glab, gh = gh }) do
    adapter.forget()
    local saved = spawn.run
    spawn.run = function()
      error("boom")
    end
    local got
    adapter.whoami(function(id, err)
      got = { id, err }
    end)
    spawn.run = saved
    eq(got[1], nil, name)
    eq(got[2]:find("boom", 1, true) ~= nil, true, name .. ": " .. tostring(got[2]))

    -- The slot is free again, so the next caller asks rather than joining a
    -- query nothing will answer.
    local calls, restore = stub_run(function(argv)
      return done(argv, answers[name])
    end)
    local answered = false
    adapter.whoami(function(id)
      answered = id
    end)
    restore()
    eq(#calls, 1, name .. ": the next caller asks again")
    eq(answered, "me", name)

    -- Two callers on one query, the first raising: the second is still answered
    -- and the raise is reported rather than escaping into the exit handler.
    adapter.forget()
    local pending = {}
    spawn.run = function(argv, _, on_done)
      pending[#pending + 1] = { argv = argv, on_done = on_done }
    end
    local second = false
    adapter.whoami(function()
      error("the first caller raised")
    end)
    adapter.whoami(function(id)
      second = id
    end)
    eq(#pending, 1, name .. ": one query for two callers")
    local notices, restore_notify = stub_notify()
    pending[1].on_done(done(pending[1].argv, answers[name]))
    spawn.run = saved
    vim.wait(1000, function()
      return #notices > 0
    end)
    restore_notify()
    eq(second, "me", name .. ": the caller behind the raise is answered")
    eq(#notices, 1, name .. ": the raise is reported")
    eq(notices[1].level, vim.log.levels.ERROR, name)
    eq(notices[1].message:find("the first caller raised", 1, true) ~= nil, true, name .. ": " .. notices[1].message)
  end
end)

test("whoami: glab and gh refuse a stale answer, and a caller after a login starts its own query", function()
  for name, adapter in pairs({ glab = glab, gh = gh }) do
    local function answer(login)
      return name == "glab" and gl_user(login, login) or login .. "\n"
    end
    adapter.forget()
    local pending, saved = {}, spawn.run
    spawn.run = function(argv, _, on_done)
      pending[#pending + 1] = { argv = argv, on_done = on_done }
    end
    local stale, fresh
    adapter.whoami(function(id, err)
      stale = { id, err }
    end)
    adapter.forget()
    adapter.whoami(function(id)
      fresh = id
    end)
    eq(#pending, 2, name .. ": a caller after a login starts its own query")
    pending[1].on_done(done(pending[1].argv, answer("old")))
    eq(stale[1], nil, name .. ": the answer from before the login is refused")
    eq(stale[2]:find("a login ran while the query was in flight", 1, true) ~= nil, true, name .. ": " .. tostring(stale[2]))
    eq(fresh, nil, name .. ": and reaches no caller of the fresh query")
    local between
    adapter.whoami(function(id)
      between = id
    end)
    eq(#pending, 2, name .. ": the fresh query is still the one in flight")
    eq(between, nil, name .. ": and the stale answer was not remembered")
    pending[2].on_done(done(pending[2].argv, answer("me")))
    eq({ fresh, between }, { "me", "me" }, name)
    adapter.whoami(function() end)
    spawn.run = saved
    eq(#pending, 2, name .. ": the fresh answer is remembered")
  end
end)

test("glab: whoami names the host in context, since api falls back to gitlab.com outside a clone", function()
  glab.forget()
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "gitlab.example.test\n")
  end)
  glab.auth_status()
  restore_wait()
  local calls, restore = stub_run(function(argv)
    return done(argv, gl_user("me", "Me Myself"))
  end)
  glab.whoami(function() end)
  restore()
  eq(calls[1].argv, { "glab", "api", "user", "--hostname", "gitlab.example.test" })

  glab.forget()
  calls, restore = stub_run(function(argv)
    return done(argv, gl_user("me", "Me Myself"))
  end)
  glab.whoami(function() end)
  restore()
  eq(calls[1].argv, { "glab", "api", "user" }, "with no host known there is nothing to name")
end)

test("auth_status: a signed-in client's report is the detail, whichever stream it came on", function()
  local report = "gitlab.example.test\n  \226\156\147 Logged in to gitlab.example.test as me (keyring)\n"
  local _, restore = stub_wait(function(argv)
    return { argv = argv, ok = true, code = 0, stdout = "", stderr = report, timed_out = false }
  end)
  local status = glab.auth_status()
  restore()
  eq(status.authenticated, true)
  eq(status.detail, vim.trim(report), "glab writes auth status to stderr")

  local gh_report = "github.com\n  \226\156\147 Logged in to github.com account me (keyring)\n  - Token scopes: 'repo'\n"
  _, restore = stub_wait(function(argv)
    return { argv = argv, ok = true, code = 0, stdout = "", stderr = gh_report, timed_out = false }
  end)
  status = gh.auth_status()
  restore()
  eq(status.authenticated, true)
  eq(status.detail, vim.trim(gh_report), "gh's report reaches the detail whichever stream carries it")
end)

test("glab and gh pin the directory the mode was entered in, so a tab elsewhere cannot move the project", function()
  glab.forget()
  gh.forget()
  local base = vim.fn.getcwd()
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  glab.auth_status()
  gh.auth_status()
  restore_wait()
  -- A tab moved into another directory is what the launcher makes away from
  -- tmux, and what a person makes by hand.
  vim.cmd.tabnew()
  vim.cmd.tcd(vim.fn.fnameescape(vim.fn.fnamemodify(base, ":h")))
  local elsewhere = vim.fn.getcwd()
  local calls, restore = stub_run(function(argv)
    if argv[1] == "glab" then
      return done(argv, { merge_request() })
    end
    return done(argv, {
      { number = 12, title = "Add the teardown", state = "OPEN", isDraft = false, headRefName = "teardown", url = "https://github.com/acme/payments/pull/12" },
    })
  end)
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function() end)
  gh.rows({ query = { "pr", "list" } }, function() end)
  restore()
  vim.cmd.tabclose()
  eq(elsewhere ~= base, true, "the tab did move the editor's own directory")
  eq(calls[1].opts.cwd, base, "glab runs where the mode was entered")
  eq(calls[2].opts.cwd, base, "gh runs where the mode was entered")
end)

test("glab: a call that chains several reads runs each in the clone it started in, whatever mode is entered meanwhile", function()
  glab.forget()
  -- auth_status() takes the directory every later call runs in; a second
  -- mode entered in another clone while the first call's reads are in
  -- flight moves it.
  local cwd, saved_getcwd = "/w/a", vim.fn.getcwd
  vim.fn.getcwd = function()
    return cwd
  end
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  local pending, saved_run = {}, spawn.run
  spawn.run = function(argv, opts, on_done)
    pending[#pending + 1] = { argv = argv, cwd = opts and opts.cwd, on_done = on_done }
  end
  local function enter(dir)
    cwd = dir
    glab.auth_status()
  end
  local function answer(payload)
    local call = table.remove(pending, 1)
    call.on_done(done(call.argv, payload))
    return call
  end
  -- Run under pcall, so a failure still puts getcwd back for the tests after.
  local ok, err = pcall(function()
    enter("/w/a")
    glab.item("!12", function() end)
    enter("/w/b")
    eq(answer(gl_user("me", "Me Myself")).argv, { "glab", "api", "user" })
    eq({ pending[1].argv[3], pending[1].cwd }, { "view", "/w/a" }, "item: mr view")
    answer(merge_request({ iid = 12 }))
    eq({ pending[1].argv[3], pending[1].cwd }, { "note", "/w/a" }, "item: mr note list")
    answer(discussions())

    enter("/w/a")
    glab.diff("!12", function() end)
    enter("/w/b")
    answer(merge_request({ iid = 12 }))
    eq({ pending[1].argv[2], pending[1].cwd }, { "api", "/w/a" }, "diff: the api read")
    answer(vim.tbl_extend("force", merge_request({ iid = 12 }), { diff_refs = DIFF_REFS }))

    enter("/w/a")
    glab.submit("!12", { summary = "Looks right.", approve = true }, function() end)
    enter("/w/b")
    eq(answer("").argv[3], "note")
    eq({ pending[1].argv[3], pending[1].cwd }, { "approve", "/w/a" }, "submit: the approval")
    answer("")

    enter("/w/a")
    glab.rows({ query = { "mr", "list" } }, function() end)
    enter("/w/b")
    glab.rows({ query = { "mr", "list" } }, function() end)
    eq({ pending[1].cwd, pending[2].cwd }, { "/w/a", "/w/b" }, "a call of one read runs where the mode it belongs to was entered")
    answer({})
    answer({})
  end)
  spawn.run = saved_run
  vim.fn.getcwd = saved_getcwd
  restore_wait()
  assert(ok, err)
end)

test("glab: the state is the exit code, the login puts the token on stdin and never in argv, and forget drops the rows", function()
  glab.forget()
  local _, restore_run = stub_glab()
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function() end)
  glab.whoami(function() end)
  restore_run()
  eq(glab.complete("item", "4"), { { id = "!482", title = "Bump the pinned acli" } }, "item references come from the rows")
  eq(glab.complete("item", ""), { { id = "!7", title = "Drop the flag" }, { id = "!482", title = "Bump the pinned acli" } })
  eq(glab.auth_fields()[1].default, "gitlab.example.test", "a row's web_url names the host when no status has been read")

  -- The status fixture names a host no row carries: with the two the same,
  -- either source alone satisfies the assertion below.
  glab.forget()
  local calls, restore = stub_wait(function(argv)
    if argv[3] == "status" then
      return failed(argv, 1, "gitlab.status.test\n  x gitlab.status.test: API call failed\n  ! No token found\n")
    end
    return done(argv, "")
  end)
  local status = glab.auth_status()
  eq(status.authenticated, false)
  eq(status.missing, false)
  eq(status.detail, "glab exited 1\ngitlab.status.test\n  x gitlab.status.test: API call failed\n  ! No token found\n")
  eq(glab.auth_fields()[1].name, "hostname")
  eq(glab.auth_fields()[1].default, "gitlab.status.test", "the host is read off the status output, not off a row's web_url")
  eq(glab.token_url(), "https://gitlab.status.test/-/user_settings/personal_access_tokens")

  -- Rows again, so the login below has an account's worth of them to drop.
  local _, restore_rows = stub_glab()
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function() end)
  restore_rows()
  eq(glab.complete("item", "4"), { { id = "!482", title = "Bump the pinned acli" } })
  eq(glab.auth_fields()[1].default, "gitlab.status.test", "a row does not replace a host the status named")

  local result = glab.auth_login("glpat-secret", { hostname = "gitlab.other.test" })
  eq(result.ok, true)
  eq(calls[2].argv, { "glab", "auth", "login", "--stdin", "--hostname", "gitlab.other.test" })
  eq(calls[2].opts.stdin, "glpat-secret\n")
  for _, word in ipairs(calls[2].argv) do
    eq(word:find("secret", 1, true), nil, "the token is nowhere in the argument list")
  end
  eq(glab.token_url(), "https://gitlab.other.test/-/user_settings/personal_access_tokens", "a login names the host")
  restore()
  eq(glab.complete("item", ""), {}, "the previous account's rows are gone")
  local run_calls, restore_glab = stub_glab()
  glab.whoami(function() end)
  restore_glab()
  eq(#run_calls, 1, "the identity is gone, so whoami asks again")

  _, restore = stub_wait(function(argv)
    return done(argv, "gitlab.example.test\n  ✓ Logged in to gitlab.example.test as me\n")
  end)
  eq(glab.auth_status().authenticated, true)
  restore()
  _, restore = stub_wait(function(argv)
    return { argv = argv, ok = false, code = spawn.MISSING, stdout = "", stderr = "ENOENT: no such file or directory", timed_out = false }
  end)
  status = glab.auth_status()
  restore()
  eq({ status.authenticated, status.missing }, { false, true })
end)

test("a failed login leaves the remembered host alone, in both review adapters", function()
  for name, adapter in pairs({ glab = glab, gh = gh }) do
    adapter.forget()
    local _, restore = stub_wait(function(argv)
      if argv[3] == "status" then
        return done(argv, name == "glab" and "gitlab.example.test\n" or "github.example.test\n")
      end
      return failed(argv, 1, "ERROR: invalid token")
    end)
    adapter.auth_status()
    local before = adapter.token_url()
    local result = adapter.auth_login("token-wrong", { hostname = name .. ".typo.test" })
    restore()
    eq(result.ok, false, name)
    eq(adapter.token_url(), before, name .. ": a login that failed names no host")
    eq(adapter.auth_fields()[1].default, before:match("^https://([^/]+)/"), name)
  end
end)

test("adapters: auth_status takes its callback, and given one runs the same check through spawn.run and hands on what the blocking form returns", function()
  eq(adapters.ARITY.auth_status, 2, "the callback and the clone the check is about")
  for name, module in pairs({ jira = jira, glab = glab, gh = gh }) do
    eq({ adapters.verify(module, name) }, { true }, name)
  end
  local adapter = bare_adapter()
  adapter.auth_status = taking(1)
  eq(
    { adapters.verify(adapter, "x") },
    { false, "adapter x: auth_status takes 1 parameters and the contract gives it 2" },
    "an auth_status with its callback alone is refused"
  )
  local function missing(argv)
    return failed(argv, spawn.MISSING, "ENOENT: no such file or directory")
  end
  local cases = {
    {
      adapter = jira,
      argv = argv_of("auth", "status"),
      answers = {
        function(argv)
          return done(argv, STATUS_SIGNED_IN)
        end,
        function(argv)
          return failed(argv, 1, "✗ Not authenticated")
        end,
        missing,
      },
    },
    {
      adapter = glab,
      argv = { "glab", "auth", "status" },
      cwd = vim.fn.getcwd(),
      answers = {
        function(argv)
          return done(argv, "gitlab.example.test\n  ✓ Logged in to gitlab.example.test as me\n")
        end,
        function(argv)
          return failed(argv, 1, "gitlab.example.test\n  x gitlab.example.test: API call failed\n")
        end,
        missing,
      },
    },
    {
      adapter = gh,
      argv = { "gh", "auth", "status", "--active" },
      cwd = vim.fn.getcwd(),
      answers = {
        function(argv)
          return done(argv, "github.com\n  ✓ Logged in to github.com account me (keyring)\n")
        end,
        function(argv)
          return failed(argv, 1, "You are not logged into any GitHub hosts. To log in, run: gh auth login")
        end,
        missing,
      },
    },
  }
  for _, case in ipairs(cases) do
    for index, answer in ipairs(case.answers) do
      local label = ("%s answer %d"):format(case.argv[1], index)
      case.adapter.forget()
      local waits, restore_wait = stub_wait(answer)
      local blocking = case.adapter.auth_status()
      restore_wait()
      case.adapter.forget()
      local runs, restore_run = stub_run(answer)
      local guarded, restore_guard = stub_wait(function(argv)
        error("the callback form waited on " .. table.concat(argv, " "))
      end)
      local got
      local returned = case.adapter.auth_status(function(status)
        got = status
      end)
      restore_guard()
      restore_run()
      eq(returned, nil, label .. ": nothing returned")
      eq(#guarded, 0, label .. ": spawn.wait was never reached")
      eq(got, blocking, label .. ": the state the blocking form returns")
      eq(#runs, 1, label)
      eq({ runs[1].argv, waits[1].argv }, { case.argv, case.argv }, label .. ": the same command")
      eq(runs[1].opts and runs[1].opts.cwd, case.cwd, label .. ": the directory the editor is in, for a review client")
    end
  end

  -- Given a clone, a review client checks there, and later calls given a bare
  -- identifier run there too; Jira's verdict is the account's and reads no
  -- directory. The dashboard passes the root it shows this way.
  for _, case in ipairs({ { adapter = glab, cwd = "/w/given", later = { "glab", "api", "user" } }, { adapter = gh, cwd = "/w/given", later = { "gh", "api", "user" } }, { adapter = jira } }) do
    local name = case.adapter == jira and "jira" or case.later[1]
    case.adapter.forget()
    local runs, restore_run = stub_run(function(argv)
      return done(argv, "")
    end)
    local guarded, restore_guard = stub_wait(function(argv)
      error("the callback form waited on " .. table.concat(argv, " "))
    end)
    case.adapter.auth_status(function() end, "/w/given")
    if case.later then
      case.adapter.whoami(function() end)
    end
    restore_guard()
    restore_run()
    case.adapter.forget()
    eq(#guarded, 0, name)
    eq(runs[1].opts and runs[1].opts.cwd, case.cwd, name .. ": the check runs in the clone given")
    if case.later then
      eq(vim.list_slice(runs[2].argv, 1, 3), case.later, name)
      eq(runs[2].opts.cwd, "/w/given", name .. ": and so does a later call given no directory of its own")
    end
  end

  -- What the answer names is kept as the blocking form keeps it.
  jira.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, STATUS_ONLY_SITE)
  end)
  jira.auth_status(function() end)
  restore()
  eq(jira.url({ id = "TIG-1" }), "https://status-only.atlassian.net/browse/TIG-1", "Jira's site")
  glab.forget()
  _, restore = stub_run(cases[2].answers[1])
  glab.auth_status(function() end)
  restore()
  eq(glab.token_url(), "https://gitlab.example.test/-/user_settings/personal_access_tokens", "GitLab's host")
  gh.forget()
  local runs
  runs, restore = stub_run(cases[3].answers[1])
  gh.auth_status(function() end)
  gh.auth_status(function() end)
  restore()
  eq(runs[2].argv, { "gh", "auth", "status", "--active", "--hostname", "github.com" }, "GitHub's host, which the next check asks about")
  jira.forget()
  glab.forget()
  gh.forget()
end)

test("adapters: a state check answered after forget() records no host and no site, since it describes the account signed in before", function()
  local cases = {
    { adapter = jira, output = STATUS_ONLY_SITE, recorded = function()
      return jira.url({ id = "TIG-1" })
    end },
    { adapter = glab, output = "gitlab.held.test\n  ✓ Logged in to gitlab.held.test as me\n", recorded = glab.token_url },
    { adapter = gh, output = "github.held.test\n  ✓ Logged in to github.held.test account me\n", recorded = gh.token_url },
  }
  local found = {}
  for _, case in ipairs(cases) do
    for _, forgotten in ipairs({ false, true }) do
      case.adapter.forget()
      local unset = case.recorded()
      local held, answer, restore = stub_run_held()
      local got
      case.adapter.auth_status(function(status)
        got = status
      end)
      if forgotten then
        case.adapter.forget()
      end
      answer(1, done(held[1].argv, case.output))
      restore()
      eq(got.authenticated, true, "the answer still reaches the caller")
      found[#found + 1] = case.recorded() ~= unset
    end
    case.adapter.forget()
  end
  eq(found, { true, false, true, false, true, false }, "jira, glab and gh: recorded when nothing ran between, and not after a forget()")
end)

test("glab: a login drops the addresses read under the previous account", function()
  glab.forget()
  local _, restore = stub_glab()
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function() end)
  restore()
  eq(glab.url({ id = "!482" }), merge_request().web_url)
  glab.forget()
  local url, err = glab.url({ id = "!482" })
  eq(url, nil)
  eq(err, "!482 has not been read this session, so its address is unknown")
end)

test("glab: user completion asks the project's users and refuses a query needing encoding", function()
  local calls, restore = stub_wait(function(argv)
    return done(argv, { gl_user("ana", "Ana"), { username = "bea" }, { name = "no username" } })
  end)
  local found = glab.complete("user", "a")
  eq(glab.complete("user", "a b"), {}, "a query outside [%w._-] is not sent")
  eq(glab.complete("user", "a/b"), {})
  restore()
  eq(#calls, 1)
  eq(calls[1].argv, { "glab", "api", "projects/:id/users?search=a" })
  eq(calls[1].opts.timeout, config.options.timeouts.complete)
  eq(found, { { id = "ana", title = "Ana" }, { id = "bea", title = "bea" } })
  local _, restore_fail = stub_wait(function(argv)
    return failed(argv, 1, "ERROR: 404")
  end)
  eq(glab.complete("user", "a"), {})
  restore_fail()
  eq(glab.complete("nothing", "a"), {}, "a kind the omnifunc does not ask for answers nothing")
end)

test("glab: each read names what the client printed instead of a payload", function()
  glab.forget()
  local got = {}
  local _, restore = stub_run(function(argv)
    if argv[3] == "view" then
      return failed(argv, 1, "ERROR: 404 Not Found")
    end
    return done(argv, gl_user("me", "Me Myself"))
  end)
  glab.item("!482", function(it, err)
    got.view = { it, err }
  end)
  restore()
  eq(got.view, { nil, "glab exited 1\nERROR: 404 Not Found" })

  _, restore = stub_run(function(argv)
    if argv[2] == "mr" and argv[3] == "list" then
      return done(argv, { message = "401 Unauthorized" })
    end
    return done(argv, gl_user("me", "Me Myself"))
  end)
  glab.rows({ query = { "mr", "list", "--assignee=@me" } }, function(rows, err)
    got.rows = { rows, err }
  end)
  restore()
  eq(
    got.rows[2],
    "glab: mr list printed something other than a list of merge requests; run\n  glab mr list --assignee=@me --per-page 100 -F json\nby hand to see what it prints"
  )

  _, restore = stub_run(function(argv)
    if argv[3] == "view" then
      return done(argv, { message = "404" })
    end
    return done(argv, gl_user("me", "Me Myself"))
  end)
  glab.item("!482", function(it, err)
    got.empty = { it, err }
  end)
  restore()
  eq(
    got.empty[2],
    "glab: mr view 482 printed no merge request; run\n  glab mr view 482 -F json\nby hand to see what it prints"
  )

  _, restore = stub_run(function(argv)
    return done(argv, merge_request())
  end)
  glab.diff("!482", function(diff, err)
    got.refs = { diff, err }
  end)
  restore()
  eq(
    got.refs[2],
    "glab: the merge request 482 payload carries no `diff_refs`; run\n  glab api projects/:id/merge_requests/482\nby hand to see what it prints"
  )

  _, restore = stub_run(function(argv)
    if argv[3] == "note" then
      return done(argv, { message = "404" })
    end
    return done(argv, merge_request())
  end)
  glab.threads("!482", function(threads, err)
    got.threads = { threads, err }
  end)
  restore()
  eq(
    got.threads[2],
    "glab: mr note list 482 printed something other than a list of discussions; run\n  glab mr note list 482 -F json\nby hand to see what it prints"
  )
end)

test("glab: a section query carrying a space reaches the message as a line a shell accepts", function()
  glab.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { message = "401" })
  end)
  local got
  glab.rows({ query = { "mr", "list", "--search", "bump the pin" } }, function(rows, err)
    got = err
  end)
  restore()
  eq(
    got,
    "glab: mr list printed something other than a list of merge requests; run\n  glab mr list --search 'bump the pin' --per-page 100 -F json\nby hand to see what it prints"
  )
end)

test("glab: the write verbs put the body on stdin and name the merge request before the note", function()
  local calls, restore = stub_glab()
  local outcomes = {}
  local function record(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end
  glab.comment_create("!482", "Looks right.\n\nOne nit.", record)
  glab.comment_update("!482", "4", "Edited.", record)
  glab.comment_delete("!482", "4", record)
  glab.body_update("!482", "New description", record)
  glab.line_comment("!482", { file = "lua/docket/env.lua", line = 12 }, "Here.", record)
  glab.line_comment("!482", { file = "lua/docket/env.lua", old_line = 7 }, "Gone.", record)
  glab.line_comment("!482", { file = "lua/docket/env.lua" }, "Whole file.", record)
  glab.line_comment("!482", { thread = string.rep("2", 40) }, "Agreed.", record)
  glab.line_comment("!482", {}, "Nowhere.", record)
  glab.thread_resolve("!482", string.rep("2", 40), record)
  restore()
  -- A comment nobody has to resolve: without `--resolvable=false` it opens a
  -- thread, which blocks the merge on a project that requires every thread
  -- resolved. `--unique` makes a post repeated after a timeout post nothing
  -- when the first one landed. A line comment and a reply carry neither flag,
  -- since glab refuses both beside `--file` and `--reply`.
  eq(calls[1].argv, { "glab", "mr", "note", "create", "482", "--resolvable=false", "--unique" })
  eq(calls[1].opts.stdin, "Looks right.\n\nOne nit.\n", "the body is text, on stdin, with the newline a redirection carries")
  eq(calls[2].argv, { "glab", "mr", "note", "update", "482", "4" })
  eq(calls[2].opts.stdin, "Edited.\n")
  eq(calls[3].argv, { "glab", "mr", "note", "delete", "482", "4", "--yes" })
  eq(calls[4].argv, { "glab", "mr", "update", "482", "--description-file", "-" })
  eq(calls[4].opts.stdin, "New description\n")
  eq(calls[5].argv, { "glab", "mr", "note", "create", "482", "--file", "lua/docket/env.lua", "--line", "12" })
  eq(calls[6].argv, { "glab", "mr", "note", "create", "482", "--file", "lua/docket/env.lua", "--old-line", "7" })
  eq(calls[7].argv, { "glab", "mr", "note", "create", "482", "--file", "lua/docket/env.lua" })
  eq(calls[8].argv, { "glab", "mr", "note", "create", "482", "--reply", string.rep("2", 40) })
  eq(calls[9].argv, { "glab", "mr", "note", "resolve", "482", string.rep("2", 40) })
  eq(#calls, 9, "a position with neither a file nor a thread spawns nothing")
  eq(outcomes[9], { false, "a line comment needs a file, or a thread to reply into" })
  for index, outcome in ipairs(outcomes) do
    if index ~= 9 then
      eq(outcome, { true }, ("call %d"):format(index))
    end
  end
  for _, call in ipairs(calls) do
    for _, word in ipairs(call.argv) do
      eq(word:find("Looks right", 1, true), nil, "no body in an argument list")
    end
  end
end)

test("glab: states are actions from the merge request's state, state_set runs each verb, and submit posts the summary then approves", function()
  local calls, restore = stub_glab()
  local got = {}
  glab.states("!482", function(states)
    got.open = states
  end)
  restore()
  eq(calls[1].argv, { "glab", "mr", "view", "482", "-F", "json" })
  eq(got.open, { { label = "Approve", target = "approve" }, { label = "Merge", target = "merge" }, { label = "Close", target = "close" } })
  _, restore = stub_glab({ state = "closed" })
  glab.states("!482", function(states)
    got.closed = states
  end)
  restore()
  eq(got.closed, { { label = "Reopen", target = "reopen" } })
  _, restore = stub_glab({ state = "merged" })
  glab.states("!482", function(states)
    got.merged = states
  end)
  restore()
  eq(got.merged, {})

  local outcomes = {}
  local function record(ok, err)
    outcomes[#outcomes + 1] = { ok, err }
  end
  calls, restore = stub_glab()
  glab.state_set("!482", "approve", record)
  glab.state_set("!482", "merge", record)
  glab.state_set("!482", "close", record)
  glab.state_set("!482", "reopen", record)
  glab.state_set("!482", "In Progress", record)
  restore()
  eq(calls[1].argv, { "glab", "mr", "approve", "482" })
  eq(calls[2].argv, { "glab", "mr", "merge", "482", "--yes" }, "merge prompts without --yes")
  eq(calls[3].argv, { "glab", "mr", "close", "482" })
  eq(calls[4].argv, { "glab", "mr", "reopen", "482" })
  eq(#calls, 4)
  eq(outcomes[5][1], false)
  eq(outcomes[5][2]:find("approve, merge, close, reopen", 1, true) ~= nil, true, outcomes[5][2])

  calls, restore = stub_glab()
  outcomes = {}
  glab.submit("!482", { summary = "Two nits, both inline.", approve = true }, record)
  glab.submit("!482", { approve = true }, record)
  glab.submit("!482", {}, record)
  glab.submit("!482", { approve = true, head = DIFF_REFS.head_sha }, record)
  restore()
  eq(calls[1].argv, { "glab", "mr", "note", "create", "482", "--resolvable=false", "--unique" }, "the summary is a note nobody has to resolve")
  eq(calls[1].opts.stdin, "Two nits, both inline.\n")
  eq(calls[2].argv, { "glab", "mr", "approve", "482" })
  eq(calls[3].argv, { "glab", "mr", "approve", "482" })
  eq(calls[4].argv, { "glab", "mr", "approve", "482", "--sha", DIFF_REFS.head_sha }, "the head reviewed pins the approval")
  eq(#calls, 4, "a verdict of nothing posts nothing")
  eq(outcomes, { { true }, { true }, { true }, { true } })

  calls, restore = stub_run(function(argv)
    if argv[3] == "note" then
      return failed(argv, 1, "ERROR: 403 Forbidden")
    end
    return done(argv, "")
  end)
  outcomes = {}
  glab.submit("!482", { summary = "x", approve = true }, record)
  restore()
  eq(#calls, 1, "a summary that fails stops before the approval")
  eq(outcomes, { { false, "glab exited 1\nERROR: 403 Forbidden" } })

  calls, restore = stub_run(function(argv)
    if argv[3] == "approve" then
      return failed(argv, 1, "ERROR: 401 Unauthorized")
    end
    return done(argv, "")
  end)
  outcomes = {}
  glab.submit("!482", { summary = "x", approve = true }, record)
  glab.submit("!482", { approve = true }, record)
  restore()
  eq(#calls, 3)
  eq(outcomes[1], {
    false,
    "the summary note is posted and the approval is not; approve alone rather than submitting again\nglab exited 1\nERROR: 401 Unauthorized",
  }, "an approval that failed after the note went out says the note is out")
  eq(outcomes[2], { false, "glab exited 1\nERROR: 401 Unauthorized" }, "with no note to lose the approval's own message stands")
end)

test("glab: a locked merge request offers the open actions", function()
  local _, restore = stub_glab({ state = "locked" })
  local got
  glab.states("!482", function(states)
    got = states
  end)
  restore()
  eq(got, {
    { label = "Approve", target = "approve" },
    { label = "Merge", target = "merge" },
    { label = "Close", target = "close" },
  })
end)

test("glab: an identifier that is not a merge request's is refused before any call", function()
  local calls, restore = stub_glab()
  local got = {}
  glab.item("PROJ-1", function(it, err)
    got.item = { it, err }
  end)
  glab.comment_create("PROJ-1", "x", function(ok, err)
    got.create = { ok, err }
  end)
  restore()
  eq(#calls, 0)
  eq(got.item[1], nil)
  eq(got.item[2], "PROJ-1 is not a merge request identifier such as !482")
  eq(got.create[1], false)
  eq(glab.url({ id = "!999" }), nil)
end)

test("glab: every call refuses an identifier that is not a merge request's", function()
  local calls, restore = stub_glab()
  local got = {}
  local function keep(name)
    return function(first, second)
      got[name] = { first, second }
    end
  end
  glab.threads("PROJ-1", keep("threads"))
  glab.diff("PROJ-1", keep("diff"))
  glab.states("PROJ-1", keep("states"))
  glab.comment_update("PROJ-1", "4", "x", keep("comment_update"))
  glab.comment_delete("PROJ-1", "4", keep("comment_delete"))
  glab.body_update("PROJ-1", "x", keep("body_update"))
  glab.line_comment("PROJ-1", { file = "a" }, "x", keep("line_comment"))
  glab.thread_resolve("PROJ-1", "abc", keep("thread_resolve"))
  glab.state_set("PROJ-1", "approve", keep("state_set"))
  glab.submit("PROJ-1", { approve = true }, keep("submit"))
  restore()
  eq(#calls, 0, "nothing spawned")
  for name, answer in pairs(got) do
    eq(answer[2], "PROJ-1 is not a merge request identifier", name)
  end
end)

test("identifiers: a number with anything after it is not an identifier", function()
  eq(commands.source_of("#12abc"), nil)
  eq(commands.source_of("!482abc"), nil)
  local calls, restore = stub_glab()
  local got = {}
  glab.item("!482abc", function(it, err)
    got.glab = { it, err }
  end)
  gh.item("#12abc", function(it, err)
    got.gh = { it, err }
  end)
  restore()
  eq(#calls, 0)
  eq(got.glab[2], "!482abc is not a merge request identifier such as !482")
  eq(got.gh[2], "#12abc is not a pull request identifier such as #12")
end)

-- the GitHub adapter ------------------------------------------------------------------------

-- The fields `pr list --json` is asked for, spelled out rather than read off
-- gh.ROW_FIELDS: a name dropped from that list while rows() still builds from
-- it is the defect, and an assertion that reads the list cannot see it.
local GH_FIELDS = "number,title,state,isDraft,headRefName,isCrossRepository,url,updatedAt,author,assignees"

local function pull_request(overrides)
  return vim.tbl_extend("force", {
    number = 12,
    title = "Add the teardown",
    state = "OPEN",
    isDraft = false,
    headRefName = "teardown",
    url = "https://github.com/acme/payments/pull/12",
    updatedAt = "2024-05-03T10:00:00Z",
    author = { id = "MDQ6", is_bot = false, login = "ana", name = "Ana" },
    assignees = { { id = "MDQ7", login = "me", name = "Me Myself" } },
  }, overrides or {})
end

test("gh: both row queries add the field list, rows carry the head branch, and whoami is api user --jq .login", function()
  gh.forget()
  local calls, restore = stub_run(function(argv)
    if argv[2] == "api" then
      return done(argv, "me\n")
    end
    return done(argv, { pull_request(), pull_request({ number = 3, title = "WIP", isDraft = true, state = "OPEN", headRefName = "wip" }) })
  end)
  local got = {}
  for _, query in ipairs({ config.defaults.sections[4].query.gh, config.defaults.sections[5].query.gh }) do
    gh.rows({ query = query }, function(rows, err, warning)
      got[#got + 1] = { rows = rows, err = err, warning = warning }
    end)
  end
  local answers = {}
  gh.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  gh.whoami(function(id, err)
    answers[#answers + 1] = { id, err }
  end)
  restore()
  eq(calls[1].argv, { "gh", "pr", "list", "--search", "review-requested:@me", "--limit", "100", "--json", GH_FIELDS })
  eq(calls[2].argv, { "gh", "pr", "list", "--assignee", "@me", "--limit", "100", "--json", GH_FIELDS })
  eq(calls[3].argv, { "gh", "api", "user", "--jq", ".login" })
  eq(#calls, 3, "one identity query for two callers")
  eq(answers, { { "me" }, { "me" } })
  local first, second = got[1].rows[1], got[1].rows[2]
  eq({ first.source, first.id, first.state, first.title, first.branch }, { "gh", "#12", "open", "Add the teardown", "teardown" })
  eq({ second.id, second.state, second.branch }, { "#3", "draft", "wip" })
  eq(first.author, { id = "ana", name = "Ana" })
  eq(first.url, "https://github.com/acme/payments/pull/12")
  eq(gh.branch(first), "teardown")
  eq(gh.url({ id = "#12" }), first.url)
  eq(gh.token_url(), "https://github.com/settings/tokens")

  local waits, restore_wait = stub_wait(function(argv)
    if argv[3] == "status" then
      return failed(argv, 1, "github.com\n  X Failed to log in to github.com account me (keyring)\n")
    end
    return done(argv, "")
  end)
  eq(gh.auth_status().authenticated, false, "gh exits 1 when an account has trouble")
  local result = gh.auth_login("ghp_secret", { hostname = "github.com" })
  eq(result.ok, true)
  eq(waits[2].argv, { "gh", "auth", "login", "--with-token", "--hostname", "github.com" })
  eq(waits[2].opts.stdin, "ghp_secret\n")
  for _, word in ipairs(waits[2].argv) do
    eq(word:find("secret", 1, true), nil, "the token is nowhere in the argument list")
  end
  restore_wait()
  local runs, restore_run = stub_run(function(argv)
    return done(argv, "me\n")
  end)
  gh.whoami(function() end)
  restore_run()
  eq(#runs, 1, "the login dropped the identity")
end)

test("gh: a row carries its assignee, one that cannot be built is a warning, and none at all is the error", function()
  gh.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { pull_request(), pull_request({ number = 4, title = vim.NIL }) })
  end)
  local got
  gh.rows({ query = { "pr", "list" } }, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  restore()
  eq(#got[1], 1)
  eq(got[1][1].assignee, { id = "me", name = "Me Myself" }, "the assignee is the first of `assignees`, not the author")
  eq(got[3], "row: #4 needs a non-empty string for title")

  _, restore = stub_run(function(argv)
    return done(argv, { pull_request({ number = 4, title = vim.NIL }) })
  end)
  gh.rows({ query = { "pr", "list" } }, function(rows, err, warning)
    got = { rows, err, warning }
  end)
  restore()
  eq(got[1], nil, "a section whose every row was refused is the error, not an empty success")
  eq(got[2], "row: #4 needs a non-empty string for title")
  eq(got[3], nil)

  _, restore = stub_run(function(argv)
    return done(argv, { message = "Not Found" })
  end)
  gh.rows({ query = { "pr", "list" } }, function(rows, err)
    got = { rows, err }
  end)
  restore()
  eq(
    got[2],
    "gh: pr list printed something other than a list of pull requests; run\n  gh pr list --limit 100 --json "
      .. GH_FIELDS
      .. "\nby hand to see what it prints"
  )
end)

test("gh: a row is from a fork when isCrossRepository is true, and not when it is false or the list left it out", function()
  gh.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, {
      pull_request({ headRefName = "main", isCrossRepository = true }),
      pull_request({ number = 3, title = "Same repository", headRefName = "same", isCrossRepository = false }),
      pull_request({ number = 4, title = "Unmarked", headRefName = "patch-1" }),
    })
  end)
  local got
  gh.rows({ query = { "pr", "list" } }, function(rows, err, warning)
    got = { rows = rows, err = err, warning = warning }
  end)
  restore()
  eq(got.err, nil)
  eq(got.warning, nil)
  eq(vim.tbl_map(function(r)
    return { r.id, r.fork }
  end, got.rows), { { "#12", true }, { "#3" }, { "#4" } }, "true marks a row; false and absence do not")
end)

test("gh: a section that answers after a login is not shown, and its addresses and host are not remembered", function()
  gh.forget()
  local pending, saved = {}, spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local got
  gh.rows({ query = { "pr", "list" } }, function(rows, err)
    got = { rows, err }
  end)
  gh.forget()
  pending[1].on_done(done(pending[1].argv, { pull_request({ number = 5, url = "https://ghe.example.test/o/r/pull/5" }) }))
  spawn.run = saved
  eq(got, { nil, "gh: a login ran while this section was in flight, so its rows are not shown; refresh to ask again" })
  eq(gh.url({ id = "#5" }), nil)
  eq(gh.token_url(), "https://github.com/settings/tokens")
end)

test("gh: auth status asks about the active account, and about the host in context once one is known", function()
  gh.forget()
  local calls, restore = stub_wait(function(argv)
    return done(argv, "github.com\n  ✓ Logged in to github.com account me (keyring)\n")
  end)
  gh.auth_status()
  gh.auth_status()
  restore()
  eq(calls[1].argv, { "gh", "auth", "status", "--active" }, "with no host known, every host")
  eq(calls[2].argv, { "gh", "auth", "status", "--active", "--hostname", "github.com" }, "then the one the first answer named")
end)

test("gh: forget drops the addresses and the host a list read", function()
  gh.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, { pull_request({ number = 5, url = "https://ghe.example.test/o/r/pull/5" }) })
  end)
  gh.rows({ query = { "pr", "list" } }, function() end)
  restore()
  eq({ gh.url({ id = "#5" }), gh.token_url() }, { "https://ghe.example.test/o/r/pull/5", "https://ghe.example.test/settings/tokens" })
  gh.forget()
  local url, err = gh.url({ id = "#5" })
  eq({ url, err }, { nil, "#5 has not been listed this session, so its address is unknown" })
  eq(gh.token_url(), "https://github.com/settings/tokens", "the host goes with the account")
  eq(gh.auth_fields()[1].default, gh.DEFAULT_HOST)
end)

test("gh: an account with no display name is named by its login", function()
  gh.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, {
      pull_request({
        author = { id = "MDQ8", is_bot = false, login = "ana", name = "" },
        assignees = { { id = "MDQ9", login = "bea", name = "" } },
      }),
    })
  end)
  local got
  gh.rows({ query = { "pr", "list" } }, function(rows)
    got = rows
  end)
  restore()
  eq(got[1].author, { id = "ana", name = "ana" })
  eq(got[1].assignee, { id = "bea", name = "bea" })
end)

test("gh: an empty login and a client that is not installed are each reported", function()
  gh.forget()
  local _, restore = stub_run(function(argv)
    return done(argv, "\n")
  end)
  local got
  gh.whoami(function(id, err)
    got = { id, err }
  end)
  restore()
  eq(got[1], nil, "an empty login is not remembered as the identity")
  eq(got[2], "gh: `api user --jq .login` printed nothing; run `gh api user --jq .login` by hand to see what it prints")

  gh.forget()
  local _, restore_wait = stub_wait(function(argv)
    return failed(argv, spawn.MISSING, "ENOENT: no such file or directory")
  end)
  local status = gh.auth_status()
  restore_wait()
  eq({ status.authenticated, status.missing }, { false, true }, "an absent gh is missing, not signed out")
  eq(status.detail, "gh: not found\nENOENT: no such file or directory")
end)

test("gh: an item is handed to octo.nvim, and no item buffer is made for a pull request", function()
  local edited = {}
  vim.api.nvim_create_user_command("Octo", function(command)
    edited[#edited + 1] = command.args
  end, { nargs = "*" })
  local got
  gh.item("#12", function(it, err)
    got = { it, err, settled = true }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(edited, { "pr edit 12" })
  eq(got, { settled = true }, "no item and no error come back")

  -- A reference carrying the row's address hands the command that address,
  -- host and all, whatever the host; one whose address names no pull request
  -- hands the number as the identifier alone does.
  for _, url in ipairs({
    "https://github.com/acme/payments/pull/12",
    "https://ghe.example.test/acme/payments/pull/12",
  }) do
    got = nil
    gh.item({ id = "#12", url = url }, function(it, err)
      got = { it, err, settled = true }
    end)
    vim.wait(1000, function()
      return got ~= nil
    end)
    eq(got, { settled = true }, url)
    eq(edited[#edited], url, "the address is what the command is handed")
  end
  eq(#edited, 3, "one command per reference")
  got = nil
  gh.item({ id = "#12", url = "https://github.com/acme/payments/issues/12" }, function(it, err)
    got = { it, err, settled = true }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got, { settled = true })
  eq(edited[#edited], "pr edit 12", "an address of another shape names no pull request, so the number goes alone")
  eq(#edited, 4)
  gh.item({ id = "PROJ-1", url = "https://github.com/acme/payments/pull/12" }, function(it, err)
    got = { it, err }
  end)
  eq(got, { nil, "PROJ-1 is not a pull request identifier such as #12" }, "the identifier is judged, whatever the address")

  -- Through the command, with the state check first: a `docket://gh/` buffer
  -- is never made.
  local _, restore_wait = stub_acli({ gh = true })
  local notices, restore_notify = stub_notify()
  local buffers = #vim.api.nvim_list_bufs()
  eq(commands.item("#12"), nil)
  vim.wait(1000, function()
    return #edited == 5
  end)
  restore_notify()
  restore_wait()
  eq(edited[5], "pr edit 12", ":Docket #12 carries no address, so the number goes alone")
  eq(buffer.named("docket://gh/#12"), nil)
  eq(#vim.api.nvim_list_bufs(), buffers, "no buffer was made")
  eq(notices, {})
  vim.api.nvim_del_user_command("Octo")

  got = nil
  gh.item("#12", function(it, err)
    got = { it, err }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got[1], nil)
  eq(got[2]:find("octo.nvim is not installed", 1, true), 1, got[2])
  -- A list teaches the adapter #12's address on github.com, and the reference
  -- carries another, on another host: the row's own is what is printed, not
  -- the one url() has cached for the number.
  local _, restore_list = stub_run(function(argv)
    return done(argv, { pull_request() })
  end)
  local listed
  gh.rows({ query = { "pr", "list" } }, function(rows)
    listed = rows
  end)
  restore_list()
  eq(listed[1].url, "https://github.com/acme/payments/pull/12", "the cached address")
  got = nil
  gh.item({ id = "#12", url = "https://ghe.example.test/acme/tools/pull/12" }, function(it, err)
    got = { it, err }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got, {
    nil,
    "octo.nvim is not installed, and a pull request opens there; #12 is at https://ghe.example.test/acme/tools/pull/12",
  }, "the address a row carries is the one printed")
  gh.item("PROJ-1", function(it, err)
    got = { it, err }
  end)
  eq(got[2], "PROJ-1 is not a pull request identifier such as #12")
end)

test("gh: a handoff that raises is reported, with the editor's own internals off the message", function()
  vim.api.nvim_create_user_command("Octo", function()
    error("E5108: Octo: no repository here", 0)
  end, { nargs = "*" })
  local got
  gh.item("#12", function(it, err)
    got = { it, err }
  end)
  vim.wait(1000, function()
    return got ~= nil
  end)
  eq(got[1], nil)
  eq(got[2]:find("E5108: Octo: no repository here", 1, true) ~= nil, true, got[2])
  eq(got[2]:find("stack traceback", 1, true), nil, "the traceback is not the report")
  eq(got[2]:find("nvim_exec2", 1, true), nil, "nor is the call that ran the command")

  -- Through the command: a handoff nobody can complete is one ERROR notice,
  -- since there is no item buffer to carry the reason instead.
  local _, restore_wait = stub_acli({ gh = true })
  local notices, restore_notify = stub_notify()
  eq(commands.item("#12"), nil)
  vim.wait(1000, function()
    return #notices > 0
  end)
  restore_notify()
  restore_wait()
  eq(#notices, 1)
  eq(notices[1].level, vim.log.levels.ERROR)
  eq(notices[1].message:find("E5108: Octo: no repository here", 1, true) ~= nil, true, notices[1].message)
  vim.api.nvim_del_user_command("Octo")
end)


test("plugin: :e on a pull request's name hands it to octo.nvim with no error, and the buffer :e made is wiped once octo's takes the window", function()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  -- `enew` stands in for the buffer octo.nvim's `pr edit` shows the pull
  -- request in, in the current window, which is what wipes the buffer :e
  -- made; the suite loads no octo.nvim.
  local edited = {}
  vim.api.nvim_create_user_command("Octo", function(command)
    edited[#edited + 1] = command.args
    vim.cmd("enew")
  end, { nargs = "*" })
  local _, restore_wait = stub_acli({ gh = true })
  local notices, restore_notify = stub_notify()
  -- `#` is the alternate file on the command line, so a typed name escapes it.
  vim.cmd("edit docket://gh/\\#12")
  local handed = vim.wait(1000, function()
    return #edited == 1 and buffer.named("docket://gh/#12") == nil
  end)
  vim.api.nvim_del_user_command("Octo")
  vim.cmd("edit docket://gh/\\#13")
  local left = buffer.named("docket://gh/#13")
  vim.wait(1000, function()
    return #notices > 0
  end)
  local kept = left and {
    valid = vim.api.nvim_buf_is_valid(left),
    bufhidden = vim.bo[left].bufhidden,
    filetype = vim.bo[left].filetype,
    listed = vim.bo[left].buflisted,
    modifiable = vim.bo[left].modifiable,
    -- Text typed into a `wipe` buffer would make every switch away from it
    -- E37, with nothing here for `:w` to clear it with.
    typed = left and pcall(vim.api.nvim_buf_set_lines, left, 0, -1, false, { "typed" }),
  }
  vim.cmd("enew")
  local wiped = left and not vim.api.nvim_buf_is_valid(left)
  restore_notify()
  restore_wait()
  eq(handed, true, "octo was asked, and the buffer :e made is gone")
  eq(edited, { "pr edit 12" })
  eq(#notices, 1, vim.inspect(notices))
  eq(notices[1].level, vim.log.levels.ERROR)
  eq(notices[1].message:find("octo.nvim is not installed", 1, true), 1, notices[1].message)
  eq(
    kept,
    { valid = true, bufhidden = "wipe", filetype = "", listed = false, modifiable = false, typed = false },
    "a handoff that failed leaves the bare buffer, set up as no item buffer and taking no text"
  )
  eq(wiped, true, "and leaving it wipes it")
end)

-- the teardown ------------------------------------------------------------------------------

-- What `git worktree list --porcelain` answers for a clone holding one
-- worktree on each of the branches the teardown tests remove.
local WORKTREES = table.concat({
  "worktree /w/repo/bare",
  "bare",
  "",
  "worktree /w/repo/PROJ-1-x",
  "branch refs/heads/PROJ-1-x",
  "",
  "worktree /w/repo/feature-acli.bump",
  "branch refs/heads/feature/acli.bump",
  "",
}, "\n")

-- What `list-windows` prints for the window names given, the first as `@1`
-- and each after it one higher.
local function listing(names)
  local lines = {}
  for index, name in ipairs(names) do
    lines[#lines + 1] = ("@%d %s\n"):format(index, name)
  end
  return table.concat(lines)
end

-- The launcher's counterpart, inside tmux: every process call recorded, with
-- tmux answering from `windows` -- the session's window names, the current one
-- first, listed with ids from `@1` -- the worktree listing from WORKTREES, a
-- clean tree from `git status`, and `git wt-rm` from `removal`.
local function stub_teardown(windows, removal)
  return stub_wait(function(argv, opts)
    if argv[1] == "tmux" and argv[2] == "display-message" then
      return done(argv, windows[1] .. "\n")
    end
    if argv[1] == "tmux" and argv[2] == "list-windows" then
      return done(argv, listing(windows))
    end
    if argv[1] == "tmux" then
      return done(argv, "")
    end
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, "")
    end
    return removal(argv, opts)
  end)
end

test("teardown: inside tmux the windows present are closed, in order, and then the worktree is removed", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_teardown({ "dash", "PROJ-1-x", "PROJ-1-x-sh", "other" }, function(argv)
    return done(argv, "removed PROJ-1-x/\ndeleted branch 'PROJ-1-x'\n")
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(err, nil)
  eq(removed, { branch = "PROJ-1-x", window = "PROJ-1-x", closed = { "PROJ-1-x", "PROJ-1-x-sh" } })
  eq(vim.tbl_map(function(call)
    return call.argv
  end, calls), {
    { "git", "worktree", "list", "--porcelain" },
    { "git", "status", "--porcelain" },
    { "tmux", "display-message", "-p", "#{window_name}" },
    { "tmux", "list-windows", "-F", "#{window_id} #{window_name}" },
    { "tmux", "kill-window", "-t", "@2" },
    { "tmux", "kill-window", "-t", "@3" },
    { "git", "wt-rm", "PROJ-1-x" },
  }, "what git wt-rm needs comes first, then both windows, then the worktree")
  eq(calls[1].opts.cwd, "/w/repo", "the listing runs at the clone's root")
  eq(calls[2].opts.cwd, "/w/repo/PROJ-1-x", "the clean-tree check runs in the worktree")
  eq(calls[7].opts.cwd, "/w/repo", "git runs at the clone's root")
  eq(calls[5].opts.timeout, config.options.timeouts.tmux)
  eq(calls[7].opts.timeout, config.options.timeouts.git)
end)

test("teardown: a worktree holding uncommitted work is refused with no window closed, and force skips the check", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, " M lua/docket/env.lua\n?? notes.md\n")
    end
    error("nothing runs once the worktree is dirty: " .. table.concat(argv, " "))
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  eq(removed, nil)
  eq(
    err,
    "/w/repo/PROJ-1-x holds modified or untracked files, which `git wt-rm` refuses; commit them, or pass force = true to discard them along with the folder"
  )
  eq(#calls, 2, "no window was closed for a refusal that was coming")

  calls, restore = stub_teardown({ "dash", "PROJ-1-x" }, function(argv)
    return done(argv, "removed PROJ-1-x/\n")
  end)
  removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x", force = true })
  restore()
  vim.env.TMUX = saved_tmux
  eq(err, nil)
  eq(removed.closed, { "PROJ-1-x" })
  eq(has(vim.tbl_map(function(call)
    return call.argv[2]
  end, calls), "status"), false, "force discards the work, so the check is not made")
end)

test("teardown: a branch with no worktree here is refused before anything is closed", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    error("nothing runs for a branch with no worktree: " .. table.concat(argv, " "))
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-9-y" })
  restore()
  eq(removed, nil)
  eq(err, "PROJ-9-y has no worktree in /w/repo, so there is nothing to remove")
  eq(#calls, 1)

  calls, restore = stub_wait(function(argv)
    return failed(argv, 128, "fatal: not a git repository")
  end)
  removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(removed, nil)
  eq(err, "git exited 128\nfatal: not a git repository")
  eq(#calls, 1, "a listing that failed stops the teardown")
end)

test("teardown: a window already gone is not closed again, a review branch's name is flattened, and force reaches git", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_teardown({ "dash", "feature-acli-bump-sh" }, function(argv)
    return done(argv, "removed feature-acli.bump/\n")
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "feature/acli.bump", force = true })
  restore()
  vim.env.TMUX = saved_tmux
  eq(err, nil)
  eq(removed.closed, { "feature-acli-bump-sh" }, "only the window that was there")
  eq(removed.window, "feature-acli-bump")
  eq(calls[4].argv, { "tmux", "kill-window", "-t", "@2" })
  eq(calls[5].argv, { "git", "wt-rm", "feature/acli.bump", "--force" }, "git takes the ref, not the window name")
  eq(#calls, 5, "force skips the clean-tree check")
end)

test("teardown: a name two windows carry stops the removal with their ids before any window is closed", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_teardown({ "dash", "PROJ-1-x", "PROJ-1-x-sh", "PROJ-1-x-sh" }, function(argv)
    error("git wt-rm must not run: " .. table.concat(argv, " "))
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(removed, nil)
  eq(
    err,
    "tmux lists more than one window named PROJ-1-x-sh: @3, @4; tmux list-windows -F '#{window_id} #{window_name}' prints what the session holds"
  )
  eq(#calls, 4, "the listing is the last call: the editor's window is not closed either")
end)

test("teardown: a window that cannot be closed stops the removal, and so does running it from either window", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, "")
    end
    if argv[2] == "display-message" then
      return done(argv, "dash\n")
    end
    if argv[2] == "list-windows" then
      return done(argv, listing({ "dash", "PROJ-1-x", "PROJ-1-x-sh" }))
    end
    if argv[2] == "kill-window" then
      return failed(argv, 1, "server exited unexpectedly")
    end
    error("git wt-rm must not run once a window failed to close: " .. table.concat(argv, " "))
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  eq(removed, nil)
  eq(err, "tmux exited 1\nserver exited unexpectedly")
  eq(#calls, 5, "the first kill failed and nothing followed")

  for _, here in ipairs({ "PROJ-1-x", "PROJ-1-x-sh" }) do
    calls, restore = stub_wait(function(argv)
      if argv[2] == "worktree" then
        return done(argv, WORKTREES)
      end
      if argv[2] == "status" then
        return done(argv, "")
      end
      if argv[2] == "display-message" then
        return done(argv, here .. "\n")
      end
      error("nothing runs after the refusal: " .. table.concat(argv, " "))
    end)
    removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
    restore()
    eq(removed, nil)
    eq(
      err,
      ("this editor runs in tmux window %s, which the teardown closes; run it from another window"):format(here),
      "the companion window refuses the teardown too"
    )
    eq(#calls, 3)
  end

  -- A tmux that cannot answer either question is an error: with no server the
  -- current window would read as empty and the listing as no windows at all,
  -- and the teardown would remove the worktree while both may still sit in it.
  for _, step in ipairs({ "display-message", "list-windows" }) do
    calls, restore = stub_wait(function(argv)
      if argv[2] == "worktree" then
        return done(argv, WORKTREES)
      end
      if argv[2] == "status" then
        return done(argv, "")
      end
      if argv[2] == "display-message" and step == "list-windows" then
        return done(argv, "dash\n")
      end
      if argv[2] == step then
        return failed(argv, 1, "no server running on /tmp/tmux-1/default")
      end
      error("nothing runs once tmux could not answer: " .. table.concat(argv, " "))
    end)
    removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
    restore()
    eq(removed, nil)
    eq(err, "tmux exited 1\nno server running on /tmp/tmux-1/default", step)
  end
  vim.env.TMUX = saved_tmux
end)

-- What git-wt-rm prints when `git worktree remove` refuses: its own prefix,
-- then the failed git argument list, then git's sentence. The refusal reaches
-- here only through a race, since teardown checks the tree first.
local WT_RM_REFUSAL = "git-wt-rm: worktree remove /w/repo/PROJ-1-x: fatal: '/w/repo/PROJ-1-x' contains modified or untracked files, use --force to delete it\n"

-- What it prints when the folder went and `git branch -d` refused the branch:
-- the same prefix and argument list, git's own sentence with its advice, and
-- then the two lines git-wt-rm adds.
local WT_RM_BRANCH_KEPT = table.concat({
  "git-wt-rm: branch -d PROJ-1-x: error: the branch 'PROJ-1-x' is not fully merged",
  "hint: If you are sure you want to delete it, run 'git branch -D PROJ-1-x'",
  "hint: Disable this message with \"git config set advice.forceDeleteBranch false\"",
  "the worktree is gone; once losing the branch is intended:",
  "    git branch -D PROJ-1-x",
  "",
}, "\n")

test("teardown: git wt-rm's refusal is the error verbatim, a branch it kept is a warning, and away from tmux nothing but git runs", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = nil
  local calls, restore = stub_wait(function(argv)
    if argv[1] ~= "git" then
      error("no tmux away from tmux: " .. table.concat(argv, " "))
    end
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, "")
    end
    return failed(argv, 1, WT_RM_REFUSAL)
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  eq(removed, nil)
  eq(err, vim.trim(WT_RM_REFUSAL), "no window was closed, so the error is git-wt-rm's own")
  eq(#calls, 3)
  eq(calls[3].argv, { "git", "wt-rm", "PROJ-1-x" })

  calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, "")
    end
    return {
      argv = argv,
      ok = false,
      code = 1,
      stdout = "removed PROJ-1-x/\n",
      stderr = WT_RM_BRANCH_KEPT,
      timed_out = false,
    }
  end)
  removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(err, nil)
  eq(removed.closed, {}, "no windows away from tmux")
  eq(removed.warning, vim.trim(WT_RM_BRANCH_KEPT))
  eq(#calls, 3)
end)

test("teardown: a refusal after both windows were closed says they are gone and the worktree is not", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local calls, restore = stub_teardown({ "dash", "PROJ-1-x", "PROJ-1-x-sh" }, function(argv)
    return failed(argv, 1, "git: 'wt-rm' is not a git command. See 'git --help'.\n")
  end)
  local removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  eq(removed, nil)
  eq(
    err,
    "git: 'wt-rm' is not a git command. See 'git --help'.\nthe tmux windows PROJ-1-x and PROJ-1-x-sh are closed; the worktree is still there"
  )
  eq(#calls, 7)

  calls, restore = stub_teardown({ "dash", "PROJ-1-x-sh" }, function(argv)
    return failed(argv, 1, WT_RM_REFUSAL)
  end)
  removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(removed, nil)
  eq(
    err,
    vim.trim(WT_RM_REFUSAL) .. "\nthe tmux window PROJ-1-x-sh is closed; the worktree is still there",
    "one window closed reads as one"
  )
  eq(#calls, 6)
end)

-- the launcher and the binding -------------------------------------------------------------

test("launcher: a ticket and a review each reuse the worktree already on their branch, and git is not asked to make one", function()
  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  local porcelain = table.concat({
    "worktree /w/repo/.bare",
    "bare",
    "",
    "worktree /w/repo/PROJ-1-old-summary",
    "branch refs/heads/PROJ-1-old-summary",
    "",
    "worktree /w/repo/feature-x",
    "branch refs/heads/feature/x",
    "",
  }, "\n")
  local calls, restore = stub_wait(function(argv)
    if argv[1] == "git" and argv[2] == "worktree" then
      return done(argv, porcelain)
    end
    if argv[1] == "tmux" and argv[2] == "list-windows" then
      return done(argv, listing({ "dash", "PROJ-1-old-summary", "PROJ-1-old-summary-sh", "feature-x", "feature-x-sh" }))
    end
    if argv[1] == "tmux" then
      return done(argv, "")
    end
    return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
  end)
  local binding = { kind = "projects", projects = { "PROJ" } }
  -- The summary was edited after the worktree was made, so the branch it
  -- would generate now is another one.
  local ticket_opened, ticket_err = env.launch({ root = "/w/repo", binding = binding, key = "PROJ-1", summary = "an edited summary" })
  local review_opened, review_err = env.launch({ root = "/w/repo", binding = binding, branch = "feature/x", review = "!4" })
  restore()
  vim.env.TMUX = saved_tmux
  eq({ ticket_err, review_err }, {})
  eq({ ticket_opened.path, ticket_opened.branch, ticket_opened.window }, { "/w/repo/PROJ-1-old-summary", "PROJ-1-old-summary", "PROJ-1-old-summary" })
  eq({ review_opened.path, review_opened.branch, review_opened.window }, { "/w/repo/feature-x", "feature/x", "feature-x" })
  for _, call in ipairs(calls) do
    eq(call.argv[1] == "git" and call.argv[2] ~= "worktree", false, "only the listing runs git: " .. table.concat(call.argv, " "))
  end
  local windows = vim.tbl_filter(function(call)
    return call.argv[2] == "new-window" and call.argv[4] == "-n"
  end, calls)
  eq(windows[1].argv, { "tmux", "new-window", "-S", "-n", "PROJ-1-old-summary", "-c", "/w/repo/PROJ-1-old-summary", "nvim" })
  eq(windows[2].argv, { "tmux", "new-window", "-S", "-n", "feature-x", "-c", "/w/repo/feature-x", "nvim", "-c", "Docket review !4" })
end)

test("launcher: a repository bound to its projects refuses another project's key with the command that binds it", function()
  local calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, "worktree /w/repo/.bare\nbare\n\n")
    end
    error("nothing runs for a key from another project: " .. table.concat(argv, " "))
  end)
  local opened, err = env.launch({ root = "/w/repo", binding = { kind = "projects", projects = { "PAY", "OPS" } }, key = "TIG-5", summary = "x" })
  restore()
  eq(opened, nil)
  eq(
    err,
    "/w/repo is bound to PAY, OPS, not TIG, so no worktree is made for TIG-5 here. If TIG's tickets belong in this repository:\n  git config --add dotfiles.jira.project TIG"
  )
  eq(#calls, 1, "the listing alone")
  -- A binding by a complete query names no project list, so its keys are not checked.
  calls, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, "worktree /w/repo/.bare\nbare\n\n")
    end
    return failed(argv, 1, "stopped here: " .. table.concat(argv, " "))
  end)
  opened, err = env.launch({ root = "/w/repo", binding = { kind = "jql", jql = "filter = 1" }, key = "TIG-5", summary = "x" })
  restore()
  eq(err, "stopped here: git wt-add TIG-5-x", "a jql binding reaches git wt-add")
end)

test("launcher: git killed at the timeout is reported as killed, ahead of the progress it printed", function()
  local killed = {
    ok = false,
    code = spawn.TIMED_OUT,
    stdout = "",
    stderr = "Preparing worktree (new branch 'PROJ-1-x')\n",
    timed_out = true,
    timeout = 60000,
  }
  local _, restore = stub_wait(function(argv)
    return vim.tbl_extend("force", killed, { argv = argv })
  end)
  local path, err = env.add_worktree("/w/repo", "PROJ-1-x")
  restore()
  eq(path, nil)
  eq(err, "git: killed after 60000 ms without exiting\nPreparing worktree (new branch 'PROJ-1-x')\n")

  local saved_tmux = vim.env.TMUX
  vim.env.TMUX = nil
  _, restore = stub_wait(function(argv)
    if argv[2] == "worktree" then
      return done(argv, WORKTREES)
    end
    if argv[2] == "status" then
      return done(argv, "")
    end
    return vim.tbl_extend("force", killed, { argv = argv, stderr = "" })
  end)
  local removed
  removed, err = env.teardown({ root = "/w/repo", branch = "PROJ-1-x" })
  restore()
  vim.env.TMUX = saved_tmux
  eq(removed, nil)
  eq(err, "git: killed after 60000 ms without exiting", "a git wt-rm that printed nothing is still said to be killed")
end)

test("binding: jql with the epic beside it, then the projects and the epic, then ignore, and a config git cannot read is the error", function()
  -- Each key answers from `set`; one absent is `git config`'s exit 1 with
  -- nothing on stderr, which is how it reports a key that is not set.
  local function stub_config(set)
    return stub_wait(function(argv)
      local value = set[argv[#argv]]
      if value == nil then
        return failed(argv, 1, "")
      end
      return done(argv, value .. "\n")
    end)
  end
  local JQL = { "git", "config", "--get", "dotfiles.jira.jql" }
  local PROJECT = { "git", "config", "--get-all", "dotfiles.jira.project" }
  local EPIC = { "git", "config", "--get", "dotfiles.jira.epic" }
  local IGNORE = { "git", "config", "--type=bool", "dotfiles.jira.ignore" }
  local malformed =
    "dotfiles.jira.epic is pay-10, which is not a work item key such as PROJ-142; git config --unset dotfiles.jira.epic clears it"
  -- What each configuration answers, and the keys git is asked for, in order.
  local cases = {
    { { ["dotfiles.jira.jql"] = "filter = 1", ["dotfiles.jira.project"] = "PAY" }, { { kind = "jql", jql = "filter = 1" } }, { JQL, EPIC } },
    {
      { ["dotfiles.jira.jql"] = "filter = 1", ["dotfiles.jira.epic"] = "PAY-10", ["dotfiles.jira.project"] = "OPS" },
      { { kind = "jql", jql = "filter = 1", epic = "PAY-10" } },
      { JQL, EPIC },
    },
    {
      { ["dotfiles.jira.project"] = "PAY\nOPS", ["dotfiles.jira.ignore"] = "true" },
      { { kind = "projects", projects = { "PAY", "OPS" } } },
      { JQL, PROJECT, EPIC },
    },
    {
      { ["dotfiles.jira.project"] = "PAY\nOPS", ["dotfiles.jira.epic"] = "PAY-10" },
      { { kind = "projects", projects = { "PAY", "OPS" }, epic = "PAY-10" } },
      { JQL, PROJECT, EPIC },
    },
    { { ["dotfiles.jira.epic"] = "PAY-10" }, { { kind = "projects", projects = { "PAY" }, epic = "PAY-10" } }, { JQL, PROJECT, EPIC } },
    {
      { ["dotfiles.jira.epic"] = "AB1-7", ["dotfiles.jira.ignore"] = "true" },
      { { kind = "projects", projects = { "AB1" }, epic = "AB1-7" } },
      { JQL, PROJECT, EPIC },
    },
    { { ["dotfiles.jira.epic"] = "pay-10" }, { nil, malformed }, { JQL, PROJECT, EPIC } },
    { { ["dotfiles.jira.jql"] = "filter = 1", ["dotfiles.jira.epic"] = "pay-10" }, { nil, malformed }, { JQL, EPIC } },
    -- `git config dotfiles.jira.epic ""` leaves a key that answers an empty
    -- line with exit 0, and binds no epic.
    { { ["dotfiles.jira.epic"] = "" }, { { kind = "unbound" } }, { JQL, PROJECT, EPIC, IGNORE } },
    {
      { ["dotfiles.jira.project"] = "PAY", ["dotfiles.jira.epic"] = "" },
      { { kind = "projects", projects = { "PAY" } } },
      { JQL, PROJECT, EPIC },
    },
    { { ["dotfiles.jira.ignore"] = "true" }, { { kind = "ignored" } }, { JQL, PROJECT, EPIC, IGNORE } },
    { { ["dotfiles.jira.ignore"] = "false" }, { { kind = "unbound" } }, { JQL, PROJECT, EPIC, IGNORE } },
    { {}, { { kind = "unbound" } }, { JQL, PROJECT, EPIC, IGNORE } },
  }
  for _, case in ipairs(cases) do
    local calls, restore = stub_config(case[1])
    local binding, err = repo.binding("/w/repo")
    restore()
    eq({ binding, err }, case[2], vim.inspect(case[1]))
    eq(calls[1].opts.cwd, "/w/repo", "git config runs at the clone's root")
    eq(vim.tbl_map(function(call)
      return call.argv
    end, calls), case[3], "the keys read for " .. vim.inspect(case[1]))
  end
  -- Exit 1 with something on stderr is git failing to read the file, not a
  -- key that is not set.
  _, restore = stub_wait(function(argv)
    return failed(argv, 1, "error: bad config line 3 in file .bare/config")
  end)
  local binding, err = repo.binding("/w/repo")
  restore()
  eq(binding, nil)
  eq(err, "git exited 1\nerror: bad config line 3 in file .bare/config")
  eq(repo.LIST_COMMAND, "acli jira project list --paginate", "the listing stops at a page without --paginate")
end)

test("binding: a clone bound to an epic names it on the dash's first line and asks Jira for its children; under a complete jql the line names none", function()
  jira.forget()
  local _, restore_cache = scratch_cache()
  local restore_clone = stub_clone({ kind = "projects", projects = { "PAY" }, epic = "PAY-10" }, "https://bitbucket.example.test/acme/payments.git")
  local runs, restore_run = stub_run(checked({ signed_in = true }, function(argv)
    return done(argv, {})
  end))
  local notices, restore_notify = stub_notify()
  local buf = list.open({ root = "/w/repo", bare = true })
  local settled_ok = settled(buf)
  local first = lines_of(buf)[1]
  restore_notify()
  restore_run()
  restore_clone()
  restore_cache()
  eq(settled_ok, true, "every section answered")
  eq(first, "Docket · /w/repo · PAY-10")
  local searched = {}
  for _, run in ipairs(runs) do
    if jql_of(run.argv) then
      searched[#searched + 1] = jql_of(run.argv)
    end
  end
  eq(#searched > 0, true, "the Jira sections were searched")
  for _, jql in ipairs(searched) do
    eq(jql:find("^project IN %(PAY%) AND parent = PAY%-10 ") ~= nil, true, jql)
  end
  eq(notices, {})
  local lines = list.lines({ root = "/w/repo", binding = { kind = "jql", jql = "filter = 1", epic = "PAY-10" }, sections = {} }, 0)
  eq(lines[1], "Docket · /w/repo", "a complete query is not narrowed, so the epic is not named")
end)

-- A merge request's item buffer as a read leaves it: named after its
-- project, read in the worktree `/w/mr/feature-x` of the clone `/w/mr`,
-- which its reference names, and keyed by commands.attach() before the item
-- is stored, which is the order a read takes: read() calls prepare(), whose
-- filetype fires the FileType autocommand that attaches the keys, and
-- populate() stores the item after that. `fields` are the item's own, over a
-- merge request on `feature/x` from no fork.
local MR_URL = "https://gitlab.example.test/acme/payments/-/merge_requests/482"
local function merge_request_buffer(fields)
  local name = buffer.name("glab", "!482", "acme/payments")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  commands.attach(buf)
  buffer.populate(
    buf,
    item.new(vim.tbl_extend("force", {
      source = "glab",
      id = "!482",
      title = "Bump the pin",
      state = "opened",
      url = MR_URL,
      body = "The pin moves.",
      me = "me",
      ref = { id = "!482", cwd = "/w/mr/feature-x" },
      project = "acme/payments",
      branch = "feature/x",
    }, fields or {})),
    { now = NOW }
  )
  return buf
end

-- A buffer's normal-mode map of `lhs`, as maparg() reports it: `buffer` is
-- 1 for a map of that buffer's own, and `callback` the function it runs.
local function buffer_map(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

-- Runs `press` with the launcher's processes recorded inside tmux: the clone
-- at `/w/mr`, whose origin is acme/payments, bound to PAY, with a worktree
-- already on `feature/x`, and tmux answering every step. The progress line
-- the launcher draws first is silenced. Answers the calls and the notices.
local function launch_from_buffer(press)
  local saved = { tmux = vim.env.TMUX, echo = vim.api.nvim_echo, redraw = vim.cmd.redraw }
  vim.env.TMUX = "/tmp/tmux-1/default,1,0"
  vim.api.nvim_echo = function() end
  vim.cmd.redraw = function() end
  local porcelain = "worktree /w/mr/.bare\nbare\n\nworktree /w/mr/feature-x\nbranch refs/heads/feature/x\n\n"
  local calls, restore = stub_wait(function(argv)
    if argv[1] == "git" and argv[2] == "rev-parse" then
      return done(argv, "/w/mr/.bare\n")
    end
    if argv[1] == "git" and argv[2] == "remote" then
      return done(argv, "git@gitlab.example.test:acme/payments.git\n")
    end
    if argv[1] == "git" and argv[2] == "config" then
      return argv[#argv] == "dotfiles.jira.project" and done(argv, "PAY\n") or failed(argv, 1, "")
    end
    if argv[1] == "git" and argv[2] == "worktree" then
      return done(argv, porcelain)
    end
    if argv[1] == "tmux" and argv[2] == "list-windows" then
      return done(argv, listing({ "dash", "feature-x", "feature-x-sh" }))
    end
    if argv[1] == "tmux" then
      return done(argv, "")
    end
    return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
  end)
  local notices, restore_notify = stub_notify()
  local ok, err = pcall(press)
  restore_notify()
  restore()
  vim.env.TMUX, vim.api.nvim_echo, vim.cmd.redraw = saved.tmux, saved.echo, saved.redraw
  assert(ok, err)
  return calls, notices
end

-- The argument list of each tmux window the launcher made.
local function windows_made(calls)
  return vim.tbl_map(
    function(call)
      return call.argv
    end,
    vim.tbl_filter(function(call)
      return call.argv[2] == "new-window" and call.argv[4] == "-n"
    end, calls)
  )
end

test("commands: <leader>dR in a merge request's buffer builds its environment in the reference's clone and opens the review there; <leader>dw builds it with no review", function()
  local buf = merge_request_buffer()
  eq(vim.b[buf].docket.branch, "feature/x", "the read stored the branch")
  local review_map, work_map = buffer_map(buf, "<leader>dR"), buffer_map(buf, "<leader>dw")
  eq(review_map.desc, "Docket: review the merge request")
  local calls, notices = launch_from_buffer(function()
    review_map.callback()
  end)
  eq(calls[1].argv, { "git", "rev-parse", "--git-common-dir" })
  eq(calls[1].opts.cwd, "/w/mr/feature-x", "the clone is the one the reference names, not the editor's")
  local listed = vim.tbl_filter(function(call)
    return call.argv[2] == "worktree"
  end, calls)
  eq(#listed, 1)
  eq(listed[1].opts.cwd, "/w/mr", "git worktree list runs in the reference's clone")
  eq(windows_made(calls)[1], { "tmux", "new-window", "-S", "-n", "feature-x", "-c", "/w/mr/feature-x", "nvim", "-c", "Docket review !482" })
  eq(notices[#notices].message:find("^worktree /w/mr/feature%-x on feature/x\n") ~= nil, true, notices[#notices].message)

  calls = launch_from_buffer(function()
    work_map.callback()
  end)
  eq(windows_made(calls)[1], { "tmux", "new-window", "-S", "-n", "feature-x", "-c", "/w/mr/feature-x", "nvim" }, "w opens no review")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("commands: a merge request's buffer from a fork is refused with the dash's line, and a ticket's buffer carries no <leader>dR and refuses a review", function()
  local buf = merge_request_buffer({ branch = "main", fork = true })
  eq(vim.b[buf].docket.fork, true, "the read stored the fork mark")
  for _, lhs in ipairs({ "<leader>dR", "<leader>dw" }) do
    local calls, notices = launch_from_buffer(function()
      buffer_map(buf, lhs).callback()
    end)
    eq(notices, {
      {
        message = "!482 comes from a fork, so origin's main is not its branch and no worktree is made for it",
        level = vim.log.levels.ERROR,
      },
    }, lhs)
    eq(vim.tbl_filter(function(call)
      return call.argv[2] == "worktree" or call.argv[1] == "tmux"
    end, calls), {}, lhs .. ": the launcher is not reached")
  end
  vim.api.nvim_buf_delete(buf, { force = true })

  local ticket_buf = loaded_buffer()
  commands.attach(ticket_buf)
  eq(buffer_map(ticket_buf, "<leader>dR").buffer, nil, "a ticket's buffer has no key that always refuses")
  local notices, restore_notify = stub_notify()
  commands.review_item(ticket_buf)
  restore_notify()
  eq(notices, { { message = "PROJ-142 is a ticket; a review is of a merge request", level = vim.log.levels.ERROR } })
end)

test("commands: the FileType autocommand sets <leader>dR from a merge request's buffer name, with nothing stored yet, as a first read and a session restore run it", function()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  local name = buffer.name("glab", "!482", "acme/payments")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  -- read() runs prepare() before anything is stored, and a session restore
  -- sets the filetype with nothing stored; either way FileType attaches.
  buffer.prepare(buf)
  local stored, map = vim.b[buf].docket, buffer_map(buf, "<leader>dR")
  local notices, restore_notify = stub_notify()
  local ok, err = pcall(function()
    map.callback()
  end)
  restore_notify()
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  eq(stored, nil, "nothing is stored before the read answers")
  eq(map.buffer, 1, "the key is the buffer's own, from its name")
  eq(notices, { { message = "nothing loaded in this buffer; :e reads the item", level = vim.log.levels.ERROR } })
end)

-- What `g?` in a buffer reports, once, at INFO.
local function keys_reported(buf)
  local map = buffer_map(buf, "g?")
  eq({ map.buffer, map.desc }, { 1, commands.HELP.desc }, "g? is the buffer's own")
  local notices, restore = stub_notify()
  local ok, err = pcall(map.callback)
  restore()
  assert(ok, err)
  eq(#notices, 1)
  eq(notices[1].level, vim.log.levels.INFO)
  return notices[1].message
end

-- Checks that `g?` in a buffer reports the description of every one of the
-- buffer's normal-mode maps that is docket's, `g?` itself included and
-- last, before `after` when one is given, and answers the report. The
-- left-hand sides are not compared: nvim_buf_get_keymap reports them with the
-- leader expanded.
local function lists_every_map(buf, label, after)
  local text = keys_reported(buf)
  local descs = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc and vim.startswith(map.desc, "Docket:") then
      descs[#descs + 1] = map.desc
    end
  end
  eq(#descs > 1, true, label .. " carries docket's maps")
  for _, desc in ipairs(descs) do
    eq(text:find(desc, 1, true) ~= nil, true, ("%s: %s is not listed in\n%s"):format(label, desc, text))
  end
  local lines = vim.split(text, "\n", { plain = true })
  if after then
    eq(table.remove(lines), after, label .. ": the line after the list")
  end
  eq(lines[#lines]:match("^g%?%s+(.*)$"), commands.HELP.desc, label .. ": the list ends with g? itself")
  return text
end

-- The description a `g?` report gives a key: the rest of the line that
-- starts with `lhs` and the two spaces at least that pad it, nil when no line
-- does. A key can be several words, as `:Docket review abandon` is.
local function listed_as(text, lhs)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, #lhs) == lhs then
      local desc = line:sub(#lhs + 1):match("^%s%s+(.*)$")
      if desc then
        return desc
      end
    end
  end
  return nil
end

test("commands: g? lists every key attach sets, in the dash, a ticket's buffer, a merge request's and a draft", function()
  local made = {}
  local ok, err = pcall(function()
    local dash = vim.api.nvim_create_buf(false, true)
    made[#made + 1] = dash
    commands.attach_dash(dash)
    eq(listed_as(lists_every_map(dash, "the dash"), "za"), "Docket: close the section under the cursor, or open it")

    local ticket_buf = loaded_buffer()
    commands.attach(ticket_buf)
    local text = lists_every_map(ticket_buf, "a ticket's buffer")
    eq(listed_as(text, ":w"), "Docket: send the regions that changed")
    eq(listed_as(text, ":e"), "Docket: read the item again; :e! discards unsaved edits")
    eq(listed_as(text, "<leader>dt"), "Docket: move the item to another state")
    eq(listed_as(text, "<leader>dR"), nil, "a ticket's buffer lists no review key")

    local mr = merge_request_buffer()
    made[#made + 1] = mr
    local approve = "Docket: approve, merge or close the merge request (reopen a closed one)"
    text = lists_every_map(mr, "a merge request's buffer")
    eq(listed_as(text, "<leader>dt"), approve, "where approving and merging are")
    eq(listed_as(text, "<leader>dR"), "Docket: review the merge request")
    eq(buffer_map(mr, "<leader>dt").desc, approve, "the map carries it too")

    local draft = vim.api.nvim_create_buf(false, false)
    made[#made + 1] = draft
    vim.api.nvim_buf_set_name(draft, commands.DRAFT .. "keys")
    commands.attach(draft)
    text = keys_reported(draft)
    eq(listed_as(text, ":w"), "Docket: create the ticket")
    eq(listed_as(text, ":e!"), "Docket: start the draft afresh")
    eq(buffer_map(draft, "<leader>dt").buffer, nil, "a draft acts on no item")
  end)
  -- Every buffer made here is deleted whether or not an assertion failed, so
  -- a failure leaves no buffer whose name a later test makes again.
  for _, buf in ipairs(made) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  assert(ok, err)
end)

-- phase 6: the write path, completion, transitions, assignment, create

-- What stub_calls answers with to keep a call's callback for the test to
-- answer later, through the record's `release`.
local HOLD = {}

-- Replaces calls on an adapter module with recorders, and hands back the
-- calls and the restore. Each call is recorded as `{ name, args }` and
-- answered with what `answers[name]` returns for its arguments, delivered
-- from a libuv timer: that is the fast-event context spawn.run's callbacks
-- arrive in, so a caller that touches the editor there without scheduling
-- fails here as it would in the editor. The registry hands back the module
-- itself, so a caller reaching the adapter through adapters.get() meets the
-- recorders too.
local function stub_calls(adapter, answers)
  local calls, saved = {}, {}
  for name, answer in pairs(answers) do
    saved[name] = adapter[name]
    adapter[name] = function(...)
      local args = { n = select("#", ...), ... }
      local on_done = args[args.n]
      local record = { name = name, args = vim.list_slice(args, 1, args.n - 1) }
      calls[#calls + 1] = record
      local function deliver(...)
        local values = { n = select("#", ...), ... }
        local timer = vim.uv.new_timer()
        timer:start(1, 0, function()
          timer:close()
          on_done(unpack(values, 1, values.n))
        end)
      end
      if answer == HOLD then
        record.release = deliver
      else
        deliver(answer(unpack(args, 1, args.n - 1)))
      end
    end
  end
  return calls, function()
    for name, fn in pairs(saved) do
      adapter[name] = fn
    end
  end
end

local function names(calls)
  return vim.tbl_map(function(call)
    return call.name
  end, calls)
end

-- Runs the write command and waits for its on_done, which a write that
-- sends nothing calls before returning.
local function write_and_wait(buf)
  local finished
  local started, message = buffer.write(buf, function(ok, reported)
    finished = { ok = ok, message = reported }
  end)
  vim.wait(2000, function()
    return finished ~= nil
  end)
  return finished, started, message
end

local function contains(text, part)
  return type(text) == "string" and text:find(part, 1, true) ~= nil
end

-- The two comments ticket() carries, each with an `updated`, which is what
-- the conflict check compares a comment by when both the load and the
-- re-read carry one.
local function stamped(overrides)
  local comments = {
    {
      id = 10001,
      author = { id = "acc-ana", name = "ana" },
      created = "2024-04-30T12:00:00.000+0000",
      updated = "2024-04-30T12:00:00.000+0000",
      body = doc(paragraph(text("Repros on staging."))),
    },
    {
      id = 10002,
      author = { id = "acc-me", name = "Me Myself" },
      created = "2024-05-02T09:00:00.000+0000",
      updated = "2024-05-02T09:00:00.000+0000",
      body = doc(paragraph(text("Fix is in review."))),
    },
  }
  for index, fields in pairs(overrides or {}) do
    comments[index] = vim.tbl_extend("force", comments[index] or {}, fields)
  end
  return comments
end

-- A comment the account posted, as the read after the post returns it.
local function posted(id, body, updated)
  return {
    id = id,
    author = { id = "acc-me", name = "Me Myself" },
    created = "2024-05-04T10:00:00.000+0000",
    updated = updated or "2024-05-04T10:00:00.000+0000",
    body = doc(paragraph(text(body))),
  }
end

test("write: no edit makes no call and clears modified, and an edit to the header, the title or an author line is refused, since none is sent", function()
  local buf = loaded_buffer()
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket()
    end,
    body_update = function()
      return true
    end,
    comment_update = function()
      return true
    end,
  })
  local notices, restore_notify = stub_notify()
  local untouched = write_and_wait(buf)
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "X" })
  vim.api.nvim_buf_set_text(buf, 1, 2, 1, 2, { "Y" })
  vim.api.nvim_buf_set_text(buf, 9, 0, 9, 0, { "Z" })
  local modified_then = vim.bo[buf].modified
  local header, started, message = write_and_wait(buf)
  restore_notify()
  restore()
  eq(untouched, { ok = true, message = "nothing changed" })
  eq(notices[1], { message = "nothing changed", level = vim.log.levels.INFO })
  eq(modified_then, true)
  local refusal = 'outside the regions: refused: line 1, "XPROJ-142   In Progress   me   updated 2h ago", is outside every region, where a save sends nothing; move it into a region, or u undoes the edit that put it there'
  eq({ started, message }, { false, refusal }, "the first line changed is named")
  eq(header, { ok = false, message = refusal })
  eq(vim.bo[buf].modified, true, "the edit is still in the buffer, unsent")
  eq(#calls, 0, "no call, not even the check read")
  eq(notices[2], { message = refusal, level = vim.log.levels.WARN })
end)

test("write: a changed body is checked, sent once, read back, and the item's cached rows are dropped", function()
  local _, restore_cache = scratch_cache()
  local holding = cache.key("jira", "project IN (PROJ)" .. OPEN)
  local elsewhere = cache.key("jira", "project IN (PAY)" .. OPEN)
  cache.write(holding, { row.new({ source = "jira", id = "PROJ-142", state = "In Progress", title = "Retry" }) })
  cache.write(elsewhere, { row.new({ source = "jira", id = "PAY-9", state = "To Do", title = "Nine" }) })
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local backend = ticket().body
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ body = backend })
    end,
    body_update = function(_, sent)
      backend = adf.serialise(sent)
      return true
    end,
  })
  local notices, restore_notify = stub_notify()
  local finished, started = write_and_wait(buf)
  restore_notify()
  restore()
  local held, kept = cache.read(holding), cache.read(elsewhere)
  restore_cache()
  eq(started, true)
  eq(names(calls), { "item", "body_update", "item" }, "the check read, the one call, the read that follows it")
  eq(calls[2].args, { "PROJ-142", "XThe retry loop re-enters\nbefore the final attempt." })
  eq(finished, { ok = true, message = "body: written" })
  eq(notices, { { message = "body: written", level = vim.log.levels.INFO } })
  eq(vim.bo[buf].modified, false)
  eq(buffer.writing(buf), false)
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "XThe retry loop re-enters" }, "populated from the read after the write")
  eq(held, nil, "the key whose rows hold the item is dropped")
  eq(kept ~= nil, true, "a key whose rows do not is kept")
end)

test("write: a body changed since the load is not written, and the message names the yank and :e!", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ body = doc(paragraph(text("Somebody rewrote the description."))) })
    end,
    body_update = function()
      return true
    end,
  })
  local notices, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(names(calls), { "item" }, "the check read alone")
  eq(finished.ok, false)
  eq(contains(finished.message, "body: changed since it was loaded"), true, finished.message)
  eq(contains(finished.message, "Yank"), true, "the yank that keeps the text: " .. finished.message)
  eq(contains(finished.message, ":e!"), true, "the reload command: " .. finished.message)
  eq(notices[1].level, vim.log.levels.WARN)
  eq(vim.bo[buf].modified, true)
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "XThe retry loop re-enters" }, "the edit is kept")
end)

test("write: the item's own update time and a colleague's new comment are not a conflict on the body", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local comments = ticket().comments
  comments[#comments + 1] = {
    id = "10003",
    author = { id = "acc-ana", name = "ana" },
    created = "2024-05-09T10:00:00.000+0000",
    body = doc(paragraph(text("Any news?"))),
  }
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ updated = "2024-05-09T10:00:00.000+0000", comments = comments })
    end,
    body_update = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(names(calls), { "item", "body_update", "item" })
  eq(finished.ok, true, finished.message)
end)

test("write: a comment is compared by its own updated when both reads carry one, and by its text otherwise", function()
  local _, restore_notify = stub_notify()
  -- Its `updated` moved: somebody edited it, whatever it says now.
  local buf = loaded_buffer({ comments = stamped() })
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local moved_calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = stamped({ [2] = { updated = "2024-05-05T09:00:00.000+0000" } }) })
    end,
    comment_update = function()
      return true
    end,
  })
  local moved = write_and_wait(buf)
  restore()
  local moved_modified = vim.bo[buf].modified

  -- The same stamp and a different text: the stamp decides, so it is sent.
  buf = loaded_buffer({ comments = stamped() })
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local same_calls
  same_calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = stamped({ [2] = { body = doc(paragraph(text("Reads differently now."))) } }) })
    end,
    comment_update = function()
      return true
    end,
  })
  local same = write_and_wait(buf)
  restore()

  -- No `updated` on either read: the text decides.
  buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local changed = vim.deepcopy(ticket().comments)
  changed[2].body = doc(paragraph(text("Reads differently now.")))
  local text_calls
  text_calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = changed })
    end,
    comment_update = function()
      return true
    end,
  })
  local by_text = write_and_wait(buf)
  restore()

  -- The comment is gone from the re-read.
  buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local gone_calls
  gone_calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = { ticket().comments[1] } })
    end,
    comment_update = function()
      return true
    end,
  })
  local gone = write_and_wait(buf)
  restore()
  restore_notify()
  eq(names(moved_calls), { "item" })
  eq(moved.ok, false)
  eq(contains(moved.message, "10002: edited since it was loaded"), true, moved.message)
  eq(contains(moved.message, "Yank"), true, moved.message)
  eq(contains(moved.message, ":e!"), true, moved.message)
  eq(moved_modified, true)
  eq(names(same_calls), { "item", "comment_update", "item" })
  eq(same_calls[2].args, { "PROJ-142", "10002", "YFix is in review." })
  eq(same.ok, true, same.message)
  eq(names(text_calls), { "item" })
  eq(by_text.ok, false)
  eq(contains(by_text.message, "10002: changed since it was loaded"), true, by_text.message)
  eq(names(gone_calls), { "item" })
  eq(contains(gone.message, "10002: not among the comments the client returned now"), true, gone.message)
end)

-- A merge request, !482, with `body` and `comments`, read by the account
-- `me`, as the GitLab adapter's item() answers one.
local function crlf_merge(body, comments)
  return item.new({ source = "glab", id = "!482", title = "Bump the pinned acli", body = body, comments = comments or {}, me = "me" })
end

-- A comment of the account's own on it.
local function own_note(id, body)
  return {
    id = id,
    author = { id = "me", name = "Me Myself" },
    created = "2024-05-02T09:00:00.000Z",
    updated = "2024-05-02T09:00:00.000Z",
    body = body,
  }
end

-- A buffer holding a merge request as the read command leaves it, under the
-- name an open from a clone of acme/payments gives it. The body is lines 3
-- onwards, 0-based.
local function merge_buffer(it)
  local name = buffer.name("glab", "!482", "acme/payments")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, name)
  buffer.populate(buf, it, { now = NOW })
  return buf
end

test("render: a body's line ends are CRLF only when every break between its lines is, and each region records it", function()
  for _, body in ipairs({ "a\r\nb", "a\r\nb\r\n", "a\r\nb\n" }) do
    eq(render.crlf(body), true, vim.inspect(body) .. ", whatever ends the body")
  end
  eq(render.crlf("a\r\n"), true, "a final CRLF that is the body's only line break is its only evidence of the ending")
  for _, body in ipairs({ "a\n", "a\nb", "a\r\nb\nc", "a\nb\r\n", "\nb", "abc", "" }) do
    eq(render.crlf(body), false, vim.inspect(body))
  end
  eq(render.crlf(nil), false, "no body")
  eq(render.crlf(doc(paragraph(text("a"), { type = "hardBreak" }, text("b")))), false, "a tree has no line ends")
  local _, regions = render.render(crlf_merge("x\r\ny", { own_note(7, "a\r\nb"), own_note(8, "c\nd") }), { now = NOW })
  eq(vim.tbl_map(function(region)
    return { region.id, region.crlf }
  end, regions), { { "body", true }, { "7", true }, { "8" } }, "an LF region carries no field at all")
  eq({ regions[1].lines, regions[2].lines }, { { "x", "y" }, { "a", "b" } }, "the buffer holds the lines without their carriage returns")
end)

test("write: a CRLF body saved unchanged sends nothing, and an edit is compared as LF and sent with CRLF, also after the read that follows it", function()
  eq(render.region_lines("x\r\ny"), { "x", "y" })
  local buf = merge_buffer(crlf_merge("x\r\ny"))
  -- The check before each save reads the body as it was loaded; the read
  -- after the first ends it with the LF glab's write appends.
  local reads = { "x\r\ny", "Xx\r\ny\n", "Xx\r\ny\n", "YXx\r\ny\n" }
  local calls, restore = stub_calls(glab, {
    item = function()
      return crlf_merge(table.remove(reads, 1))
    end,
    body_update = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local unchanged = write_and_wait(buf)
  local sent = {}
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local plan = buffer.plan(buf)
  local first = write_and_wait(buf)
  sent[#sent + 1] = calls[#calls - 1].args
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "Y" })
  local second = write_and_wait(buf)
  sent[#sent + 1] = calls[#calls - 1].args
  restore_notify()
  restore()
  eq(unchanged, { ok = true, message = "nothing changed" })
  eq(plan.calls, { { kind = diff.BODY_UPDATE, id = "body", text = "Xx\ny", crlf = true } }, "the plan's text is the buffer's LF")
  eq(first.ok, true, first.message)
  eq(second.ok, true, second.message)
  eq(names(calls), { "item", "body_update", "item", "item", "body_update", "item" }, "neither save is refused as somebody else's change")
  eq(sent, { { "!482", "Xx\r\ny" }, { "!482", "YXx\r\ny" } }, "each save puts the CRLF back")
  eq(vim.api.nvim_buf_get_lines(buf, 3, 5, false), { "YXx", "y" }, "and the buffer shows no ^M")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("write: an LF body and one mixing both endings are sent with LF, and a CRLF comment is sent with CRLF", function()
  local function sent(it, row)
    local buf = merge_buffer(it)
    vim.api.nvim_buf_set_text(buf, row, 0, row, 0, { "X" })
    local plan = buffer.plan(buf)
    local calls, restore = stub_calls(glab, {
      item = function()
        return it
      end,
      body_update = function()
        return true
      end,
      comment_update = function()
        return true
      end,
    })
    local _, restore_notify = stub_notify()
    local finished = write_and_wait(buf)
    restore_notify()
    restore()
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(finished.ok, true, finished.message)
    eq(#calls, 3, "the check, the update and the read after it")
    return { plan = plan.calls, args = calls[2].args }
  end
  eq(
    sent(crlf_merge("x\ny"), 3),
    { plan = { { kind = diff.BODY_UPDATE, id = "body", text = "Xx\ny" } }, args = { "!482", "Xx\ny" } },
    "an LF body, as it always was"
  )
  eq(
    sent(crlf_merge("x\r\ny\nz"), 3),
    { plan = { { kind = diff.BODY_UPDATE, id = "body", text = "Xx\ny\nz" } }, args = { "!482", "Xx\ny\nz" } },
    "a mixed body is written with LF"
  )
  eq(
    sent(crlf_merge("x", { own_note(7, "a\r\nb") }), 6),
    { plan = { { kind = diff.COMMENT_UPDATE, id = "7", text = "Xa\nb", crlf = true } }, args = { "!482", "7", "Xa\r\nb" } },
    "a comment's CRLF is its own"
  )
end)

test("compose: a new comment is a region at the end, typed on the line it returns, and one at a time", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local row = buffer.compose(buf)
  eq(row, count + 3, "a blank line, the author line, and the line typed on")
  eq(vim.api.nvim_win_get_cursor(0), { row, 0 })
  eq(vim.api.nvim_buf_get_lines(buf, row - 2, row - 1, false), { "me" .. render.SEPARATOR .. "not posted" })
  eq(vim.bo[buf].modified, false, "an empty comment is not an edit")
  eq(buffer.compose(buf), row, "a second compose goes to the one already open")
  eq(vim.api.nvim_buf_line_count(buf), count + 3)
  local plan = buffer.plan(buf)
  eq(plan.calls, {})
  eq(plan.skipped, { { id = "new", reason = "empty; nothing sent" } })
end)

test("compose: a new comment whose line was deleted is replaced, and the author lines it leaves are outside the regions as the save expects", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, {})
  eq(buffer.plan(buf), { calls = {}, skipped = { { id = "new", reason = "empty; nothing sent" } }, refused = {} })
  local again = buffer.compose(buf)
  eq(again, row + 2, "below a blank line and an author line of its own")
  vim.api.nvim_buf_set_text(buf, again - 1, 0, again - 1, 0, { "Second try." })
  eq(buffer.plan(buf), { calls = { { kind = diff.COMMENT_CREATE, id = "new", text = "Second try." } }, skipped = {}, refused = {} })
  -- An edit to the author line compose() wrote is an edit outside every
  -- region like any other.
  vim.api.nvim_buf_set_text(buf, again - 2, 0, again - 2, 0, { "X" })
  local refused = buffer.plan(buf).refused
  eq(#refused, 1)
  eq(refused[1].id, diff.OUTSIDE)
  eq(refused[1].reason:match("^line %d+"), ("line %d"):format(again - 1))
  eq(
    #vim.api.nvim_buf_get_extmarks(buf, buffer.EDGES, 0, -1, {}),
    #vim.api.nvim_buf_get_extmarks(buf, buffer.REGIONS, 0, -1, {}),
    "the replaced comment's edge goes with its mark"
  )
end)

test("compose: u takes a new comment out and the save is what it was before, a redo is refused as overlapping until u, and compose() opens one afresh", function()
  local buf = unsorted_buffer()
  local function now()
    return listed(buffer.plan(buf))
  end
  local function compose()
    local row
    own_block(function()
      row = buffer.compose(buf)
    end)
    return row
  end
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  typed("Aedit<Esc>")
  local edited = { diff.BODY_UPDATE, "body", "charlieedit\nalpha" }
  compose()
  typed("u")
  local undone = now()
  typed("<C-r>")
  local redone = now()
  typed("u")
  local undone_again = now()
  local row = compose()
  typed("Anote<Esc>")
  local composed = now()
  -- The body edit undone too: the empty comment is all that is left.
  typed("uuu")
  local back = now()
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(undone, { edited, "new: empty; nothing sent" }, "u after compose()")
  local recover = "u undoes that edit; otherwise yank the text, then :e! reads the item again"
  eq(redone, {
    ("10002: refused: its text runs into new's, so which lines are whose is lost; %s"):format(recover),
    ("new: refused: its text runs into 10002's, so which lines are whose is lost; %s"):format(recover),
    gone("me   not posted"),
  }, "<C-r> puts the lines back where both ranges end, the author line inside them")
  eq(undone_again, undone, "u after the redo")
  eq(row, 15, "compose() again opens the comment where the first one was")
  eq(composed, { edited, { diff.COMMENT_CREATE, "new", "note" } }, "compose() again, and a comment typed")
  eq(back, { "new: empty; nothing sent" }, "undone back to the read")
end)

test("compose: a new comment whose lines are all gone is withdrawn, and what is put or undone back where it was is the last comment's", function()
  -- A line put below the last comment after u takes compose() out.
  local buf = unsorted_buffer()
  own_block(function()
    buffer.compose(buf)
  end)
  typed("u")
  vim.fn.setreg("a", "one\n", "l")
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  typed('"ap')
  local put = listed(buffer.plan(buf))
  -- compose() then opens another rather than going to the one withdrawn.
  local row = buffer.compose(buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(put, { { diff.COMMENT_UPDATE, "10002", "zulu\nbravo\none" }, "new: empty; nothing sent" }, "a line put")
  eq(row, 16, "compose() after it")
  -- The last comment rewritten, then compose(), then both undone: the undo
  -- puts the comment's lines back where the new one's range sits.
  buf = unsorted_buffer()
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  typed("capR<Esc>")
  own_block(function()
    buffer.compose(buf)
  end)
  typed("uu")
  eq(planned_in(buf, function() end), { "new: empty; nothing sent" }, "undone back to the read")
end)

test("compose: gq over a new comment takes its author line in and leaves it outside, and the comment is sent reflowed", function()
  local buf = unsorted_buffer()
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "one", "two" })
  vim.bo[buf].textwidth = 79
  eq(planned_in(buf, keys(row, "gqip")), { { diff.COMMENT_CREATE, "new", "one two" } })
end)

test("compose: the author line compose() wrote, deleted, is no change, and moved into a region by a sort refuses the save", function()
  local function composed(edit)
    local buf = unsorted_buffer()
    local row = buffer.compose(buf)
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { "note" })
    return planned_in(buf, function()
      edit(row)
    end)
  end
  eq(composed(function(row)
    vim.cmd(("silent %dd"):format(row - 1))
  end), { { diff.COMMENT_CREATE, "new", "note" } }, "deleted")
  -- The author line and the comment's line, sorted last first: the range
  -- collapses where the author line began and takes both lines in.
  eq(composed(function(row)
    vim.cmd(("silent %d,%dsort!"):format(row - 1, row))
  end), { gone("me   not posted") }, "sorted into the comment")
end)

test("write: a new comment is posted without a check, and the read after it names the comment it became", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "A new note." })
  local comments = ticket().comments
  comments[#comments + 1] = posted("10003", "A new note.", "2024-05-04T11:00:00.000+0000")
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = comments })
    end,
    comment_create = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(names(calls), { "comment_create", "item" }, "a post replaces nothing, so nothing is checked first")
  eq(calls[1].args, { "PROJ-142", "A new note." })
  eq(finished, { ok = true, message = "new: posted as 10003" })
  eq(buffer.snapshot(buf).regions.new, nil)
  eq(buffer.snapshot(buf).regions["10003"].lines, { "A new note." })
  eq(vim.b[buf].docket.stamps["10003"], "2024-05-04T11:00:00.000+0000")
  eq(vim.bo[buf].modified, false)
end)

test("write: a second :w before the read that follows a post is refused, so the comment is posted once", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "Once." })
  local comments = ticket().comments
  comments[#comments + 1] = posted("10003", "Once.")
  local calls, restore = stub_calls(jira, { comment_create = HOLD, item = HOLD })
  local notices, restore_notify = stub_notify()
  local finished
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  local in_flight = buffer.writing(buf)
  local before_post = { buffer.write(buf) }
  local composed = { buffer.compose(buf) }
  calls[1].release(true)
  -- The post has answered and the read after it has not.
  vim.wait(2000, function()
    return #calls == 2
  end)
  local before_read = { buffer.write(buf) }
  local still = buffer.writing(buf)
  calls[2].release(ticket({ comments = comments }))
  vim.wait(2000, function()
    return finished ~= nil
  end)
  local after = buffer.plan(buf)
  restore_notify()
  restore()
  eq(in_flight, true)
  eq(before_post[1], false)
  eq(contains(before_post[2], "a write is still in flight"), true, before_post[2])
  eq(composed[1], nil)
  eq(contains(composed[2], "a write is still in flight"), true, composed[2])
  eq(still, true, "the write lasts until the read that names the comment has landed")
  eq(before_read[1], false)
  eq(contains(before_read[2], "a write is still in flight"), true, before_read[2])
  eq(names(calls), { "comment_create", "item" }, "exactly one create")
  eq(finished, { ok = true, message = "new: posted as 10003" })
  eq(after.calls, {}, "and nothing is left to post")
  eq(notices[#notices].message, "new: posted as 10003")
end)

test("write: a post whose read then fails holds the region read-only rather than posting it again", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "A new note." })
  local calls, restore = stub_calls(jira, {
    item = function()
      return nil, "acli exited 1\nError: the service is unavailable"
    end,
    comment_create = function()
      return true
    end,
  })
  local notices, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  local modified = vim.bo[buf].modified
  local unedited = buffer.plan(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "More: " })
  local edited = buffer.plan(buf)
  local composed = { buffer.compose(buf) }
  restore_notify()
  restore()
  eq(names(calls), { "comment_create", "item" })
  eq(finished.ok, true)
  eq(contains(finished.message, "new: posted"), true, finished.message)
  eq(contains(finished.message, "could not be read after the write"), true, finished.message)
  eq(notices[1].level, vim.log.levels.WARN)
  eq(modified, false)
  eq(unedited.calls, {}, "a second :w posts nothing")
  eq(edited.calls, {})
  eq(edited.refused, { { id = "new", reason = buffer.POSTED } })
  eq(composed[1], nil)
  eq(contains(composed[2], buffer.POSTED), true, composed[2])
end)

test("write: a partial failure reports each region, keeps the buffer dirty with its text, and :w sends what is left", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local backend = ticket().body
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ body = backend })
    end,
    body_update = function(_, sent)
      backend = adf.serialise(sent)
      return true
    end,
    comment_update = function()
      return false, "acli exited 1\nError: comment 10002 is locked"
    end,
  })
  local notices, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  -- The plan is in identifier order, so the comment goes before the body.
  eq(names(calls), { "item", "comment_update", "body_update", "item" }, "a failure does not stop the calls after it")
  eq(finished.ok, false)
  eq(contains(finished.message, "body: written"), true, finished.message)
  eq(contains(finished.message, "10002: acli exited 1\nError: comment 10002 is locked"), true, finished.message)
  eq(notices[1].level, vim.log.levels.ERROR)
  eq(vim.bo[buf].modified, true)
  eq(vim.api.nvim_buf_get_lines(buf, 3, 4, false), { "XThe retry loop re-enters" })
  eq(vim.api.nvim_buf_get_lines(buf, 10, 11, false), { "YFix is in review." })
  eq(buffer.plan(buf).calls, { { kind = diff.COMMENT_UPDATE, id = "10002", text = "YFix is in review." } })
end)

test("write: text typed while a post is in flight is kept, and the region takes the new comment's identifier", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "A new note." })
  local comments = ticket().comments
  comments[#comments + 1] = posted("10003", "A new note.")
  local calls, restore = stub_calls(jira, {
    comment_create = HOLD,
    item = function()
      return ticket({ comments = comments })
    end,
  })
  local _, restore_notify = stub_notify()
  local finished
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  local last = #vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  vim.api.nvim_buf_set_text(buf, row - 1, last, row - 1, last, { " And more." })
  calls[1].release(true)
  vim.wait(2000, function()
    return finished ~= nil
  end)
  restore_notify()
  restore()
  eq(finished.ok, true)
  eq(contains(finished.message, "new: posted as 10003"), true, finished.message)
  eq(contains(finished.message, ":w sends those edits"), true, finished.message)
  eq(vim.bo[buf].modified, true)
  local sends = { { kind = diff.COMMENT_UPDATE, id = "10003", text = "A new note. And more." } }
  eq(buffer.plan(buf).calls, sends)
  -- The region keeps its edge under its new identifier: joined onto the
  -- author line of a comment opened below it, it still holds its own text.
  buffer.compose(buf)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.cmd("silent normal! JJ")
  eq(buffer.plan(buf).calls, sends, "joined onto the next author line")
end)

test("write: a body whose words are unchanged and that gained a mark on the web is refused, not flattened", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local coloured = doc(paragraph(
    text("The retry loop re-enters", { { type = "textColor", attrs = { color = "#bf2600" } } }),
    { type = "hardBreak" },
    text("before the final attempt.")
  ))
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ body = coloured })
    end,
    body_update = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(names(calls), { "item" }, "nothing is written")
  eq(finished.ok, false)
  eq(contains(finished.message, "body: now carries a text node with a textColor mark"), true, finished.message)
  eq(vim.bo[buf].modified, true)
end)

test("write: a region the read after a write finds holding what cannot be written back is read-only there", function()
  -- The post is held while the body is edited, so the buffer is settled in
  -- place rather than read afresh.
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "see https://x.test" })
  local carded = {
    id = "10003",
    author = { id = "acc-me", name = "Me Myself" },
    created = "2024-05-04T10:00:00.000+0000",
    updated = "2024-05-04T10:00:00.000+0000",
    body = doc(paragraph(text("see "), { type = "inlineCard", attrs = { url = "https://x.test" } })),
  }
  local comments = ticket().comments
  comments[#comments + 1] = carded
  local calls, restore = stub_calls(jira, {
    comment_create = HOLD,
    item = function()
      return ticket({ comments = comments })
    end,
  })
  local _, restore_notify = stub_notify()
  local finished
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "typed meanwhile " })
  calls[1].release(true)
  vim.wait(2000, function()
    return finished ~= nil
  end)
  restore_notify()
  restore()
  local settled = buffer.snapshot(buf).regions["10003"]
  eq(contains(finished.message, "new: posted as 10003"), true, finished.message)
  eq(settled.editable, false)
  eq(settled.reason, "carries an inlineCard node, which a write would replace by its flattened text; " .. render.WEB_HINT)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "More " })
  eq(buffer.plan(buf).refused, { { id = "10003", reason = settled.reason } }, "an edit to it is refused rather than flattening the card")

  -- The same for a comment the write replaced.
  buf = loaded_buffer({ comments = stamped() })
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, #"Fix is in review.", { "see https://x.test" })
  local replaced = stamped({ [2] = { updated = "2024-05-05T08:00:00.000+0000", body = carded.body } })
  local reads = 0
  calls, restore = stub_calls(jira, {
    comment_update = HOLD,
    item = function()
      reads = reads + 1
      return ticket({ comments = reads == 1 and stamped() or replaced })
    end,
  })
  _, restore_notify = stub_notify()
  finished = nil
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  vim.wait(2000, function()
    return #calls == 2
  end)
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "typed meanwhile " })
  calls[2].release(true)
  vim.wait(2000, function()
    return finished ~= nil
  end)
  restore_notify()
  restore()
  eq(contains(finished.message, "10002: written"), true, finished.message)
  eq(buffer.snapshot(buf).regions["10002"].editable, false, "the comment written is judged as the read found it")
end)

test("write: a comment updated beside a failed call takes its new stamp, so the retry sends the next edit rather than refusing it", function()
  local buf = loaded_buffer({ comments = stamped() })
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Y" })
  local updated = "2024-05-05T08:00:00.000+0000"
  local after_update = stamped({ [2] = { updated = updated, body = doc(paragraph(text("YFix is in review."))) } })
  local reads = 0
  local calls, restore = stub_calls(jira, {
    item = function()
      reads = reads + 1
      return ticket({ comments = reads == 1 and stamped() or after_update })
    end,
    body_update = function()
      return false, "acli exited 1\nError: the description is locked"
    end,
    comment_update = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local first = write_and_wait(buf)
  local after_first = #calls
  vim.api.nvim_buf_set_text(buf, 10, 0, 10, 0, { "Z" })
  local second = write_and_wait(buf)
  restore_notify()
  restore()
  eq(first.ok, false)
  eq(vim.b[buf].docket.stamps["10002"] ~= nil, true)
  eq(names(vim.list_slice(calls, after_first + 1)), { "item", "comment_update", "body_update", "item" }, "the retry sends the comment's second edit")
  eq(contains(second.message, "10002: edited since it was loaded"), false, second.message)
end)

test("write: the comment a post became is the account's own, and the last of the account's holding the text", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "Agreed." })
  local comments = ticket().comments
  -- New comments holding the same words: a colleague's, one of the
  -- account's own posted from elsewhere, the post, and a colleague's after it.
  local function colleague(id)
    return {
      id = id,
      author = { id = "acc-ana", name = "ana" },
      created = "2024-05-04T09:00:00.000+0000",
      body = doc(paragraph(text("Agreed."))),
    }
  end
  comments[#comments + 1] = colleague("10003")
  comments[#comments + 1] = posted("10004", "Agreed.")
  comments[#comments + 1] = posted("10005", "Agreed.")
  comments[#comments + 1] = colleague("10006")
  local _, restore = stub_calls(jira, {
    item = function()
      return ticket({ comments = comments })
    end,
    comment_create = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(finished, { ok = true, message = "new: posted as 10005" })
end)

test("write: a new comment whose line was deleted is opened afresh, and what is typed there is posted", function()
  local buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, {})
  local again = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, again - 1, 0, again - 1, 0, { "Second try." })
  local plan = buffer.plan(buf)
  eq(plan.calls, { { kind = diff.COMMENT_CREATE, id = diff.NEW, text = "Second try." } })
  eq(plan.skipped, {})
end)

test("write: a post killed at its timeout is looked for in the read after it, and held read-only when it is not there", function()
  local function post(found)
    local buf = loaded_buffer()
    vim.api.nvim_set_current_buf(buf)
    local row = buffer.compose(buf)
    vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "Once." })
    local comments = ticket().comments
    if found then
      comments[#comments + 1] = posted("10003", "Once.")
    end
    local calls, restore = stub_calls(jira, {
      comment_create = function()
        return false, "acli: killed after 30000 ms without exiting", true
      end,
      item = function()
        return ticket({ comments = comments })
      end,
    })
    local notices, restore_notify = stub_notify()
    local finished = write_and_wait(buf)
    local again = write_and_wait(buf)
    restore_notify()
    restore()
    return { finished = finished, again = again, calls = names(calls), level = notices[1].level, buf = buf, row = row }
  end
  local landed = post(true)
  eq(landed.calls, { "comment_create", "item" }, "the read after it runs")
  eq(landed.finished, { ok = true, message = "new: posted as 10003; the client was killed at its timeout after sending it" })
  eq(landed.again.message, "nothing changed")
  local lost = post(false)
  eq(lost.calls, { "comment_create", "item" }, "and no second post")
  eq(lost.finished.ok, false)
  eq(lost.level, vim.log.levels.WARN)
  eq(
    lost.finished.message,
    "new: acli: killed after 30000 ms without exiting\nwhether the comment was posted is unknown, so it is held read-only rather than posted again"
  )
  eq(lost.again.message, "nothing changed", "a second :w posts nothing")
  vim.api.nvim_buf_set_text(lost.buf, lost.row - 1, 0, lost.row - 1, 0, { "More " })
  eq(buffer.plan(lost.buf).refused, { { id = diff.NEW, reason = buffer.POSTED } })
end)

test("write: text typed into a post whose read fails is named for yanking, and text typed elsewhere is left for :w", function()
  local function run(typed_row)
    local buf = loaded_buffer()
    vim.api.nvim_set_current_buf(buf)
    local row = buffer.compose(buf)
    vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "A note." })
    local calls, restore = stub_calls(jira, {
      comment_create = HOLD,
      item = function()
        return nil, "acli exited 1\nError: the service is unavailable"
      end,
    })
    local _, restore_notify = stub_notify()
    local finished
    buffer.write(buf, function(ok, message)
      finished = { ok = ok, message = message }
    end)
    vim.api.nvim_buf_set_text(buf, typed_row or (row - 1), 0, typed_row or (row - 1), 0, { "typed " })
    calls[1].release(true)
    vim.wait(2000, function()
      return finished ~= nil
    end)
    local after = write_and_wait(buf)
    restore_notify()
    restore()
    return finished.message, after.message
  end
  local into_post, refused = run(nil)
  eq(
    contains(into_post, "the buffer changed while the write ran; the posted comment is read-only until the item is read again, so yank what was typed into it before :e!"),
    true,
    into_post
  )
  eq(contains(into_post, ":w sends those edits"), false, into_post)
  eq(refused, "new: refused: " .. buffer.POSTED)
  eq(buffer.POSTED, "posted; the comment it became is known once the item is read again: :e reads it when nothing is unsaved, and otherwise yank what to keep before :e!")
  local elsewhere = run(3)
  eq(contains(elsewhere, "the buffer changed while the write ran; :w sends those edits"), true, elsewhere)
end)

test("write: an emptied region is put back by the read after another region is sent", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  vim.api.nvim_buf_set_lines(buf, 10, 11, false, { "" })
  local backend = ticket().body
  local _, restore = stub_calls(jira, {
    item = function()
      return ticket({ body = backend })
    end,
    body_update = function(_, sent)
      backend = adf.serialise(sent)
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished = write_and_wait(buf)
  restore_notify()
  restore()
  eq(finished, { ok = true, message = "body: written\n10002: empty; nothing sent" })
  eq(vim.bo[buf].modified, false)
  eq(vim.api.nvim_buf_get_lines(buf, 10, 11, false), { "Fix is in review." })
end)

test("write: :e! while the check read is out, or while the read after a post is, sends nothing more and says so", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  local calls, restore = stub_calls(jira, {
    item = HOLD,
    body_update = function()
      return true
    end,
  })
  local _, restore_notify = stub_notify()
  local finished
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  -- What :e! does: the edits are gone and the buffer is read again.
  vim.bo[buf].modified = false
  buffer.populate(buf, ticket(), { now = NOW })
  calls[1].release(ticket())
  vim.wait(2000, function()
    return finished ~= nil
  end)
  restore()
  eq(names(calls), { "item" }, "the discarded edit is not sent")
  eq(finished.ok, false)
  eq(contains(finished.message, "closed or read again"), true, finished.message)

  buf = loaded_buffer()
  vim.api.nvim_set_current_buf(buf)
  local row = buffer.compose(buf)
  vim.api.nvim_buf_set_text(buf, row - 1, 0, row - 1, 0, { "A note." })
  local comments = ticket().comments
  comments[#comments + 1] = posted("10003", "A note.")
  calls, restore = stub_calls(jira, {
    comment_create = function()
      return true
    end,
    item = HOLD,
  })
  finished = nil
  buffer.write(buf, function(ok, message)
    finished = { ok = ok, message = message }
  end)
  vim.wait(2000, function()
    return #calls == 2
  end)
  vim.bo[buf].modified = false
  buffer.populate(buf, ticket({ comments = comments }), { now = NOW })
  local reloaded = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  calls[2].release(ticket({ comments = comments }))
  vim.wait(2000, function()
    return finished ~= nil
  end)
  restore_notify()
  restore()
  eq(names(calls), { "comment_create", "item" })
  eq(contains(finished.message, "the buffer was closed or read again while the write ran, so it was left as it is"), true, finished.message)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), reloaded, "the buffer :e! read is left as it is")
end)

test("write: an edit in another account's region refuses the whole save before any call", function()
  local buf = loaded_buffer()
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  vim.api.nvim_buf_set_text(buf, 7, 0, 7, 0, { "not mine: " })
  local calls, restore = stub_calls(jira, {
    item = function()
      return ticket()
    end,
    body_update = function()
      return true
    end,
    comment_update = function()
      return true
    end,
  })
  local notices, restore_notify = stub_notify()
  local finished, started, message = write_and_wait(buf)
  restore_notify()
  restore()
  eq(started, false)
  eq(message, "10001: refused: written by ana; " .. render.WEB_HINT)
  eq(finished, { ok = false, message = message })
  eq(notices, { { message = message, level = vim.log.levels.WARN } })
  eq(#calls, 0, "not even the check read")
  eq(vim.bo[buf].modified, true)
end)

test("complete: the trigger rule, and where each trigger's completion starts", function()
  local complete = require("docket.complete")
  local cases = {
    { "see @an", { "user", "an", 5 } },
    { "ana@exa", {} },
    { "see !48", { "item", "48", 4 } },
    { "done!", {} },
    { "PROJ-1", { "item", "PROJ-1", 0 } },
    { "(PROJ-", { "item", "PROJ-", 1 } },
    { "xPROJ-1", {} },
    { "A-1", {} },
    { "@PROJ-1", { "user", "PROJ-1", 1 } },
    { "plain words", {} },
  }
  for _, case in ipairs(cases) do
    eq({ complete.trigger(case[1]) }, case[2], case[1])
  end
end)

test("complete: ordinary typing answers NONE and asks nothing; a trigger is answered, then served from the cache", function()
  local complete = require("docket.complete")
  complete.clear()
  local waits, restore_wait = stub_wait(function(argv)
    return done(argv, { gl_user("ana", "Ana"), gl_user("andre", "Andre") })
  end)
  local runs, restore_run = stub_run(function(argv)
    return done(argv, {})
  end)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].docket = { source = "glab", id = "!482" }
  vim.api.nvim_set_current_buf(buf)
  -- The cursor sits on the character after the text, since in normal mode
  -- it cannot sit past the last one.
  local function at(line)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line .. " " })
    vim.api.nvim_win_set_cursor(0, { 1, #line })
  end
  at("hello world")
  local ordinary = complete.omnifunc(1, "")
  local ordinary_waits = #waits
  at("see @an")
  local start = complete.omnifunc(1, "")
  local items = complete.omnifunc(0, "an")
  local asked = #waits
  local again = complete.omnifunc(1, "")
  local items_again = complete.omnifunc(0, "an")
  local mismatch_start = complete.omnifunc(1, "")
  local mismatch = complete.omnifunc(0, "somebody else")
  vim.b[buf].docket = nil
  local unloaded = complete.omnifunc(1, "")
  restore_run()
  restore_wait()
  eq(complete.NONE, -3, "-3 cancels silently; -1 starts completion at the cursor and asks a second time")
  eq(ordinary, complete.NONE)
  eq(ordinary_waits, 0, "ordinary typing spawns nothing")
  eq(start, 5, "the name after the @ is replaced, and the @ kept")
  eq(items, { { word = "ana", menu = "Ana" }, { word = "andre", menu = "Andre" } })
  eq(asked, 1)
  eq(waits[1].argv, { "glab", "api", "projects/:id/users?search=an" })
  eq({ again, items_again }, { 5, items })
  eq(#waits, 1, "the repeat is answered from the cache")
  eq(mismatch_start, 5)
  eq(mismatch, {}, "a base that is not the text the first call found gets nothing")
  eq(unloaded, complete.NONE, "a buffer with no item")
  eq(#runs, 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("complete: an item reference keeps only what continues the text typed, and an empty answer is NONE", function()
  local complete = require("docket.complete")
  complete.clear()
  local asked = {}
  local saved = jira.complete
  jira.complete = function(kind, query)
    asked[#asked + 1] = { kind, query }
    if kind == "user" then
      return {}
    end
    return { { id = "PROJ-1", title = "One" }, { id = "PROJ-142", title = "Retry" }, { id = "PAY-1", title = "Pay" } }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].docket = { source = "jira", id = "PROJ-142" }
  vim.api.nvim_set_current_buf(buf)
  local function at(line)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line .. " " })
    vim.api.nvim_win_set_cursor(0, { 1, #line })
  end
  at("see PROJ-1")
  local start = complete.omnifunc(1, "")
  local items = complete.omnifunc(0, "PROJ-1")
  at("see !48")
  local bang = complete.omnifunc(1, "")
  at("ask @an")
  local user_start = complete.omnifunc(1, "")
  jira.complete = saved
  eq(start, 4)
  eq(items, { { word = "PROJ-1", menu = "One" }, { word = "PROJ-142", menu = "Retry" } })
  eq(bang, complete.NONE, "a Jira key does not continue `!48`, so nothing is offered")
  eq(user_start, complete.NONE, "Jira offers no user")
  eq(asked, { { "item", "PROJ-1" }, { "item", "48" }, { "user", "an" } })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("adapters: assign and item_create are in the contract, with the two values a person can be besides an identifier", function()
  eq(vim.tbl_contains(adapters.OPTIONAL, "assign"), true)
  eq(vim.tbl_contains(adapters.OPTIONAL, "item_create"), true)
  eq({ adapters.ARITY.assign, adapters.ARITY.item_create }, { 3, 3 })
  eq({ adapters.ME, adapters.NOBODY }, { "@me", "@nobody" })
  eq({ adapters.can(jira, "assign"), adapters.can(jira, "item_create") }, { true, true })
  eq({ adapters.can(glab, "assign"), adapters.can(glab, "item_create") }, { true, false })
  eq({ adapters.can(gh, "assign"), adapters.can(gh, "item_create") }, { false, false })
end)

test("jira: assign edits the assignee with --yes, as @me, removed, or by account id, and refuses what is none of them", function()
  local calls, restore = stub_run(function(argv)
    return done(argv, "")
  end)
  local got = {}
  local function keep(ok, err)
    got[#got + 1] = { ok, err }
  end
  jira.assign("TIG-1", adapters.ME, keep)
  jira.assign("TIG-1", adapters.NOBODY, keep)
  jira.assign("TIG-1", "acc-ana", keep)
  local spawned = #calls
  jira.assign("TIG-1,TIG-2", adapters.ME, keep)
  jira.assign("TIG-1", nil, keep)
  jira.assign("TIG-1", "", keep)
  restore()
  eq(calls[1].argv, argv_of("workitem", "edit", "--key", "TIG-1", "--assignee", "@me", "--yes", "--json"))
  eq(calls[2].argv, argv_of("workitem", "edit", "--key", "TIG-1", "--remove-assignee", "--yes", "--json"))
  eq(calls[3].argv, argv_of("workitem", "edit", "--key", "TIG-1", "--assignee", "acc-ana", "--yes", "--json"))
  eq(#calls, spawned, "a refusal spawns nothing")
  eq(got, {
    { true },
    { true },
    { true },
    { false, "TIG-1,TIG-2 is not a work item key" },
    { false, "nil is not a person to assign" },
    { false, '"" is not a person to assign' },
  })
  _, restore = stub_run(function(argv)
    return failed(argv, 1, "Error: the user cannot be assigned")
  end)
  local refused
  jira.assign("TIG-1", "acc-ana", function(ok, err)
    refused = { ok, err }
  end)
  restore()
  eq(refused, { false, "acli exited 1\nError: the user cannot be assigned" }, "the client's own words")
end)

test("jira: item_create sends the fields, the assignee when one is asked for, and the body as a document last", function()
  local path, written
  local calls, restore = stub_run(function(argv)
    path, written = read_document(argv, "--description-file")
    return done(argv, { id = "10045", key = "TIG-45", self = "https://example.atlassian.net/rest/api/3/issue/10045" })
  end)
  local got = {}
  local function keep(key, err)
    got[#got + 1] = { key, err }
  end
  jira.item_create({ project = "TIG", type = "Task", summary = "Follow up", assignee = adapters.ME }, "one\n\ntwo", keep)
  local first_path, first_written = path, written
  jira.item_create({ project = "TIG", type = "Bug", summary = "Nobody" }, "", keep)
  jira.item_create({ project = "TIG", type = "Bug", summary = "Nobody either", assignee = adapters.NOBODY }, "\n\n", keep)
  restore()
  eq(calls[1].argv, argv_of(
    "workitem", "create", "--project", "TIG", "--type", "Task", "--summary", "Follow up", "--json",
    "--assignee", "@me", "--description-file", first_path
  ))
  eq(first_written, adf.serialise("one\n\ntwo"), "the file holds the serialised tree")
  eq(vim.uv.fs_stat(first_path), nil, "and is removed once acli has exited")
  eq(calls[2].argv, argv_of("workitem", "create", "--project", "TIG", "--type", "Bug", "--summary", "Nobody", "--json"))
  eq(calls[3].argv, argv_of("workitem", "create", "--project", "TIG", "--type", "Bug", "--summary", "Nobody either", "--json"))
  eq(got, { { "TIG-45" }, { "TIG-45" }, { "TIG-45" } })
end)

test("jira: item_create reads the key from an object, a bulk summary, or text naming exactly one key of the project", function()
  local function create(stdout, summary)
    local _, restore = stub_run(function(argv)
      return done(argv, stdout)
    end)
    local got
    jira.item_create({ project = "TIG", type = "Task", summary = summary or "Follow up" }, "", function(key, err)
      got = { key, err }
    end)
    restore()
    return got
  end
  eq(create({ id = "10045", key = "TIG-45", self = "https://example.atlassian.net/rest/api/3/issue/10045" }), { "TIG-45" })
  eq(create({ results = { { key = "TIG-46" } }, successCount = 1, totalCount = 1 }), { "TIG-46" })
  eq(
    create("Work item TIG-47 created: Follow up TIG-12\nhttps://example.atlassian.net/browse/TIG-47", "Follow up TIG-12"),
    { "TIG-47" },
    "a key the summary names is not the new one"
  )
  local two = create("Created TIG-48 and TIG-49")
  eq(two[1], nil)
  eq(two[2]:find("acli reported the work item created and printed no key", 1, true), 1, two[2])
  eq(contains(two[2], "acli jira workitem search --jql 'project = TIG ORDER BY created DESC' --fields summary --json"), true, two[2])
  eq(two[2]:sub(-#"acli printed:\nCreated TIG-48 and TIG-49"), "acli printed:\nCreated TIG-48 and TIG-49")
  eq(create({ key = "PAY-1" })[1], nil, "a key of another project is not this create's")
end)

test("jira: item_create reports a bulk summary's error and refuses what is not a work item before any spawn", function()
  local _, restore = stub_run(function(argv)
    return done(argv, { results = { { error = "issuetype is required" } }, successCount = 0, totalCount = 1 })
  end)
  local failed_create
  jira.item_create({ project = "TIG", type = "Task", summary = "x" }, "", function(key, err)
    failed_create = { key, err }
  end)
  restore()
  eq(failed_create, { nil, "issuetype is required" })
  local calls
  calls, restore = stub_run(function(argv)
    return done(argv, { key = "TIG-1" })
  end)
  local got = {}
  local function keep(key, err)
    got[#got + 1] = { key, err }
  end
  jira.item_create(nil, "", keep)
  jira.item_create({ project = "TIG", summary = " " }, "", keep)
  jira.item_create({ project = "TIG,PAY", type = "Task", summary = "x" }, "", keep)
  jira.item_create({ project = "TIG", type = "Task", summary = "x", assignee = "" }, "", keep)
  restore()
  eq(#calls, 0)
  eq(got, {
    { nil, "a work item needs a project, a type and a summary" },
    { nil, "a work item needs a type, a summary" },
    { nil, "TIG,PAY is not a project key such as PROJ" },
    { nil, '"" is not a person to assign' },
  })
end)

test("jira: an identical create while one runs joins it, and a different one makes its own", function()
  local pending, saved = {}, spawn.run
  spawn.run = function(argv, _, on_done)
    pending[#pending + 1] = { argv = argv, on_done = on_done }
  end
  local answers = {}
  local function keep(key, err)
    answers[#answers + 1] = { key, err }
  end
  local fields = { project = "TIG", type = "Task", summary = "Once" }
  jira.item_create(fields, "the body", keep)
  jira.item_create(vim.deepcopy(fields), "the body", keep)
  local joined = #pending
  jira.item_create(fields, "another body", keep)
  local separate = #pending
  pending[1].on_done(done(pending[1].argv, { key = "TIG-50" }))
  pending[2].on_done(done(pending[2].argv, { key = "TIG-51" }))
  spawn.run = saved
  eq(joined, 1, "one spawn for two identical creates")
  eq(separate, 2)
  eq(answers, { { "TIG-50" }, { "TIG-50" }, { "TIG-51" } })
end)

test("glab: assign updates with --yes, as the account's username, unassigned, or by username, and refuses the rest", function()
  glab.forget()
  local calls, restore = stub_glab()
  local got = {}
  local function keep(ok, err)
    got[#got + 1] = { ok, err }
  end
  glab.assign("!482", adapters.ME, keep)
  glab.assign("!482", adapters.NOBODY, keep)
  glab.assign("!482", "ana", keep)
  local spawned = #calls
  for _, odd in ipairs({ "+ana", "-ana", "!ana", "ana,bob" }) do
    glab.assign("!482", odd, keep)
  end
  glab.assign("!482", nil, keep)
  glab.assign("PROJ-1", "ana", keep)
  restore()
  eq(vim.tbl_map(function(call)
    return call.argv
  end, calls), {
    { "glab", "api", "user" },
    { "glab", "mr", "update", "482", "--assignee", "me", "--yes" },
    { "glab", "mr", "update", "482", "--unassign", "--yes" },
    { "glab", "mr", "update", "482", "--assignee", "ana", "--yes" },
  })
  eq(#calls, spawned, "a refusal spawns nothing")
  eq(got, {
    { true },
    { true },
    { true },
    { false, '"+ana" is not a GitLab username' },
    { false, '"-ana" is not a GitLab username' },
    { false, '"!ana" is not a GitLab username' },
    { false, '"ana,bob" is not a GitLab username' },
    { false, "nil is not a GitLab username" },
    { false, "PROJ-1 is not a merge request identifier" },
  })
  glab.forget()
  calls, restore = stub_run(function(argv)
    return failed(argv, 1, "glab: 401 Unauthorized")
  end)
  local refused
  glab.assign("!482", adapters.ME, function(ok, err)
    refused = { ok, err }
  end)
  restore()
  eq(#calls, 1, "no update when the account is unknown")
  eq(refused, { false, "glab exited 1\nglab: 401 Unauthorized" })
end)

test("glab: states reports a view that printed no merge request rather than raising", function()
  for _, payload in ipairs({ "null", "5" }) do
    local _, restore = stub_run(function(argv)
      return done(argv, payload)
    end)
    local got
    glab.states("!482", function(states, err)
      got = { states, err }
    end)
    restore()
    eq(got, { nil, "glab: mr view 482 printed no merge request; run\n  glab mr view 482 -F json\nby hand to see what it prints" }, payload)
  end
end)

test("fast events: assign and item_create answer from a fast event without touching the editor", function()
  glab.forget()
  local _, restore = stub_run_fast(function(argv)
    if argv[1] == "glab" then
      return glab_answer()(argv)
    end
    return done(argv, { key = "TIG-45" })
  end)
  local notices, restore_notify = stub_notify()
  local assigned, created
  glab.assign("!482", adapters.ME, function(ok, err)
    assigned = { ok, err }
  end)
  jira.item_create({ project = "TIG", type = "Task", summary = "Fast" }, "a body", function(key, err)
    created = { key, err }
  end)
  vim.wait(2000, function()
    return assigned ~= nil and created ~= nil
  end)
  restore_notify()
  restore()
  eq(assigned, { true })
  eq(created, { "TIG-45" })
  eq(notices, {})
end)

-- vim.ui.select replaced for a test: it records what it was offered and
-- answers with the entry `pick` chooses, or nil to cancel.
local function stub_select(pick)
  local offered, saved = {}, vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    offered.items = items
    offered.prompt = opts.prompt
    offered.labels = vim.tbl_map(opts.format_item, items)
    on_choice(pick(items))
  end
  return offered, function()
    vim.ui.select = saved
  end
end

test("commands: an item buffer binds a new comment, a transition and an assignment, and a draft binds none of them", function()
  local buf = loaded_buffer()
  commands.attach(buf)
  for _, lhs in ipairs({ "<leader>dc", "<leader>dt", "<leader>da", "gx", "<leader>dw" }) do
    local map = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    eq(map.buffer, 1, lhs)
  end
  local draft = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(draft, commands.DRAFT .. "test")
  commands.attach(draft)
  local none = vim.api.nvim_buf_call(draft, function()
    return vim.fn.maparg("<leader>dt", "n", false, true)
  end)
  eq(none.buffer, nil, "a draft acts on no item")
  vim.api.nvim_buf_delete(draft, { force = true })

  -- <leader>dc opens the comment region.
  vim.api.nvim_set_current_buf(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>dc", true, false, true), "x", false)
  eq(vim.api.nvim_buf_line_count(buf), count + 3)
  eq(vim.api.nvim_win_get_cursor(0), { count + 3, 0 })
  eq(buffer.snapshot(buf).regions.new ~= nil, true)
end)

test("commands: a transition offers the adapter's states, applies the one chosen, drops the cached rows and reads the item", function()
  local _, restore_cache = scratch_cache()
  local key = cache.key("jira", "project IN (PROJ)" .. OPEN)
  cache.write(key, { row.new({ source = "jira", id = "PROJ-142", state = "In Progress", title = "Retry" }) })
  local buf = loaded_buffer()
  local load = vim.b[buf].docket.load
  local offered, restore_select = stub_select(function(items)
    return items[2]
  end)
  local calls, restore = stub_calls(jira, {
    -- Each label differs from its target, so the target is what is sent.
    states = function()
      return { { label = "Done, resolved", target = "Done" }, { label = "In Review, awaiting", target = "In Review" } }
    end,
    state_set = function()
      return true
    end,
    item = function()
      return ticket({ state = "In Review" })
    end,
  })
  local notices, restore_notify = stub_notify()
  commands.transition(buf)
  vim.wait(2000, function()
    return vim.b[buf].docket.load ~= load
  end)
  restore_notify()
  restore()
  restore_select()
  local cached = cache.read(key)
  restore_cache()
  eq(names(calls), { "states", "state_set", "item" })
  eq(calls[2].args, { "PROJ-142", "In Review" })
  eq(offered.prompt, "Move PROJ-142 to")
  eq(offered.labels, { "Done, resolved", "In Review, awaiting" })
  eq(notices, { { message = "PROJ-142: In Review, awaiting", level = vim.log.levels.INFO } })
  eq(cached, nil, "the rows holding the item are dropped")
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("^PROJ%-142   In Review") ~= nil, true, "the item is read again")
end)

test("commands: a status the workflow refuses is the client's own error; a cancel, no state and a failed list send nothing", function()
  local buf = loaded_buffer()
  local refusal = "acli exited 1\nError: Transition 'Done' is not valid for PROJ-142: Resolution is required"
  local notices, restore_notify = stub_notify()
  local _, restore_select = stub_select(function(items)
    return items[1]
  end)
  local refused_calls, restore = stub_calls(jira, {
    states = function()
      return { { label = "Done", target = "Done" } }
    end,
    state_set = function()
      return false, refusal
    end,
  })
  commands.transition(buf)
  vim.wait(2000, function()
    return #notices > 0
  end)
  restore()
  restore_select()

  local offered
  offered, restore_select = stub_select(function()
    return nil
  end)
  local cancelled_calls
  cancelled_calls, restore = stub_calls(jira, {
    states = function()
      return { { label = "Done", target = "Done" } }
    end,
    state_set = function()
      return true
    end,
  })
  commands.transition(buf)
  vim.wait(2000, function()
    return offered.items ~= nil
  end)
  restore()
  restore_select()

  local listed = {}
  for _, answer in ipairs({ { {} }, { nil, "acli exited 1\nError: search failed" } }) do
    local shown = #notices
    local calls
    calls, restore = stub_calls(jira, {
      states = function()
        return answer[1], answer[2]
      end,
      state_set = function()
        return true
      end,
    })
    commands.transition(buf)
    vim.wait(2000, function()
      return #notices > shown
    end)
    restore()
    listed[#listed + 1] = names(calls)
  end
  restore_notify()
  eq(names(refused_calls), { "states", "state_set" })
  eq(notices[1], { message = "PROJ-142: Done: " .. refusal .. "\n" .. commands.WEB, level = vim.log.levels.ERROR })
  eq(names(cancelled_calls), { "states" }, "a cancelled picker applies nothing")
  eq(listed, { { "states" }, { "states" } })
  eq(notices[2], { message = "PROJ-142: there is no state to move it to", level = vim.log.levels.INFO })
  eq(notices[3], { message = "PROJ-142: acli exited 1\nError: search failed", level = vim.log.levels.ERROR })
  eq(#notices, 3)
end)

test("commands: an assignment offers me, nobody and the item's people, and applies the one chosen", function()
  local buf = loaded_buffer()
  local load = vim.b[buf].docket.load
  local notices, restore_notify = stub_notify()
  local offered, restore_select = stub_select(function(items)
    return items[4]
  end)
  -- A reporter who wrote no comment, so each source of people is seen.
  local chosen_calls, restore = stub_calls(jira, {
    item = function()
      return ticket({ reporter = { id = "acc-bo", name = "Bo" } })
    end,
    assign = function()
      return true
    end,
  })
  commands.assign(buf)
  vim.wait(2000, function()
    return vim.b[buf].docket.load ~= load
  end)
  restore()
  restore_select()

  -- Nobody, on a buffer holding edits, which is not read again after.
  vim.api.nvim_buf_set_text(buf, 3, 0, 3, 0, { "X" })
  _, restore_select = stub_select(function(items)
    return items[2]
  end)
  local nobody_calls, shown
  nobody_calls, restore = stub_calls(jira, {
    item = function()
      return ticket()
    end,
    assign = function()
      return true
    end,
  })
  shown = #notices
  commands.assign(buf)
  vim.wait(2000, function()
    return #nobody_calls == 2 and #notices > shown
  end)
  restore()
  restore_select()
  local kept = vim.api.nvim_buf_get_lines(buf, 3, 4, false)

  -- A refusal, in the client's own words.
  _, restore_select = stub_select(function(items)
    return items[1]
  end)
  local refused_calls
  refused_calls, restore = stub_calls(jira, {
    item = function()
      return ticket()
    end,
    assign = function()
      return false, "acli exited 1\nError: the account cannot be assigned here"
    end,
  })
  shown = #notices
  commands.assign(buf)
  vim.wait(2000, function()
    return #refused_calls == 2 and #notices > shown
  end)
  restore()
  restore_select()
  restore_notify()
  eq(names(chosen_calls), { "item", "assign", "item" }, "the people come from a read, and the item is read again after")
  eq(offered.prompt, "Assign PROJ-142 to")
  eq(offered.labels, { "me (assigned)", "nobody", "Bo", "ana" }, "the assignee, the reporter, then each comment's author, once each")
  eq(vim.tbl_map(function(choice)
    return choice.who
  end, offered.items), { adapters.ME, adapters.NOBODY, "acc-bo", "acc-ana" })
  eq(chosen_calls[2].args, { "PROJ-142", "acc-ana" })
  eq(notices[1], { message = "PROJ-142: assigned to ana", level = vim.log.levels.INFO })
  eq(names(nobody_calls), { "item", "assign" })
  eq(nobody_calls[2].args, { "PROJ-142", adapters.NOBODY })
  eq(contains(notices[2].message, "PROJ-142: unassigned; the buffer holds unsaved edits"), true, notices[2].message)
  eq(kept, { "XThe retry loop re-enters" })
  eq(names(refused_calls), { "item", "assign" })
  eq(refused_calls[2].args, { "PROJ-142", adapters.ME })
  eq(notices[3], { message = "PROJ-142: acli exited 1\nError: the account cannot be assigned here", level = vim.log.levels.ERROR })
  eq(#notices, 3)
end)

-- Deletes the draft an earlier test left, so each create test starts with none.
local function no_draft()
  local draft = buffer.named(commands.DRAFT .. "jira")
  if draft then
    vim.api.nvim_buf_delete(draft, { force = true })
  end
end

test("commands: a backend lacking a capability says so in one line and calls nothing", function()
  no_draft()
  local buf = loaded_buffer()
  local saved = jira.capabilities
  jira.capabilities = {}
  -- Held, so a regression that makes a call gets no answer that could reach
  -- a picker after this test.
  local calls, restore = stub_calls(jira, { item = HOLD, states = HOLD })
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  -- A regression that reached a picker would otherwise block on the real one.
  local _, restore_select = stub_select(function()
    return nil
  end)
  local ok, raised = pcall(function()
    commands.transition(buf)
    commands.assign(buf)
    commands.comment(buf)
    commands.create("TIG")
  end)
  commands.transition(vim.api.nvim_create_buf(false, true))
  drained()
  restore_select()
  restore_notify()
  restore_wait()
  restore()
  jira.capabilities = saved
  eq({ ok, raised }, { true })
  eq(#calls, 0)
  eq(notices, {
    { message = "docket://jira/PROJ-142: the jira adapter has no states", level = vim.log.levels.WARN },
    { message = "docket://jira/PROJ-142: the jira adapter has no assign", level = vim.log.levels.WARN },
    { message = "docket://jira/PROJ-142: the jira adapter has no comment_create", level = vim.log.levels.WARN },
    { message = "docket-new://jira: the jira adapter has no item_create", level = vim.log.levels.WARN },
    { message = "nothing loaded in this buffer; :e reads the item", level = vim.log.levels.WARN },
  })
  eq(buffer.named(commands.DRAFT .. "jira"), nil, "no draft is made")
end)

test("create: a draft's header is parsed into the fields item_create takes, and the rest is the body", function()
  local fields, body = commands.parse_draft({
    "Project: TIG",
    "type: Bug",
    "Summary:   Retry drops the last attempt  ",
    "Assignee: me",
    "",
    "",
    "First line.",
    "",
    "Second.",
    "",
  })
  eq(fields, { project = "TIG", type = "Bug", summary = "Retry drops the last attempt", assignee = adapters.ME })
  eq(body, "First line.\n\nSecond.")
  eq(commands.parse_draft({ "Assignee: nobody" }).assignee, adapters.NOBODY)
  eq(commands.parse_draft({ "Assignee: acc-ana" }).assignee, "acc-ana")
  eq({ commands.parse_draft({ "Project: TIG", "Summary: ", "Assignee:" }) }, { { project = "TIG" }, "" }, "an empty value is an absent field")
  eq({ commands.parse_draft({ "Project TIG" }) }, { nil, "line 1 is not a header line such as `Summary: text`; a blank line ends the header" })
  eq({ commands.parse_draft({ "Priority: High" }) }, { nil, "Priority is not a field of a new ticket; the fields are Project, Type, Summary, Assignee" })
end)

test("create: :Docket create opens a draft, :w creates the ticket once, and the ticket's buffer takes the draft's place", function()
  no_draft()
  local previous = buffer.named(buffer.name("jira", "TIG-45"))
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  jira.forget()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  commands.run({ fargs = { "create", "TIG" }, bang = false })
  local draft = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_name(draft), "docket-new://jira")
  eq(vim.api.nvim_buf_get_lines(draft, 0, -1, false), { "Project: TIG", "Type: Task", "Summary: ", "Assignee: ", "", "" })
  eq(vim.api.nvim_win_get_cursor(0), { 3, 8 }, "at the summary")
  eq({ vim.bo[draft].buftype, vim.bo[draft].bufhidden, vim.bo[draft].buflisted }, { "acwrite", "hide", true })
  eq(vim.bo[draft].modified, false, "a blank draft is not an edit")
  vim.api.nvim_buf_set_text(draft, 2, 9, 2, 9, { "Follow up" })
  vim.api.nvim_buf_set_lines(draft, 5, 6, false, { "The body." })
  local calls, restore = stub_calls(jira, {
    item_create = HOLD,
    item = function()
      return ticket({ id = "TIG-45" })
    end,
  })
  local finished
  local started = commands.save_draft(draft, function(ok, message)
    finished = { ok, message }
  end)
  local locked = vim.bo[draft].modifiable
  local again = { commands.save_draft(draft) }
  local reopened_while = commands.create("TIG")
  calls[1].release("TIG-45")
  vim.wait(2000, function()
    local buf = buffer.named(buffer.name("jira", "TIG-45"))
    return finished ~= nil and buf ~= nil and vim.b[buf].docket ~= nil
  end)
  restore()
  restore_notify()
  restore_wait()
  local item_buf = buffer.named(buffer.name("jira", "TIG-45"))
  eq(started, true)
  eq(locked, false, "the draft cannot change while its create is in flight")
  eq(again[1], false)
  eq(contains(again[2], "a create is in flight"), true, again[2])
  eq(reopened_while, draft, ":Docket create while one is in flight goes to that draft")
  eq(names(calls), { "item_create", "item" }, "one create, then the new item's read")
  eq(calls[1].args, { { project = "TIG", type = "Task", summary = "Follow up" }, "The body." })
  eq(finished, { true, "created TIG-45" })
  eq(vim.api.nvim_get_current_buf(), item_buf, "the new ticket is where the draft was")
  eq(vim.api.nvim_buf_is_valid(draft), false, "and the draft is gone")
  eq(vim.b[item_buf].docket.id, "TIG-45")
  eq(notices[#notices], { message = "created TIG-45", level = vim.log.levels.INFO })
  vim.api.nvim_buf_delete(item_buf, { force = true })
end)

-- Whether a buffer is valid, loaded and listed, in that order.
local function held(buf)
  return {
    vim.api.nvim_buf_is_valid(buf),
    vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf),
    vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted,
  }
end

test("create: :Docket create after :bdelete of the draft makes the draft afresh, so it is filled once", function()
  no_draft()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  jira.forget()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  local fills = 0
  local counter = vim.api.nvim_create_autocmd("BufReadCmd", {
    pattern = "docket-new://*",
    callback = function()
      fills = fills + 1
    end,
  })
  local other = vim.api.nvim_create_buf(true, false)
  local ok, err = pcall(function()
    local first = commands.create("TIG")
    vim.api.nvim_set_current_buf(other)
    vim.cmd("bdelete " .. first)
    eq(held(first), { true, false, false }, ":bdelete leaves the draft, unloaded and off the list")
    fills = 0
    local second = commands.create("PAY")
    eq(vim.api.nvim_buf_is_valid(first), false, "the deleted draft is wiped")
    eq(second ~= first, true, "and the draft is made afresh")
    eq(vim.api.nvim_get_current_buf(), second)
    eq(vim.api.nvim_buf_get_name(second), "docket-new://jira")
    eq(vim.api.nvim_buf_get_lines(second, 0, -1, false), { "Project: PAY", "Type: Task", "Summary: ", "Assignee: ", "", "" })
    eq({ vim.bo[second].buftype, vim.bo[second].buflisted, vim.bo[second].modified }, { "acwrite", true, false })
    eq(fills, 0, "showing it fires no BufReadCmd")
    eq(notices, {})
  end)
  vim.api.nvim_del_autocmd(counter)
  restore_notify()
  restore_wait()
  no_draft()
  vim.api.nvim_buf_delete(other, { force = true })
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  assert(ok, err)
end)

test("create: a created ticket whose buffer :bdelete left takes the draft's place in a buffer made afresh, so it is read once", function()
  no_draft()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  local name = buffer.name("jira", "TIG-46")
  local previous = buffer.named(name)
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  jira.forget()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  local calls, restore = stub_calls(jira, {
    item_create = HOLD,
    item = function()
      return ticket({ id = "TIG-46" })
    end,
  })
  local count, restore_count = count_reads()
  local ok, err = pcall(function()
    local old = buffer.open("jira", "TIG-46")
    vim.wait(1000, function()
      return vim.b[old].docket ~= nil
    end)
    local draft = commands.create("TIG")
    vim.cmd("bdelete " .. old)
    eq(held(old), { true, false, false }, ":bdelete leaves the ticket's buffer, unloaded and off the list")
    vim.api.nvim_buf_set_text(draft, 2, 9, 2, 9, { "Follow up" })
    count.reads = 0
    local before = #calls
    local finished
    commands.save_draft(draft, function(saved, message)
      finished = { saved, message }
    end)
    calls[#calls].release("TIG-46")
    vim.wait(2000, function()
      local buf = buffer.named(name)
      return finished ~= nil and buf ~= nil and vim.b[buf].docket ~= nil
    end)
    drained()
    local item_buf = buffer.named(name)
    eq(finished, { true, "created TIG-46" })
    eq(vim.api.nvim_buf_is_valid(old), false, "the deleted buffer is wiped")
    eq(item_buf ~= old, true, "and the ticket opens in a buffer made afresh")
    eq(vim.api.nvim_get_current_buf(), item_buf, "where the draft was")
    eq({ vim.bo[item_buf].buftype, vim.bo[item_buf].buflisted }, { "acwrite", true })
    eq(names(vim.list_slice(calls, before + 1)), { "item_create", "item" }, "one create, then one read of the ticket")
    eq(count.reads, 0, "showing it fires no BufReadCmd")
    eq(notices[#notices], { message = "created TIG-46", level = vim.log.levels.INFO })
    vim.api.nvim_buf_delete(item_buf, { force = true })
  end)
  restore_count()
  restore()
  restore_notify()
  restore_wait()
  no_draft()
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  assert(ok, err)
end)

test("commands: :Docket create's draft wraps in its window", function()
  no_draft()
  jira.forget()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  local ok, err = in_tab(function()
    local draft = commands.create("TIG")
    eq(vim.api.nvim_get_current_buf(), draft)
    eq(wrapping(0), WRAPS, "draft() ran before the window showed the draft, and create() sets them there")
  end, true)
  restore_notify()
  restore_wait()
  no_draft()
  assert(ok, err)
  eq(notices, {})
end)

test("create: a create the client refuses keeps the draft and its text, and a missing field is the adapter's own refusal", function()
  no_draft()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  local draft = commands.create("TIG")
  vim.api.nvim_buf_set_text(draft, 2, 9, 2, 9, { "Follow up" })
  local calls, restore = stub_calls(jira, {
    item_create = function()
      return nil, "acli exited 1\nError: issuetype is required"
    end,
  })
  local refused
  commands.save_draft(draft, function(ok, message)
    refused = { ok, message }
  end)
  vim.wait(2000, function()
    return refused ~= nil
  end)
  restore()
  local refused_level = notices[#notices].level
  local after = {
    valid = vim.api.nvim_buf_is_valid(draft),
    modified = vim.bo[draft].modified,
    modifiable = vim.bo[draft].modifiable,
    summary = vim.api.nvim_buf_get_lines(draft, 2, 3, false)[1],
  }
  -- A second :Docket create goes to the draft holding text, and keeps it.
  local again = commands.create("PAY")
  local project_line = vim.api.nvim_buf_get_lines(draft, 0, 1, false)[1]

  -- No summary: the real adapter refuses before any spawn, which the suite's
  -- guard would otherwise turn into a different message.
  vim.api.nvim_buf_set_lines(draft, 2, 3, false, { "Summary: " })
  local missing
  commands.save_draft(draft, function(ok, message)
    missing = { ok, message }
  end)
  vim.wait(2000, function()
    return missing ~= nil
  end)
  vim.api.nvim_buf_set_lines(draft, 0, 1, false, { "Project TIG" })
  local malformed = { commands.save_draft(draft) }
  local bad_project = commands.create("tig")
  restore_notify()
  restore_wait()
  vim.api.nvim_buf_delete(draft, { force = true })
  eq(names(calls), { "item_create" })
  eq(refused, { false, "docket-new://jira: acli exited 1\nError: issuetype is required" })
  eq(refused_level, vim.log.levels.ERROR)
  eq(after, { valid = true, modified = true, modifiable = true, summary = "Summary: Follow up" })
  eq(again, draft)
  eq(project_line, "Project: TIG")
  eq(missing, { false, "docket-new://jira: a work item needs a summary" })
  eq(malformed, { false, "docket-new://jira: line 1 is not a header line such as `Summary: text`; a blank line ends the header" })
  eq(bad_project, nil)
  eq(notices[#notices], { message = "create takes a project key such as PROJ; got tig", level = vim.log.levels.ERROR })
end)

test("create: a create that may have made the ticket leaves its text on screen and is not a draft any more, so :w makes no second one", function()
  no_draft()
  local _, restore_wait = stub_acli({ signed_in = true })
  local notices, restore_notify = stub_notify()
  local draft = commands.create("TIG")
  vim.api.nvim_buf_set_text(draft, 2, 9, 2, 9, { "Follow up" })
  local calls, restore = stub_calls(jira, {
    item_create = function()
      return nil, "acli reported the work item created and printed no key that can be read", true
    end,
  })
  local first
  commands.save_draft(draft, function(ok, message)
    first = { ok, message }
  end)
  vim.wait(2000, function()
    return first ~= nil
  end)
  local after = {
    modified = vim.bo[draft].modified,
    modifiable = vim.bo[draft].modifiable,
    summary = vim.api.nvim_buf_get_lines(draft, 2, 3, false)[1],
  }
  local second = { commands.save_draft(draft) }
  restore()
  restore_notify()
  restore_wait()
  vim.api.nvim_buf_delete(draft, { force = true })
  eq(first[1], false)
  eq(after, { modified = false, modifiable = true, summary = "Summary: Follow up" })
  eq(second, { false, "nothing to create in this buffer; :Docket create starts a ticket" })
  eq(names(calls), { "item_create" }, "one create")
  eq(notices[#notices].level, vim.log.levels.WARN)
end)

test("jira: a create killed at its timeout, or reported done with no key, answers that the ticket may exist", function()
  local function create(answer)
    local _, restore = stub_run(answer)
    local got
    jira.item_create({ project = "TIG", type = "Task", summary = "Follow up" }, "", function(...)
      got = { n = select("#", ...), ... }
    end)
    restore()
    return got
  end
  local killed = create(function(argv)
    return { argv = argv, ok = false, code = spawn.TIMED_OUT, stdout = "", stderr = "", timed_out = true, timeout = 30000 }
  end)
  eq({ killed[1], killed[3] }, { nil, true })
  eq(killed[2]:find("acli: killed after 30000 ms without exiting\nthe create may have reached Jira", 1, true), 1, killed[2])
  eq(contains(killed[2], "acli jira workitem search --jql 'project = TIG ORDER BY created DESC'"), true, killed[2])
  local unread = create(function(argv)
    return done(argv, "created, see the board")
  end)
  eq({ unread[1], unread[3] }, { nil, true })
  local refused = create(function(argv)
    return failed(argv, 1, "Error: issuetype is required")
  end)
  eq({ refused[1], refused[3] }, { nil, nil }, "a refusal made nothing")
end)

test("adapters: a write killed at its timeout answers that it may have been sent, on Jira and on GitLab", function()
  local killed = function(argv)
    return { argv = argv, ok = false, code = spawn.TIMED_OUT, stdout = "", stderr = "", timed_out = true, timeout = 30000 }
  end
  local got = {}
  local function keep(...)
    got[#got + 1] = { ... }
  end
  local _, restore = stub_run(killed)
  jira.comment_create("PROJ-142", "Once.", keep)
  glab.comment_create("!482", "Once.", keep)
  restore()
  _, restore = stub_run(function(argv)
    return failed(argv, 1, "refused")
  end)
  jira.comment_create("PROJ-142", "Once.", keep)
  glab.comment_create("!482", "Once.", keep)
  restore()
  eq(vim.tbl_map(function(answer)
    return answer[3] == true
  end, got), { true, true, false, false })
end)

test("glab: a user search that fails is not asked again for a while, and a login asks again at once", function()
  glab.forget()
  local waits, restore_wait = stub_wait(function(argv)
    return failed(argv, 1, "dial tcp: i/o timeout")
  end)
  local first = glab.complete("user", "a")
  local second = glab.complete("user", "an")
  local count = #waits
  glab.forget()
  glab.complete("user", "ana")
  restore_wait()
  eq({ first, second }, { {}, {} })
  eq(count, 1, "the second query waits for nothing")
  eq(#waits, 2, "after a login the search is asked again")
  glab.forget()
end)

test("create: the project comes from the argument, the ticket in the current buffer, or the clone's one bound project", function()
  no_draft()
  local _, restore_wait = stub_acli({ signed_in = true })
  local saved_root, saved_binding = repo.root, repo.binding
  local bound = { kind = "projects", projects = { "PAY" } }
  repo.root = function()
    return { root = "/w/repo", bare = true }
  end
  repo.binding = function()
    return bound
  end
  local _, restore_notify = stub_notify()
  local item_buf = loaded_buffer()
  vim.api.nvim_set_current_buf(item_buf)
  local from_item = commands.create()
  local first_from_item = vim.api.nvim_buf_get_lines(from_item, 0, 1, false)[1]
  vim.api.nvim_buf_delete(from_item, { force = true })
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
  local from_binding = commands.create()
  local first_from_binding = vim.api.nvim_buf_get_lines(from_binding, 0, 1, false)[1]
  vim.api.nvim_buf_delete(from_binding, { force = true })
  bound = { kind = "projects", projects = { "PAY", "OPS" } }
  -- Deleting the draft put the item buffer, which is listed, back in the
  -- window, and its ticket would name the project.
  vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
  local ambiguous = commands.create()
  local first_ambiguous = vim.api.nvim_buf_get_lines(ambiguous, 0, 1, false)[1]
  vim.api.nvim_buf_delete(ambiguous, { force = true })
  restore_notify()
  repo.root, repo.binding = saved_root, saved_binding
  restore_wait()
  eq(first_from_item, "Project: PROJ")
  eq(first_from_binding, "Project: PAY")
  eq(first_ambiguous, "Project: ", "two bound projects leave the choice to the reader")
end)

test("plugin: :e on a draft's name fills it, :w on it goes to the create, and :e! in flight keeps what was sent", function()
  no_draft()
  vim.g.loaded_docket = nil
  dofile(root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua")
  local saved_root = repo.root
  repo.root = function()
    return nil, "not a clone"
  end
  local notices, restore_notify = stub_notify()
  vim.cmd.edit("docket-new://jira")
  local draft = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
  vim.api.nvim_buf_set_text(draft, 0, 9, 0, 9, { "TIG" })
  vim.cmd.write()
  vim.wait(2000, function()
    return #notices > 0
  end)
  local refused = vim.deepcopy(notices)

  -- A create in flight: `:e!` empties the draft before the read command
  -- runs, and the read command puts back what was sent.
  vim.api.nvim_buf_set_text(draft, 2, 9, 2, 9, { "Kept" })
  local sent = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
  local calls, restore = stub_calls(jira, { item_create = HOLD })
  vim.cmd.write()
  vim.cmd("edit!")
  local after_reload = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
  local shown = #notices
  calls[1].release(nil, "acli exited 1\nError: issuetype is required")
  vim.wait(2000, function()
    return #notices > shown
  end)
  restore()
  restore_notify()
  repo.root = saved_root
  vim.api.nvim_del_user_command("Docket")
  vim.g.loaded_docket = nil
  local after_failure = vim.api.nvim_buf_get_lines(draft, 0, -1, false)
  local modified = vim.bo[draft].modified
  vim.api.nvim_buf_delete(draft, { force = true })
  eq(lines, { "Project: ", "Type: Task", "Summary: ", "Assignee: ", "", "" })
  eq(refused, { { message = "docket-new://jira: a work item needs a summary", level = vim.log.levels.ERROR } })
  eq(#calls, 1)
  eq(after_reload, sent, ":e! during the create leaves the text that was sent")
  eq(after_failure, sent, "and a refused create leaves it to correct")
  eq(modified, true)
  eq(notices[#notices], { message = "docket-new://jira: acli exited 1\nError: issuetype is required", level = vim.log.levels.ERROR })
end)

-- phase 7: the review mode

-- The file the review tests comment on is the one the GitLab fixtures'
-- discussions sit in, twenty lines long, in a worktree of its own on disk:
-- locate() finds a buffer's file by resolving its path under the worktree.
-- The worktree is returned resolved, as review.lua holds it.
local REVIEW_FILE = "lua/docket/env.lua"

local function review_worktree()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/lua/docket", "p")
  local lines = {}
  for index = 1, 20 do
    lines[index] = ("line %d"):format(index)
  end
  vim.fn.writefile(lines, dir .. "/" .. REVIEW_FILE)
  return vim.uv.fs_realpath(dir)
end

-- git and glab's state check as review.lua meets them through spawn.wait:
-- the worktree is on !482's source branch at its head, its merge base with
-- the target is !482's base, it holds no uncommitted change, and a directory
-- outside it is in no worktree. glab is signed in. `answers` replaces any git
-- answer, keyed by the words after `git`.
local function review_wait(worktree, answers)
  answers = answers or {}
  local fixed = {
    ["rev-parse HEAD"] = DIFF_REFS.head_sha .. "\n",
    ["rev-parse --abbrev-ref HEAD"] = merge_request().source_branch .. "\n",
    ["merge-base origin/main HEAD"] = DIFF_REFS.base_sha .. "\n",
    ["status --porcelain --untracked-files=no"] = "",
    ["diff --quiet HEAD -- " .. REVIEW_FILE] = "",
    -- One hunk that shows every line of the file on both sides.
    ["diff -U3 --no-color " .. DIFF_REFS.base_sha .. " HEAD -- " .. REVIEW_FILE] = table.concat({
      "diff --git a/" .. REVIEW_FILE .. " b/" .. REVIEW_FILE,
      "--- a/" .. REVIEW_FILE,
      "+++ b/" .. REVIEW_FILE,
      "@@ -1,20 +1,20 @@",
      "",
    }, "\n"),
  }
  return stub_wait(function(argv, opts)
    if argv[1] == "glab" and argv[2] == "auth" then
      return done(argv, "✓ Logged in to gitlab.example.test as me\n")
    end
    if argv[1] ~= "git" then
      return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
    end
    local asked = table.concat(argv, " ", 2)
    if answers[asked] then
      return answers[asked](argv, opts)
    end
    if asked == "rev-parse --show-toplevel" then
      local cwd = vim.uv.fs_realpath(opts.cwd) or opts.cwd
      if cwd == worktree or cwd:sub(1, #worktree + 1) == worktree .. "/" then
        return done(argv, worktree .. "\n")
      end
      return failed(argv, 128, "fatal: not a git repository (or any of the parent directories): .git\n")
    end
    if fixed[asked] then
      return done(argv, fixed[asked])
    end
    return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
  end)
end

-- diffview.nvim as review.lua meets it: `:DiffviewOpen` records its
-- arguments and opens a tab showing the worktree's file, which is what
-- `--imply-local` makes of the new side, and `:DiffviewClose` closes the tab
-- it runs in. With `tab` false it opens nothing, as diffview does for a range
-- it cannot read. review_case() deletes both commands.
local function stub_diffview(worktree, opts)
  opts = opts or {}
  local opened = {}
  vim.api.nvim_create_user_command("DiffviewOpen", function(command)
    opened[#opened + 1] = command.fargs
    if opts.tab ~= false then
      vim.cmd.tabnew()
      vim.cmd.edit(vim.fn.fnameescape(worktree .. "/" .. REVIEW_FILE))
    end
  end, { nargs = "*" })
  vim.api.nvim_create_user_command("DiffviewClose", function()
    vim.cmd.tabclose()
  end, {})
  return opened
end

-- An adapter carrying every call a review makes and nothing else, each one
-- answered by stub_calls from a libuv timer -- the fast event a client's
-- answer lands in -- with what `answers` returns for it, or held for the test
-- to release. A call `answers` does not name raises.
local function review_adapter(answers)
  local adapter = {
    capabilities = vim.deepcopy(review.NEEDS),
    url = function()
      return merge_request().web_url
    end,
  }
  for _, name in ipairs(review.NEEDS) do
    adapter[name] = function()
      error("the test gave " .. name .. " no answer")
    end
  end
  local calls = stub_calls(adapter, answers)
  return adapter, calls
end

-- !482 as its read answers it, with no discussion, and every write
-- succeeding; `overrides` replace any of the calls.
local function review_answers(overrides)
  return vim.tbl_extend("force", {
    diff = function()
      return { source = merge_request().source_branch, target = "main", refs = vim.deepcopy(DIFF_REFS) }
    end,
    threads = function()
      return {}
    end,
    line_comment = function()
      return true
    end,
    thread_resolve = function()
      return true
    end,
    submit = function()
      return true
    end,
  }, overrides or {})
end

-- A discussion as threads() answers one, on `line` of REVIEW_FILE's new
-- side: a resolvable thread, not resolved, of one note. `fields` replace any
-- of that, `position` whole.
local function review_thread(id, line, fields)
  return vim.tbl_extend("force", {
    id = id,
    individual = false,
    resolvable = true,
    resolved = false,
    position = { new_path = REVIEW_FILE, old_path = REVIEW_FILE, new_line = line },
    notes = { { author = { id = "ana", name = "Ana" }, body = ("On %s."):format(id) } },
  }, fields or {})
end

-- !482's review in the worktree as load() leaves it, with no diff open: the
-- worktree on the source branch at the merge request's head and base.
local function read_review(worktree)
  local r = review.start("glab", "!482", worktree)
  r.head, r.base, r.branch = DIFF_REFS.head_sha, DIFF_REFS.base_sha, merge_request().source_branch
  r.source_branch, r.target, r.refs = merge_request().source_branch, "main", vim.deepcopy(DIFF_REFS)
  return r
end

-- What review.lua gives every adapter call in place of !482: the reference
-- naming the worktree.
local function review_ref(worktree)
  return { id = "!482", cwd = worktree }
end

-- Opens !482's review from inside the worktree and waits for the report or
-- the refusal that ends the open, which `notices` collects. With no adapter,
-- review.open() asks auth.ready() for one, as the command does.
local function open_review(worktree, adapter, notices)
  vim.cmd.cd(vim.fn.fnameescape(worktree))
  local before = #notices
  local r = review.open("glab", "!482", adapter)
  vim.wait(2000, function()
    return #notices > before
  end)
  return r
end

-- Sends a review and waits for what it reports, as `{ ok, message }`.
local function send_and_wait(r, adapter, verdict)
  local reported
  review.send(r, adapter, verdict, function(ok, message)
    reported = { ok, message }
  end)
  vim.wait(2000, function()
    return reported ~= nil
  end)
  return reported
end

-- What the review draws in a buffer: each mark's 0-based row, and its
-- virtual lines as the text they show.
local function review_drawn(buf)
  local space = vim.api.nvim_create_namespace("docket/review")
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, space, 0, -1, { details = true })) do
    local lines = {}
    for _, chunks in ipairs(mark[4].virt_lines or {}) do
      lines[#lines + 1] = table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
      end, chunks))
    end
    found[#found + 1] = { row = mark[2], lines = lines }
  end
  return found
end

-- Writes `lines` into the compose buffer in the current window with `:w`,
-- and waits for the buffer to go, which it does once what was written is
-- held or sent.
local function compose_write(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd.write()
  vim.wait(1000, function()
    return not vim.api.nvim_buf_is_valid(buf)
  end)
  return buf
end

-- The review's keys as a buffer has them: each key's description where the
-- buffer maps it, false where it does not.
local function review_keys_on(buf)
  return vim.api.nvim_buf_call(buf, function()
    return vim.tbl_map(function(key)
      local map = vim.fn.maparg(key.lhs, "n", false, true)
      return map.buffer == 1 and map.desc or false
    end, commands.REVIEW_KEYS)
  end)
end

local PLUGIN = root .. "/dot_local/share/private_nvim/private_site/pack/docket/start/docket/plugin/docket.lua"

-- Runs a review test in a worktree of its own, and puts the editor back
-- whatever the test did, failing or not: every function a review test
-- replaces, the working directory, the tabs and buffers the test left, the
-- diffview commands and view, the plugin's command, and every review of the
-- worktree, discarded. A review test that fails would otherwise leave its
-- tab current and its review answering review.current() for the next one.
local function review_case(body)
  local saved = {
    { auth, "ready" },
    { review, "open" },
    { review, "comment" },
    { review, "reply" },
    { review, "resolve" },
    { review, "submit" },
    { review, "abandon" },
    { list, "row_at" },
    { list, "state" },
    { gh, "item" },
    { vim, "notify" },
    { vim.ui, "select" },
    { vim.api, "nvim_echo" },
    { vim.cmd, "redraw" },
    { vim.env, "TMUX" },
  }
  for _, entry in ipairs(saved) do
    entry[3] = entry[1][entry[2]]
  end
  local cwd = vim.fn.getcwd()
  local tabs = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    tabs[tab] = true
  end
  local worktree = review_worktree()
  local ok, err = pcall(body, worktree)
  -- A client answer still on its timer, and what it schedules, land here,
  -- in this test, rather than in the next one's notices.
  vim.wait(20)
  for _, entry in ipairs(saved) do
    entry[1][entry[2]] = entry[3]
  end
  package.loaded["diffview.lib"] = nil
  for _, id in ipairs({ "!482", "!4" }) do
    local left = review.get(worktree, id)
    if left then
      review.discard(left)
    end
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not tabs[tab] and #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    local real = vim.uv.fs_realpath(name) or name
    if name:sub(1, #review.SCHEME) == review.SCHEME or real:sub(1, #worktree + 1) == worktree .. "/" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  pcall(vim.api.nvim_del_user_command, "DiffviewOpen")
  pcall(vim.api.nvim_del_user_command, "DiffviewClose")
  if vim.g.loaded_docket then
    pcall(vim.api.nvim_del_user_command, "Docket")
    vim.g.loaded_docket = nil
  end
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  if not ok then
    error(err, 0)
  end
end

test("review: the module loads inside a fast event, making no call there that the editor refuses", function()
  local saved = package.loaded["docket.review"]
  package.loaded["docket.review"] = nil
  local loaded
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    timer:close()
    loaded = { pcall(require, "docket.review") }
  end)
  vim.wait(2000, function()
    return loaded ~= nil
  end)
  package.loaded["docket.review"] = saved
  eq(loaded[1], true, tostring(loaded[2]))
  eq(type(loaded[2].open), "function")
end)

test("review: a machine without diffview is told so in one line, from the command as well, and nothing runs or raises", function()
  review_case(function(worktree)
    eq(vim.fn.exists(":DiffviewOpen"), 0, "no diffview in this editor")
    local adapter, calls = review_adapter(review_answers())
    local notices = stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    -- spawn raises between tests, so a check that reached git or glab would
    -- raise here, and the command's pcall would say so.
    local opened = review.open("glab", "!482", adapter)
    local ran, raised = pcall(commands.run, { fargs = { "review", "!482" }, bang = false })
    eq(opened, nil)
    eq({ ran, raised }, { true, nil })
    eq(notices, {
      { message = review.NO_DIFFVIEW, level = vim.log.levels.WARN },
      { message = review.NO_DIFFVIEW, level = vim.log.levels.WARN },
    })
    eq(review.NO_DIFFVIEW:find("\n", 1, true), nil, "one line")
    eq(calls, {})
    eq(review.get(worktree, "!482"), nil, "no review is made")
  end)
end)

test("review: an adapter missing a call the review makes is refused naming the call, before git or the client runs", function()
  review_case(function(worktree)
    stub_diffview(worktree)
    local adapter, calls = review_adapter(review_answers())
    adapter.capabilities = vim.tbl_filter(function(name)
      return name ~= "submit"
    end, adapter.capabilities)
    local notices = stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    eq(review.open("glab", "!482", adapter), nil)
    eq(notices, { { message = "!482: glab has no review mode; it does not implement submit", level = vim.log.levels.ERROR } })
    eq(calls, {})
  end)
end)

test("review: open diffs origin/<target>...HEAD in a tab of its own and reports its discussions and how many are on lines", function()
  review_case(function(worktree)
    review_wait(worktree)
    local opened = stub_diffview(worktree)
    local general = review_thread("general", 1, { individual = true })
    general.position = nil
    local adapter, calls = review_adapter(review_answers({
      threads = function()
        return { review_thread("t1", 12), general }
      end,
    }))
    local notices = stub_notify()
    local before = vim.api.nvim_get_current_tabpage()
    local r = open_review(worktree, adapter, notices)
    eq(opened, { { "origin/main...HEAD", "--imply-local" } })
    eq(r.tab ~= nil and r.tab ~= before, true, "a tab of its own")
    eq(vim.api.nvim_get_current_tabpage(), r.tab, "and it is the current one")
    eq(review.current(), r)
    eq(
      { r.root, r.head, r.base, r.branch, r.source_branch, r.target },
      { worktree, DIFF_REFS.head_sha, DIFF_REFS.base_sha, "feature/acli.bump", "feature/acli.bump", "main" }
    )
    eq(r.refs, DIFF_REFS)
    eq(names(calls), { "diff", "threads" })
    eq(notices, {
      {
        message = "!482: 2 discussion(s), 1 on lines of the diff; 0 comment(s) held. :Docket review comment holds one at the cursor, and :Docket review submit sends them.",
        level = vim.log.levels.INFO,
      },
    })
  end)
end)

test("review: open refuses a worktree on another branch, a target with no merge base here, and a diffview that opened no tab", function()
  review_case(function(worktree)
    local adapter = review_adapter(review_answers())
    local notices = stub_notify()
    local function attempt(answers, diffview)
      local previous = review.get(worktree, "!482")
      if previous then
        review.discard(previous)
      end
      review_wait(worktree, answers)
      local opened = stub_diffview(worktree, diffview)
      return open_review(worktree, adapter, notices), opened
    end
    local on_other, other_opened = attempt({
      ["rev-parse --abbrev-ref HEAD"] = function(argv)
        return done(argv, "PROJ-1-other\n")
      end,
    })
    local no_base, base_opened = attempt({
      ["merge-base origin/main HEAD"] = function(argv)
        return failed(argv, 128, "fatal: Not a valid object name origin/main\n")
      end,
    })
    local no_tab, tab_opened = attempt({}, { tab = false })
    eq({ #other_opened, #base_opened, #tab_opened }, { 0, 0, 1 }, "diffview is asked only once the worktree holds the merge request's change")
    eq(notices, {
      {
        message = ("!482: %s is on PROJ-1-other and the merge request's source branch is feature/acli.bump, so origin/main...HEAD would not be its change. R on the dashboard builds its worktree."):format(worktree),
        level = vim.log.levels.ERROR,
      },
      {
        message = ("!482: origin/main has no merge base with HEAD here. Fetch it and open the review again:\n  git -C %s fetch origin main\n  :Docket review !482\ngit exited 128\nfatal: Not a valid object name origin/main\n"):format(worktree),
        level = vim.log.levels.ERROR,
      },
      {
        message = "!482: diffview opened no tab for origin/main...HEAD; :messages holds its reason. The held comments are kept.",
        level = vim.log.levels.ERROR,
      },
    })
    eq({ on_other.tab, no_base.tab, no_tab.tab }, {}, "none of them has a tab")
  end)
end)

test("review: open on a worktree behind the merge request's head still opens, and warns with the command that brings it level", function()
  review_case(function(worktree)
    review_wait(worktree, {
      ["rev-parse HEAD"] = function(argv)
        return done(argv, ("d"):rep(40) .. "\n")
      end,
    })
    local opened = stub_diffview(worktree)
    local notices = stub_notify()
    local r = open_review(worktree, (review_adapter(review_answers())), notices)
    eq(#opened, 1)
    eq(r.tab, vim.api.nvim_get_current_tabpage())
    eq(#notices, 1)
    eq(notices[1].level, vim.log.levels.WARN)
    eq(vim.split(notices[1].message, "\n"), {
      "!482: 0 discussion(s), 0 on lines of the diff; 0 comment(s) held. :Docket review comment holds one at the cursor, and :Docket review submit sends them.",
      "!482: the worktree is at dddddddd and the merge request's head is cccccccc, so a line numbered here is not the line a comment would land on. Bring the worktree to the head and open the review again:",
      ("  git -C %s pull --ff-only origin feature/acli.bump"):format(worktree),
      "  :Docket review !482",
    })
  end)
end)

test("review: marks draw a discussion on the side its position names, a held comment on its own side, and a held reply under its thread", function()
  local new = { path = REVIEW_FILE, old_path = REVIEW_FILE, side = review.NEW }
  local old = { path = REVIEW_FILE, old_path = REVIEW_FILE, side = review.OLD }
  local threads = {
    review_thread("added", 3),
    review_thread("removed", nil, { position = { old_path = REVIEW_FILE, old_line = 7 } }),
    review_thread("kept", 9, { position = { new_path = REVIEW_FILE, new_line = 9, old_path = REVIEW_FILE, old_line = 8 } }),
    review_thread("elsewhere", 3, { position = { new_path = "lua/docket/list.lua", new_line = 3 } }),
    review_thread("placeless", 3, { position = { position_type = "text" } }),
  }
  local held = {
    { position = { file = REVIEW_FILE, line = 5 }, text = "New side." },
    { position = { file = REVIEW_FILE, old_line = 6 }, text = "Old side." },
    { position = { file = "lua/docket/list.lua", line = 5 }, text = "Another file." },
    { position = { thread = "kept" }, text = "A reply." },
  }
  local function placed(marks)
    return vim.tbl_map(function(mark)
      return {
        mark.line,
        vim.tbl_map(function(chunks)
          return table.concat(vim.tbl_map(function(chunk)
            return chunk[1]
          end, chunks))
        end, mark.lines),
      }
    end, marks)
  end
  local bar = review.BAR
  eq(placed(review.marks(threads, held, new)), {
    { 3, { bar .. " Ana  unresolved", bar .. "   On added." } },
    { 9, { bar .. " Ana  unresolved", bar .. "   On kept.", bar .. " reply, not sent", bar .. "   A reply." } },
    { 5, { bar .. " comment, not sent", bar .. "   New side." } },
  }, "a line the change kept is drawn on the new side alone, and the reply has no mark of its own")
  eq(placed(review.marks(threads, held, old)), {
    { 7, { bar .. " Ana  unresolved", bar .. "   On removed." } },
    { 6, { bar .. " comment, not sent", bar .. "   Old side." } },
  })
end)

test("review: locate answers a worktree file as the new side, asks diffview's view for either side, and answers nothing for any other buffer", function()
  review_case(function(worktree)
    local r = review.start("glab", "!482", worktree)
    r.tab = vim.api.nvim_get_current_tabpage()
    local file = vim.fn.bufadd(worktree .. "/" .. REVIEW_FILE)
    vim.fn.bufload(file)
    local outside_path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, outside_path)
    local outside = vim.fn.bufadd(outside_path)
    vim.fn.bufload(outside)
    local panel = vim.api.nvim_create_buf(false, true)
    local old_side = vim.api.nvim_create_buf(false, true)
    local by_file = { review.locate(r, file), review.locate(r, outside), review.locate(r, panel) }
    local view = {
      tabpage = r.tab,
      cur_entry = { path = REVIEW_FILE, oldpath = "lua/docket/launch.lua" },
      cur_layout = { a = { file = { bufnr = old_side } }, b = { file = { bufnr = file } } },
    }
    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return view
      end,
    }
    local renamed = { review.locate(r, old_side), review.locate(r, file) }
    -- Another file of the worktree, open in a split beside the diff.
    vim.fn.writefile({ "y" }, worktree .. "/lua/docket/other.lua")
    local beside = vim.fn.bufadd(worktree .. "/lua/docket/other.lua")
    vim.fn.bufload(beside)
    local split = review.locate(r, beside)
    vim.api.nvim_buf_delete(beside, { force = true })
    view.cur_entry.oldpath = nil
    local unrenamed = review.locate(r, old_side)
    view.tabpage = -1
    local other_tab = { review.locate(r, old_side), review.locate(r, file) }
    package.loaded["diffview.lib"] = {
      get_current_view = function()
        error("diffview changed its insides")
      end,
    }
    local raising = { review.locate(r, old_side), review.locate(r, file) }
    package.loaded["diffview.lib"] = nil
    vim.api.nvim_buf_delete(outside, { force = true })
    vim.api.nvim_buf_delete(panel, { force = true })
    vim.api.nvim_buf_delete(old_side, { force = true })
    local new_side = { path = REVIEW_FILE, side = review.NEW, local_file = true }
    eq(by_file, { new_side }, "a file outside the worktree and a scratch buffer are no side")
    eq(renamed, {
      { path = REVIEW_FILE, old_path = "lua/docket/launch.lua", side = review.OLD, local_file = false },
      { path = REVIEW_FILE, old_path = "lua/docket/launch.lua", side = review.NEW, local_file = true },
    })
    eq(unrenamed, { path = REVIEW_FILE, old_path = REVIEW_FILE, side = review.OLD, local_file = false })
    eq(split, nil, "a file of the worktree that the view of this tab shows on neither side is no side")
    eq(other_tab, { nil, new_side }, "a view of another tab is passed over, and the file route answers")
    eq(raising, { nil, new_side }, "and so is a view that raises")
  end)
end)

test("review: hold adds, replaces and drops the comment at a place, and refuses a line the worktree cannot place", function()
  review_case(function(worktree)
    local r = review.start("glab", "!482", worktree)
    local at4 = { file = REVIEW_FILE, line = 4 }
    local unread = { review.hold(r, at4, "Early.") }
    r.head, r.base, r.refs = DIFF_REFS.head_sha, DIFF_REFS.base_sha, vim.deepcopy(DIFF_REFS)
    local first = { review.hold(r, at4, "First.") }
    local second = { review.hold(r, at4, "Second.") }
    local replaced = vim.deepcopy(r.held)
    local dropped = { review.hold(r, at4, "") }
    local none = { review.hold(r, at4, "") }
    -- Behind the head: a new-side line is refused and an old-side line is not.
    r.head = ("d"):rep(40)
    local behind = { review.hold(r, at4, "Behind.") }
    local old_behind = { review.hold(r, { file = REVIEW_FILE, old_line = 4 }, "Old side.") }
    -- Another merge base: the old side is refused and the new side is not.
    r.head, r.base = DIFF_REFS.head_sha, ("e"):rep(40)
    local other_base = { review.hold(r, { file = REVIEW_FILE, old_line = 5 }, "Old side again.") }
    local new_other_base = { review.hold(r, { file = REVIEW_FILE, line = 6 }, "New side.") }
    r.refs = nil
    local reply = { review.hold(r, { thread = "t1" }, "A reply.") }
    eq(unread, { false, "!482: the merge request has not been read; :Docket review !482 reads it" })
    eq(first, { true, "!482: held at lua/docket/env.lua:4; 1 held, and :Docket review submit sends them" })
    eq(second, { true, "!482: replaced the comment held at lua/docket/env.lua:4; 1 held" })
    eq(replaced, { { position = at4, text = "Second.", head = DIFF_REFS.head_sha, base = DIFF_REFS.base_sha } })
    eq(dropped, { true, "!482: dropped the comment held at lua/docket/env.lua:4; 0 held" })
    eq(none, { true, "!482: nothing is held at lua/docket/env.lua:4" })
    eq(behind[1], false)
    eq(behind[2]:find("!482: the worktree is at dddddddd and the merge request's head is cccccccc", 1, true), 1, behind[2])
    eq(old_behind[1], true)
    eq(other_base[1], false)
    eq(other_base[2]:find("!482: the diff here starts from eeeeeeee and the merge request's starts from aaaaaaaa", 1, true), 1, other_base[2])
    eq(new_other_base[1], true)
    eq(reply[1], true, "a reply is placed by its thread, so it is taken with nothing read")
    eq(vim.tbl_map(function(entry)
      return entry.position
    end, r.held), { { file = REVIEW_FILE, old_line = 4 }, { file = REVIEW_FILE, line = 6 }, { thread = "t1" } })
  end)
end)

test("review: submit posts each held comment in the order held, then applies the verdict, and nothing is held after", function()
  review_case(function(worktree)
    local adapter, calls = review_adapter(review_answers())
    local r = read_review(worktree)
    review.hold(r, { file = REVIEW_FILE, line = 9 }, "Held first.")
    review.hold(r, { file = REVIEW_FILE, old_line = 2 }, "On the old side.")
    review.hold(r, { thread = "t1" }, "A reply.")
    local reported = send_and_wait(r, adapter, { approve = true, summary = "Looks right." })
    eq(names(calls), { "diff", "line_comment", "line_comment", "line_comment", "submit", "submit" })
    eq(vim.tbl_map(function(call)
      return call.args
    end, vim.list_slice(calls, 2)), {
      { review_ref(worktree), { file = REVIEW_FILE, line = 9 }, "Held first." },
      { review_ref(worktree), { file = REVIEW_FILE, old_line = 2 }, "On the old side." },
      { review_ref(worktree), { thread = "t1" }, "A reply." },
      { review_ref(worktree), { summary = "Looks right." } },
      { review_ref(worktree), { approve = true, head = DIFF_REFS.head_sha } },
    }, "the summary, then the approval of the head the review was opened at")
    eq(r.held, {})
    eq(reported, { true, "!482: posted 3 comment(s), posted the summary, approved" })
  end)
end)

test("review: a failure part-way stops the batch, keeps the comment that failed and those after it, reports glab's own words, and a second submit sends only those", function()
  review_case(function(worktree)
    local creates = 0
    local calls = stub_run_fast(function(argv, opts)
      if argv[3] == "note" and argv[4] == "create" then
        creates = creates + 1
        if creates == 2 then
          return failed(argv, 1, "ERROR: 403 Forbidden\n")
        end
      end
      return glab_answer()(argv, opts)
    end)
    local r = read_review(worktree)
    for _, line in ipairs({ 3, 5, 7 }) do
      review.hold(r, { file = REVIEW_FILE, line = line }, ("At %d."):format(line))
    end
    local first = send_and_wait(r, glab, { approve = true })
    local after_first = #calls
    local still_held = vim.tbl_map(function(entry)
      return entry.position.line
    end, r.held)
    local second = send_and_wait(r, glab, { approve = true })
    local function writes(from, to)
      local found = {}
      for _, call in ipairs(vim.list_slice(calls, from, to)) do
        if call.argv[4] == "create" or call.argv[3] == "approve" then
          found[#found + 1] = { table.concat(call.argv, " "), call.opts.stdin }
        end
      end
      return found
    end
    local create = "glab mr note create 482 --file lua/docket/env.lua --line "
    eq(first, {
      false,
      ("!482: 1 of 3 held comment(s) posted. The one at lua/docket/env.lua:5 failed, and it and the 1 held after it are still held; no verdict was applied. :Docket review submit sends what is still held. A failure that came after the merge request took the comment -- a timeout, typically -- would post it twice, so check %s first.\nglab exited 1\nERROR: 403 Forbidden\n"):format(
        merge_request().web_url
      ),
    })
    eq(writes(1, after_first), { { create .. "3", "At 3.\n" }, { create .. "5", "At 5.\n" } }, "nothing after the failure, and no approval")
    eq(still_held, { 5, 7 })
    eq(second, { true, "!482: posted 2 comment(s), approved" })
    eq(writes(after_first + 1, #calls), {
      { create .. "5", "At 5.\n" },
      { create .. "7", "At 7.\n" },
      { "glab mr approve 482 --sha " .. DIFF_REFS.head_sha },
    })
    eq(r.held, {})
  end)
end)

test("review: nothing is sent when the merge request has moved since a comment was held, and the bang posts it anyway", function()
  review_case(function(worktree)
    local moved = vim.tbl_extend("force", DIFF_REFS, { head_sha = ("d"):rep(40) })
    local adapter, calls = review_adapter(review_answers({
      diff = function()
        return { source = merge_request().source_branch, target = "main", refs = moved }
      end,
    }))
    local r = read_review(worktree)
    review.hold(r, { file = REVIEW_FILE, line = 5 }, "Here.")
    local refused = send_and_wait(r, adapter, { approve = true })
    local asked = names(calls)
    local held = #r.held
    local forced = send_and_wait(r, adapter, { approve = true, force = true })
    eq(asked, { "diff" })
    eq(refused[1], false)
    eq(refused[2]:find("its head is now dddddddd", 1, true) ~= nil, true, refused[2])
    eq(refused[2]:find(review.VERBS.force, 1, true) ~= nil, true, refused[2])
    eq(vim.split(refused[2], "\n")[2], "  lua/docket/env.lua:5", "the comment is named")
    eq(held, 1)
    eq(names(calls), { "diff", "line_comment", "submit" }, "the bang posts without reading the merge request again")
    eq(forced, { true, "!482: posted 1 comment(s), approved" })
  end)
end)

test("review: replies alone or a verdict alone post without reading the merge request again, nothing held and no verdict sends nothing, and a failed re-read sends nothing", function()
  review_case(function(worktree)
    local r = read_review(worktree)
    local replies, reply_calls = review_adapter(review_answers())
    review.hold(r, { thread = "t1" }, "Agreed.")
    local replied = send_and_wait(r, replies, {})
    local verdict_only, verdict_calls = review_adapter(review_answers())
    local approved = send_and_wait(r, verdict_only, { approve = true })
    local idle, idle_calls = review_adapter(review_answers())
    local nothing = send_and_wait(r, idle, {})
    local broken, broken_calls = review_adapter(review_answers({
      diff = function()
        return nil, "glab exited 1\nERROR: 500 Internal Server Error"
      end,
    }))
    review.hold(r, { file = REVIEW_FILE, line = 5 }, "Here.")
    local unread = send_and_wait(r, broken, { approve = true })
    eq(names(reply_calls), { "line_comment" }, "no verdict makes no submit call")
    eq(reply_calls[1].args, { review_ref(worktree), { thread = "t1" }, "Agreed." })
    eq(replied, { true, "!482: posted 1 comment(s)" })
    eq(names(verdict_calls), { "submit" })
    eq(approved, { true, "!482: approved" })
    eq(idle_calls, {})
    eq(nothing, { false, "!482: nothing is held and no verdict was given, so nothing was sent" })
    eq(names(broken_calls), { "diff" })
    eq(unread, {
      false,
      "!482: nothing was sent, because the merge request could not be read again to check the held lines still match it\nglab exited 1\nERROR: 500 Internal Server Error",
    })
    eq(#r.held, 1)
  end)
end)

test("review: while a submit is in flight a second submit, a hold and a discard are each refused, and the first ends as it began", function()
  review_case(function(worktree)
    local adapter, calls = review_adapter(review_answers({ line_comment = HOLD }))
    local r = read_review(worktree)
    review.hold(r, { file = REVIEW_FILE, line = 5 }, "Here.")
    local first
    review.send(r, adapter, { approve = true }, function(ok, message)
      first = { ok, message }
    end)
    vim.wait(1000, function()
      return #calls == 2
    end)
    local second
    review.send(r, adapter, {}, function(ok, message)
      second = { ok, message }
    end)
    local held = { review.hold(r, { file = REVIEW_FILE, line = 6 }, "Another.") }
    local dropped = { review.hold(r, { file = REVIEW_FILE, line = 5 }, "") }
    local discarded = { review.discard(r) }
    calls[2].release(true)
    vim.wait(1000, function()
      return first ~= nil
    end)
    eq(second, { false, "!482: a submit is already in flight; its report comes when it ends" })
    eq(held, { false, "!482: a submit is in flight; nothing is held or dropped until it reports" })
    eq(dropped, held)
    eq(discarded, { false, "!482: a submit is in flight; nothing is discarded until it reports" })
    eq(review.get(worktree, "!482"), r)
    eq(names(calls), { "diff", "line_comment", "submit" })
    eq(first, { true, "!482: posted 1 comment(s), approved" })
  end)
end)

test("review: resolve_thread refuses a thread GitLab does not let be resolved or one resolved already, and marks one resolved only when the client says so", function()
  review_case(function(worktree)
    local adapter, calls = review_adapter(review_answers({
      thread_resolve = function(_, thread)
        if thread == "fails" then
          return false, "glab exited 1\nERROR: 403 Forbidden"
        end
        return true
      end,
    }))
    local r = read_review(worktree)
    local threads = {
      fixed = review_thread("fixed", 3, { resolvable = false }),
      done = review_thread("done", 4, { resolved = true }),
      open = review_thread("open", 5),
      fails = review_thread("fails", 6),
    }
    local answers = {}
    for _, name in ipairs({ "fixed", "done", "open", "fails" }) do
      review.resolve_thread(r, adapter, threads[name], function(ok, message)
        answers[name] = { ok, message }
      end)
    end
    vim.wait(1000, function()
      return answers.open ~= nil and answers.fails ~= nil
    end)
    eq(answers.fixed, { false, "!482: the thread fixed cannot be resolved" })
    eq(answers.done, { false, "!482: the thread done is resolved already" })
    eq(answers.open, { true, "!482: resolved the thread open" })
    eq(answers.fails, { false, "!482: the thread fails was not resolved\nglab exited 1\nERROR: 403 Forbidden" })
    eq(vim.tbl_map(function(call)
      return call.args[2]
    end, calls), { "open", "fails" }, "no call for either refusal")
    eq({ threads.open.resolved, threads.fails.resolved }, { true, false })
  end)
end)

test("review: resolve at the cursor is offered only on a thread GitLab lets be resolved and that is not resolved yet", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_diffview(worktree)
    local adapter, calls = review_adapter(review_answers({
      threads = function()
        return {
          review_thread("open", 12),
          review_thread("fixed", 15, { resolvable = false }),
          review_thread("done", 18, { resolved = true }),
        }
      end,
    }))
    auth.ready = function()
      return adapter
    end
    local notices = stub_notify()
    local r = open_review(worktree, adapter, notices)
    local function resolve_at(line)
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      local before = #notices
      review.resolve()
      vim.wait(1000, function()
        return #notices > before
      end)
      return notices[#notices]
    end
    local at_fixed = resolve_at(15)
    local at_done = resolve_at(18)
    local at_none = resolve_at(10)
    local at_open = resolve_at(12)
    local refusal = "!482: the threads at this line are resolved already, or GitLab does not let them be"
    eq(at_fixed, { message = refusal, level = vim.log.levels.WARN })
    eq(at_done, { message = refusal, level = vim.log.levels.WARN })
    eq(at_none, { message = "!482: no thread is drawn at this line", level = vim.log.levels.WARN })
    eq(at_open, { message = "!482: resolved the thread open", level = vim.log.levels.INFO })
    eq(names(calls), { "diff", "threads", "thread_resolve" })
    eq(calls[3].args, { review_ref(worktree), "open" })
    eq(r.threads[1].resolved, true)
  end)
end)

test("review: decorate draws in the review's namespace, puts a line past the end on the last line, and draws only while the review's tab is current", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_diffview(worktree)
    local adapter = review_adapter(review_answers({
      threads = function()
        return { review_thread("near", 3), review_thread("far", 99) }
      end,
    }))
    local notices = stub_notify()
    local before = vim.api.nvim_get_current_tabpage()
    local r = open_review(worktree, adapter, notices)
    local file = vim.api.nvim_get_current_buf()
    local function rows()
      return vim.tbl_map(function(mark)
        return { mark.row, mark.lines[#mark.lines] }
      end, review_drawn(file))
    end
    local bar = review.BAR
    local opened = rows()
    vim.api.nvim_set_current_tabpage(before)
    review.hold(r, { file = REVIEW_FILE, line = 7 }, "Held away.")
    review.decorate(r)
    local away = rows()
    vim.api.nvim_set_current_tabpage(r.tab)
    review.decorate(r)
    local back = rows()
    eq(opened, { { 2, bar .. "   On near." }, { 19, bar .. "   On far." } })
    eq(away, opened, "nothing is drawn from another tab")
    eq(back, { { 2, bar .. "   On near." }, { 6, bar .. "   Held away." }, { 19, bar .. "   On far." } })
  end)
end)

test("review: comment at the cursor opens a float to write it in, and :w there holds it, closes the float, and sends nothing", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_diffview(worktree)
    local adapter, calls = review_adapter(review_answers())
    local notices = stub_notify()
    local r = open_review(worktree, adapter, notices)
    local diff_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    local compose = vim.api.nvim_get_current_buf()
    local shape = {
      name = vim.api.nvim_buf_get_name(compose),
      buftype = vim.bo[compose].buftype,
      filetype = vim.bo[compose].filetype,
      float = vim.api.nvim_win_get_config(0).relative ~= "",
      lines = vim.api.nvim_buf_get_lines(compose, 0, -1, false),
    }
    compose_write({ "", "Needs a test.", "" })
    local back = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    local again = vim.api.nvim_get_current_buf()
    local prefilled = { vim.api.nvim_buf_get_lines(again, 0, -1, false), vim.bo[again].modified }
    eq(shape, { name = "docket-review://" .. worktree .. "/!482/lua/docket/env.lua:5", buftype = "acwrite", filetype = "markdown", float = true, lines = { "" } })
    eq(vim.api.nvim_buf_is_valid(compose), false, "the buffer is wiped once the comment is held")
    eq(back, diff_win, "and the cursor is back on the diff")
    eq(r.held, { { position = { file = REVIEW_FILE, line = 5 }, text = "Needs a test.", head = DIFF_REFS.head_sha, base = DIFF_REFS.base_sha } })
    eq(notices[#notices], { message = "!482: held at lua/docket/env.lua:5; 1 held, and :Docket review submit sends them", level = vim.log.levels.INFO })
    eq(prefilled, { { "Needs a test." }, false }, "commenting at the same line again starts from what is held")
    eq(names(calls), { "diff", "threads" }, "holding sends nothing")
  end)
end)

test("review: comment refuses a line whose buffer has unsaved changes or whose file differs from HEAD, and opens nothing to write in", function()
  review_case(function(worktree)
    local differs = false
    review_wait(worktree, {
      ["diff --quiet HEAD -- " .. REVIEW_FILE] = function(argv)
        if differs then
          return failed(argv, 1, "")
        end
        return done(argv, "")
      end,
    })
    stub_diffview(worktree)
    local notices = stub_notify()
    open_review(worktree, (review_adapter(review_answers())), notices)
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(file, 0, 1, false, { "typed, not saved" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    local unsaved = notices[#notices]
    vim.cmd("edit!")
    differs = true
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    local changed = notices[#notices]
    eq(unsaved, {
      message = "!482: lua/docket/env.lua has unsaved changes, so its lines are not the merge request's; :e! discards them",
      level = vim.log.levels.ERROR,
    })
    eq(changed, {
      message = ("!482: lua/docket/env.lua differs from HEAD in the worktree, so its lines are not the merge request's; git -C %s stash sets the change aside"):format(worktree),
      level = vim.log.levels.ERROR,
    })
    eq(buffer.named(review.SCHEME .. "!482/lua/docket/env.lua:5"), nil, "no buffer to write it in")
    eq(vim.api.nvim_get_current_buf(), file)
  end)
end)

test("review: a review with two line comments is submitted as one batch: held at :w, nothing sent until submit, then each comment and the approval", function()
  review_case(function(worktree)
    vim.g.loaded_docket = nil
    dofile(PLUGIN)
    review_wait(worktree)
    local calls = stub_run_fast(glab_answer())
    stub_diffview(worktree)
    local notices = stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    vim.cmd("Docket review !482")
    vim.wait(2000, function()
      return review.current() ~= nil
    end)
    local r = review.current()
    local file = vim.api.nvim_get_current_buf()
    vim.wait(1000, function()
      return review_keys_on(file)[1] ~= false
    end)
    local key = vim.api.nvim_replace_termcodes("<leader>dc", true, false, true)
    for _, case in ipairs({ { 3, "First." }, { 7, "Second." } }) do
      vim.api.nvim_win_set_cursor(0, { case[1], 0 })
      vim.api.nvim_feedkeys(key, "x", false)
      compose_write({ case[2] })
    end
    local read = #calls
    local held = vim.tbl_map(function(entry)
      return { entry.position.line, entry.text }
    end, r.held)
    -- The read after the submit replaces the discussions once it lands.
    local threads = r.threads
    vim.cmd("Docket review submit approve")
    vim.wait(2000, function()
      return r.threads ~= threads
    end)
    local function sent(from)
      return vim.tbl_map(function(call)
        return { table.concat(call.argv, " "), call.opts.stdin }
      end, vim.list_slice(calls, from))
    end
    local view = { "glab mr view 482 -F json" }
    local api = { "glab api projects/:id/merge_requests/482" }
    local list_notes = { "glab mr note list 482 -F json" }
    local create = "glab mr note create 482 --file lua/docket/env.lua --line "
    eq(held, { { 3, "First." }, { 7, "Second." } })
    eq(vim.list_slice(sent(1), 1, read), { view, api, list_notes }, "holding sends nothing")
    eq(sent(read + 1), {
      view,
      api,
      { create .. "3", "First.\n" },
      { create .. "7", "Second.\n" },
      { "glab mr approve 482 --sha " .. DIFF_REFS.head_sha },
      view,
      api,
      list_notes,
    }, "the merge request is read again first, and after, for what was posted")
    eq(r.held, {})
    eq(vim.tbl_contains(vim.tbl_map(function(notice)
      return notice.message
    end, notices), "!482: posted 2 comment(s), approved"), true, vim.inspect(notices))
  end)
end)

test("review: an abandoned review sends nothing, drops what it held and its keys, and a read that lands after is refused", function()
  review_case(function(worktree)
    vim.g.loaded_docket = nil
    dofile(PLUGIN)
    review_wait(worktree)
    local calls = stub_run_fast(glab_answer())
    stub_diffview(worktree)
    local notices = stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    vim.cmd("Docket review !482")
    vim.wait(2000, function()
      return review.current() ~= nil
    end)
    local r = review.current()
    local tab, file = r.tab, vim.api.nvim_get_current_buf()
    vim.wait(1000, function()
      return review_keys_on(file)[1] ~= false
    end)
    review.hold(r, { file = REVIEW_FILE, line = 3 }, "First.")
    review.hold(r, { thread = string.rep("2", 40) }, "Agreed.")
    vim.cmd("Docket review abandon")
    local abandoned = notices[#notices]
    local keys_after = review_keys_on(file)
    vim.cmd("Docket review submit")
    local after = notices[#notices]
    vim.wait(50)
    local none = vim.tbl_map(function()
      return false
    end, commands.REVIEW_KEYS)
    eq(abandoned, { message = "!482: abandoned; 2 held comment(s) discarded and nothing sent", level = vim.log.levels.INFO })
    eq(review.get(worktree, "!482"), nil)
    eq(r.held, {})
    eq(vim.api.nvim_tabpage_is_valid(tab), false, "the diff is closed")
    eq(keys_after, none, "and its keys are off the worktree's file")
    eq(after, { message = "no review in this tab; :Docket review <id> opens one", level = vim.log.levels.ERROR })
    eq(vim.tbl_map(function(call)
      return table.concat(call.argv, " ")
    end, calls), { "glab mr view 482 -F json", "glab api projects/:id/merge_requests/482", "glab mr note list 482 -F json" }, "the read that opened it, and nothing after")

    -- A read in flight when a review is abandoned is refused when it lands.
    local late = review.start("glab", "!482", worktree)
    local adapter, adapter_calls = review_adapter(review_answers({ diff = HOLD }))
    local answered
    review.load(late, adapter, function(ok, err)
      answered = { ok, err }
    end)
    review.discard(late)
    adapter_calls[1].release({ source = merge_request().source_branch, target = "main", refs = vim.deepcopy(DIFF_REFS) })
    vim.wait(1000, function()
      return answered ~= nil
    end)
    eq(answered, { false, "the review was abandoned while the merge request was being read; nothing of it is kept" })
    eq({ late.refs, late.threads }, { nil, {} })
  end)
end)

test("review: submit from a tab in another worktree or in no repository is refused before any call, and a summary is written in a buffer whose empty :w sends nothing", function()
  review_case(function(worktree)
    local other = review_worktree()
    review_wait(worktree, {
      ["rev-parse --show-toplevel"] = function(argv, opts)
        local cwd = vim.uv.fs_realpath(opts.cwd) or opts.cwd
        for _, top in ipairs({ worktree, other }) do
          if cwd == top then
            return done(argv, top .. "\n")
          end
        end
        return failed(argv, 128, "fatal: not a git repository (or any of the parent directories): .git\n")
      end,
    })
    stub_diffview(worktree)
    local adapter, calls = review_adapter(review_answers())
    local readied = 0
    auth.ready = function()
      readied = readied + 1
      return adapter
    end
    local notices = stub_notify()
    local r = open_review(worktree, adapter, notices)
    review.hold(r, { file = REVIEW_FILE, line = 5 }, "Here.")
    vim.cmd.tcd(vim.fn.fnameescape(other))
    review.submit({ approve = true })
    local elsewhere = notices[#notices]
    local nowhere = vim.fn.tempname()
    vim.fn.mkdir(nowhere, "p")
    nowhere = vim.uv.fs_realpath(nowhere)
    vim.cmd.tcd(vim.fn.fnameescape(nowhere))
    review.submit({ approve = true })
    local outside = notices[#notices]
    vim.cmd.tcd(vim.fn.fnameescape(worktree))
    local asked = names(calls)
    review.submit({ approve = true, summary = true })
    local summary = vim.api.nvim_get_current_buf()
    local summary_name = vim.api.nvim_buf_get_name(summary)
    vim.cmd.write()
    local empty = notices[#notices]
    local after_empty = { names(calls), readied, vim.api.nvim_buf_is_valid(summary) }
    -- The read after the submit replaces the discussions once it lands.
    local threads = r.threads
    compose_write({ "Ship it." })
    vim.wait(1000, function()
      return r.threads ~= threads
    end)
    eq(elsewhere, {
      message = ("!482: this tab is in %s, not in %s, where the review was opened; :tcd %s and run it again"):format(other, worktree, worktree),
      level = vim.log.levels.ERROR,
    })
    eq(outside, {
      message = ("!482: %s is in no repository, so glab's state check there is not about the host !482 is on; :tcd %s and run it again\ngit exited 128\nfatal: not a git repository (or any of the parent directories): .git\n"):format(
        nowhere,
        worktree
      ),
      level = vim.log.levels.ERROR,
    })
    eq(asked, { "diff", "threads" }, "refused before the state check or any call")
    eq(summary_name, "docket-review://" .. worktree .. "/!482/summary")
    eq(empty, {
      message = "!482: the summary is empty, so nothing was sent; :Docket review submit approve sends the held comments without one",
      level = vim.log.levels.WARN,
    }, "the command named is the one asked for, less the summary")
    eq(after_empty, { { "diff", "threads" }, 0, true })
    eq(names(calls), { "diff", "threads", "diff", "line_comment", "submit", "submit", "diff", "threads" }, "and after the submit the merge request is read again")
    eq({ calls[5].args, calls[6].args }, {
      { review_ref(worktree), { summary = "Ship it." } },
      { review_ref(worktree), { approve = true, head = DIFF_REFS.head_sha } },
    })
    eq(vim.api.nvim_buf_is_valid(summary), false)
    eq(readied, 1)
  end)
end)

test("review: reply is offered on a thread and not on a standalone comment, which individual_note decides", function()
  review_case(function(worktree)
    review_wait(worktree)
    -- A thread of one note and a standalone comment, both on lines: a
    -- note count would call the thread standalone as well.
    local thread = {
      id = string.rep("2", 40),
      individual_note = false,
      notes = { gl_note(3, gl_user("ana", "Ana"), "Why here?", { type = "DiffNote", resolvable = true, resolved = false, position = gl_position(12) }) },
    }
    local standalone = {
      id = string.rep("4", 40),
      individual_note = true,
      notes = { gl_note(7, gl_user("ana", "Ana"), "A remark on this line.", { type = "DiffNote", position = gl_position(15) }) },
    }
    stub_run_fast(function(argv, opts)
      if argv[3] == "note" and argv[4] == "list" then
        return done(argv, { thread, standalone })
      end
      return glab_answer()(argv, opts)
    end)
    stub_diffview(worktree)
    local notices = stub_notify()
    local r = open_review(worktree, nil, notices)
    local file = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 15, 0 })
    review.reply()
    local refused = { notices[#notices], vim.api.nvim_get_current_buf() }
    vim.api.nvim_win_set_cursor(0, { 12, 0 })
    review.reply()
    local compose_name = vim.api.nvim_buf_get_name(0)
    compose_write({ "Agreed." })
    eq(vim.tbl_map(function(t)
      return { t.id, t.individual }
    end, r.threads), { { string.rep("2", 40), false }, { string.rep("4", 40), true } })
    eq(refused, { { message = "!482: no thread at this line takes a reply", level = vim.log.levels.WARN }, file })
    eq(compose_name, "docket-review://" .. worktree .. "/!482/reply/22222222")
    eq(r.held, { { position = { thread = string.rep("2", 40) }, text = "Agreed.", head = DIFF_REFS.head_sha, base = DIFF_REFS.base_sha } })
  end)
end)

test("review: the notes GitLab writes itself are drawn nowhere and counted nowhere", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_run_fast(glab_answer())
    stub_diffview(worktree)
    local notices = stub_notify()
    -- discussions() holds one discussion of a system note alone, and a diff
    -- thread with a system note after its two notes.
    local r = open_review(worktree, nil, notices)
    local bodies = {}
    for _, thread in ipairs(r.threads) do
      for _, note in ipairs(thread.notes) do
        bodies[#bodies + 1] = note.body
      end
    end
    local bar = review.BAR
    eq(notices[1].message:find("!482: 3 discussion(s), 1 on lines of the diff;", 1, true), 1, notices[1].message)
    eq(bodies, { "Repros on staging.", "Why here?", "Because the window sits in it.", "Squash before merging?" })
    eq(review_drawn(vim.api.nvim_get_current_buf()), {
      { row = 11, lines = { bar .. " Ana  unresolved", bar .. "   Why here?", bar .. " Me Myself", bar .. "   Because the window sits in it." } },
    })
  end)
end)

test("commands: :Docket review's verbs reach the review mode, the bang forces a submit, and a malformed review is refused", function()
  review_case(function()
    local ran = {}
    for _, verb in ipairs(commands.REVIEW_VERBS) do
      review[verb] = function(verdict)
        ran[#ran + 1] = { verb, verdict }
      end
    end
    review.open = function(source, id)
      ran[#ran + 1] = { "open", source, id }
    end
    local handed = stub_calls(gh, {
      item = function()
        return nil, nil
      end,
    })
    local waited = stub_acli({ gh = true })
    local notices = stub_notify()
    local function run(bang, ...)
      commands.run({ fargs = { "review", ... }, bang = bang })
    end
    run(false, "comment")
    run(false, "reply")
    run(false, "resolve")
    run(false, "abandon")
    run(false, "submit")
    run(true, "submit", "approve", "summary")
    run(false)
    run(false, "!4", "!5")
    run(false, "comment", "now")
    run(false, "submit", "later")
    run(false, "PROJ-142")
    run(false, "#12")
    vim.wait(1000, function()
      return #handed > 0
    end)
    eq(ran, {
      { "comment" },
      { "reply" },
      { "resolve" },
      { "abandon" },
      { "submit", { force = false } },
      { "submit", { force = true, approve = true, summary = true } },
    })
    eq(notices, vim.tbl_map(function(message)
      return { message = message, level = vim.log.levels.ERROR }
    end, {
      "review takes a merge request such as !482, or one of comment, reply, resolve, submit, abandon",
      "review takes one merge request; got !4 !5",
      "review comment takes nothing more; got now",
      "review submit takes approve and summary; got later",
      "PROJ-142: jira has no review mode; it does not implement diff",
    }))
    eq(vim.tbl_map(function(call)
      return call.argv[1]
    end, waited), { "gh" }, "acli is not asked about a ticket the review mode cannot take; gh is, for the pull request")
    eq(handed[1].args, { "#12" }, "a pull request goes to octo.nvim, as :Docket #12 sends it")
  end)
end)

test("commands: completion offers the review's verbs after review, the verdict's words after submit, and nothing after an identifier", function()
  eq(commands.complete("", "Docket review "), commands.REVIEW_VERBS)
  eq(commands.complete("s", "Docket review s"), { "submit" })
  eq(commands.complete("", "Docket! review submit "), commands.SUBMIT_WORDS)
  eq(commands.complete("s", "Docket review submit approve s"), { "summary" })
  eq(commands.complete("", "Docket review !482 "), {})
  eq(commands.complete("", "Docket review comment "), {})
end)

test("commands: a review's keys are set on the buffers that show its diff and on no other, and come off when its tab closes", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_run_fast(glab_answer())
    stub_diffview(worktree)
    stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    local r = commands.review_open("!482")
    vim.wait(2000, function()
      return r.tab ~= nil
    end)
    local file = vim.api.nvim_get_current_buf()
    -- A window in the review's tab that shows no side of the diff.
    vim.cmd("belowright new")
    local other = vim.api.nvim_get_current_buf()
    local descriptions = vim.tbl_map(function(key)
      return key.desc
    end, commands.REVIEW_KEYS)
    local none = vim.tbl_map(function()
      return false
    end, commands.REVIEW_KEYS)
    vim.wait(1000, function()
      return vim.deep_equal(review_keys_on(file), descriptions)
    end)
    -- The keying the new window's BufWinEnter scheduled runs here.
    vim.wait(50)
    local on_file, on_other = review_keys_on(file), review_keys_on(other)
    local global = vim.tbl_filter(function(map)
      return vim.tbl_contains(descriptions, map.desc)
    end, vim.api.nvim_get_keymap("n"))
    vim.cmd.tabclose()
    local after = review_keys_on(file)
    vim.api.nvim_buf_delete(other, { force = true })
    eq(on_file, descriptions)
    eq(on_other, none)
    eq(global, {}, "none is global")
    eq(after, none, "the worktree's file keeps none of them once the review's tab is gone")
  end)
end)

test("commands: R on a merge request row lands in the review mode, in the tab the launcher opens away from tmux and through the command its tmux window runs", function()
  review_case(function(worktree)
    vim.g.loaded_docket = nil
    dofile(PLUGIN)
    local branch = merge_request().source_branch
    list.row_at = function()
      return { source = "glab", id = "!482", branch = branch }, {}
    end
    list.state = function()
      return { root = "/w/repo", binding = { kind = "projects", projects = { "PROJ" } } }
    end
    vim.api.nvim_echo = function() end
    vim.cmd.redraw = function() end
    local opened = {}
    review.open = function(source, id)
      opened[#opened + 1] = { source = source, id = id, cwd = vim.uv.fs_realpath(vim.fn.getcwd()) }
    end
    local tmux = {}
    stub_wait(function(argv)
      if argv[1] == "git" and argv[2] == "worktree" then
        return done(argv, ("worktree /w/repo/.bare\nbare\n\nworktree %s\nbranch refs/heads/%s\n\n"):format(worktree, branch))
      end
      if argv[1] == "tmux" then
        tmux[#tmux + 1] = argv
        if argv[2] == "list-windows" then
          return done(argv, listing({ "dash", env.window_name(branch), env.window_name(branch) .. "-sh" }))
        end
        return done(argv, "")
      end
      return failed(argv, 1, "unexpected: " .. table.concat(argv, " "))
    end)
    local notices = stub_notify()
    vim.env.TMUX = nil
    commands.review_row(0)
    local away = vim.deepcopy(opened)
    vim.env.TMUX = "/tmp/tmux-1/default,1,0"
    commands.review_row(0)
    -- The editor window's `nvim -c <command>` runs that command once the
    -- plugin has declared `:Docket`, which is what running it here does.
    local window = tmux[1]
    vim.cmd(window[#window])
    eq(away, { { source = "glab", id = "!482", cwd = worktree } }, "the tab at the worktree opens the review")
    eq(notices[1].level, vim.log.levels.INFO, "and the launcher reports no warning: " .. notices[1].message)
    eq(vim.list_slice(window, #window - 2), { "nvim", "-c", "Docket review !482" })
    eq({ opened[2].source, opened[2].id }, { "glab", "!482" }, "the tmux window's command opens it too")
  end)
end)

-- An open review of !482 in its own tab, from open_review(), with every
-- state check answered by `adapter`.
local function opened_review(worktree, answers, notices)
  review_wait(worktree, answers)
  stub_diffview(worktree)
  local adapter, calls = review_adapter(review_answers())
  auth.ready = function()
    return adapter
  end
  local r = open_review(worktree, adapter, notices)
  return r, adapter, calls
end

-- The messages at one level, in order.
local function at_level(notices, level)
  local found = {}
  for _, notice in ipairs(notices) do
    if notice.level == level then
      found[#found + 1] = notice.message
    end
  end
  return found
end

test("review: a review abandoned while the read after its submit runs reports the abandon and no failed read", function()
  review_case(function(worktree)
    local notices = stub_notify()
    local r, adapter = opened_review(worktree, nil, notices)
    review.hold(r, { thread = "t1" }, "Agreed.")
    local held_read
    adapter.diff = function(_, on_done)
      held_read = on_done
    end
    review.submit({})
    vim.wait(1000, function()
      return held_read ~= nil
    end)
    review.abandon()
    held_read({ source = merge_request().source_branch, target = "main", refs = vim.deepcopy(DIFF_REFS) })
    vim.wait(100)
    eq(held_read ~= nil, true, "the submit read the merge request again")
    eq(at_level(notices, vim.log.levels.WARN), {})
    eq(at_level(notices, vim.log.levels.INFO), {
      "!482: 0 discussion(s), 0 on lines of the diff; 0 comment(s) held. :Docket review comment holds one at the cursor, and :Docket review submit sends them.",
      "!482: posted 1 comment(s)",
      "!482: abandoned; 0 held comment(s) discarded and nothing sent",
    })
  end)
end)

test("review: a summary posted before its approval failed closes its buffer and names the approval alone, so no :w posts it twice", function()
  review_case(function(worktree)
    local notices = stub_notify()
    local r, adapter, calls = opened_review(worktree, nil, notices)
    local submits = {}
    adapter.submit = function(ref, verdict, on_done)
      submits[#submits + 1] = { ref = ref, verdict = verdict }
      vim.schedule(function()
        if verdict.approve then
          return on_done(false, "glab exited 1\nERROR: 401 Unauthorized")
        end
        on_done(true)
      end)
    end
    review.submit({ approve = true, summary = true })
    local summary = vim.api.nvim_get_current_buf()
    compose_write({ "Ship it." })
    vim.wait(1000, function()
      return #at_level(notices, vim.log.levels.ERROR) > 0 and #calls >= 4
    end)
    eq(vim.tbl_map(function(call)
      return call.verdict
    end, submits), { { summary = "Ship it." }, { approve = true, head = DIFF_REFS.head_sha } })
    eq(vim.api.nvim_buf_is_valid(summary), false, "the summary's buffer is gone, so no :w posts it again")
    eq(at_level(notices, vim.log.levels.ERROR), {
      "!482: the summary posted; the approval was not. :Docket review submit approve approves alone\nglab exited 1\nERROR: 401 Unauthorized",
    })
    eq(names(calls), { "diff", "threads", "diff", "threads" }, "the merge request is read again for the summary")
    eq(r.held, {})
  end)
end)

test("review: the summary's window says :w submits the review, a comment's that :w keeps it, and an empty summary names the command asked for", function()
  review_case(function(worktree)
    local notices = stub_notify()
    opened_review(worktree, nil, notices)
    review.submit({ force = true, approve = true, summary = true })
    local summary_title = vim.api.nvim_win_get_config(0).title
    vim.cmd.write()
    local empty = notices[#notices]
    vim.cmd("close")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    local comment_title = vim.api.nvim_win_get_config(0).title
    eq(summary_title, { { " !482/summary  :w submits the review " } })
    eq(comment_title, { { " !482/lua/docket/env.lua:5  :w keeps it " } })
    eq(empty, {
      message = "!482: the summary is empty, so nothing was sent; :Docket! review submit approve sends the held comments without one",
      level = vim.log.levels.WARN,
    })
  end)
end)

test("review: a draft closed with :q is there at the next comment on that line, and one discarded with :q! reopens with the held text", function()
  review_case(function(worktree)
    local notices = stub_notify()
    local r = opened_review(worktree, nil, notices)
    local file_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    review.comment()
    compose_write({ "Held." })
    vim.api.nvim_set_current_win(file_win)
    review.comment()
    local compose = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(compose, 0, -1, false, { "Draft." })
    vim.cmd("q")
    vim.api.nvim_set_current_win(file_win)
    review.comment()
    local kept = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.cmd("q!")
    vim.api.nvim_set_current_win(file_win)
    review.comment()
    local reopened = { vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.bo.modified }
    vim.cmd.write()
    eq(kept, { "Draft." })
    eq(reopened, { { "Held." }, false }, "the held comment's text, not an empty buffer")
    eq(vim.tbl_map(function(entry)
      return entry.text
    end, r.held), { "Held." }, "and its :w keeps it rather than dropping it")
  end)
end)

test("review: the reviews of one merge request number in two worktrees draft their summaries in two buffers", function()
  review_case(function(worktree)
    local other = review_worktree()
    local here = review.start("glab", "!482", worktree)
    local there = review.start("glab", "!482", other)
    local first = review.compose(here, { kind = "summary" }, nil)
    vim.api.nvim_buf_set_lines(first, 0, -1, false, { "Summary for the first." })
    vim.cmd("q")
    local second = review.compose(there, { kind = "summary" }, nil)
    local shown = vim.api.nvim_buf_get_lines(second, 0, -1, false)
    vim.cmd("q")
    review.discard(here)
    local after = { vim.api.nvim_buf_is_valid(first), vim.api.nvim_buf_is_valid(second) }
    review.discard(there)
    eq(first ~= second, true, "two buffers")
    eq(shown, { "" }, "the second shows none of the first's draft")
    eq(after, { false, true }, "abandoning one leaves the other's")
  end)
end)

test("review: comment on diffview's old side holds an old-side position, and a line outside the diff's hunks is refused on either side", function()
  review_case(function(worktree)
    local notices = stub_notify()
    local hunk = table.concat({ "diff --git a/x b/x", "@@ -10,2 +11,3 @@ function M.run()", " kept", "+added", " kept", "" }, "\n")
    local r, _, calls = opened_review(worktree, {
      ["diff -U3 --no-color " .. DIFF_REFS.base_sha .. " HEAD -- " .. REVIEW_FILE] = function(argv)
        return done(argv, hunk)
      end,
    }, notices)
    local file = vim.api.nvim_get_current_buf()
    local file_win = vim.api.nvim_get_current_win()
    vim.cmd("leftabove vnew")
    local old_side = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(old_side, 0, -1, false, vim.fn["repeat"]({ "old" }, 20))
    vim.bo[old_side].buftype = "nofile"
    local old_win = vim.api.nvim_get_current_win()
    package.loaded["diffview.lib"] = {
      get_current_view = function()
        return {
          tabpage = r.tab,
          cur_entry = { path = REVIEW_FILE },
          cur_layout = { a = { file = { bufnr = old_side } }, b = { file = { bufnr = file } } },
        }
      end,
    }
    vim.api.nvim_win_set_cursor(old_win, { 11, 0 })
    review.comment()
    compose_write({ "Why was this removed?" })
    vim.api.nvim_set_current_win(old_win)
    vim.api.nvim_win_set_cursor(old_win, { 12, 0 })
    review.comment()
    local old_outside = { notices[#notices], vim.api.nvim_get_current_buf() }
    vim.api.nvim_set_current_win(file_win)
    vim.api.nvim_win_set_cursor(file_win, { 13, 0 })
    review.comment()
    compose_write({ "Inside." })
    vim.api.nvim_set_current_win(file_win)
    vim.api.nvim_win_set_cursor(file_win, { 14, 0 })
    review.comment()
    local new_outside = { notices[#notices], vim.api.nvim_get_current_buf() }
    eq(vim.tbl_map(function(entry)
      return entry.position
    end, r.held), { { file = REVIEW_FILE, old_line = 11 }, { file = REVIEW_FILE, line = 13 } })
    eq(old_outside, {
      {
        message = "!482: line 12 of " .. REVIEW_FILE .. " on the old side is not in the merge request's diff, and glab refuses a comment on a line the diff does not show; comment on a changed line or one within 3 lines of it",
        level = vim.log.levels.ERROR,
      },
      old_side,
    })
    eq(new_outside, {
      {
        message = "!482: line 14 of " .. REVIEW_FILE .. " is not in the merge request's diff, and glab refuses a comment on a line the diff does not show; comment on a changed line or one within 3 lines of it",
        level = vim.log.levels.ERROR,
      },
      file,
    })
    eq(names(calls), { "diff", "threads" }, "holding sends nothing")
  end)
end)

test("review: a held old-side comment is not sent when the merge base has moved, and the check reads the merge request for it", function()
  review_case(function(worktree)
    local moved = vim.tbl_extend("force", DIFF_REFS, { base_sha = ("e"):rep(40) })
    local adapter, calls = review_adapter(review_answers({
      diff = function()
        return { source = merge_request().source_branch, target = "main", refs = moved }
      end,
    }))
    local r = read_review(worktree)
    review.hold(r, { file = REVIEW_FILE, old_line = 2 }, "Gone.")
    local refused = send_and_wait(r, adapter, {})
    eq(names(calls), { "diff" })
    eq(refused[1], false)
    eq(#r.held, 1)
  end)
end)

test("review: a discussion placed on another version of the diff is drawn at no line and counted apart", function()
  review_case(function(worktree)
    local current = review_thread("t1", 4, { position = { new_path = REVIEW_FILE, new_line = 4, head_sha = DIFF_REFS.head_sha } })
    local outdated = review_thread("t2", 6, { position = { new_path = REVIEW_FILE, new_line = 6, head_sha = ("9"):rep(40) } })
    local loc = { path = REVIEW_FILE, side = review.NEW, head = DIFF_REFS.head_sha }
    eq(vim.tbl_map(function(mark)
      return mark.line
    end, review.marks({ current, outdated }, {}, loc)), { 4 })
    eq(review.threads_at({ threads = { current, outdated } }, loc, 6), {}, "so it is offered for no reply or resolve")
    local notices = stub_notify()
    review_wait(worktree)
    stub_diffview(worktree)
    local adapter = review_adapter(review_answers({
      threads = function()
        return { current, outdated }
      end,
    }))
    open_review(worktree, adapter, notices)
    eq(notices[#notices].message:match("^[^;]+"), "!482: 2 discussion(s), 1 on lines of the diff, 1 on another version of it")
  end)
end)

test("commands: taking a review's keys off leaves a buffer's own maps, abandoning takes them off when the diff keeps its tab, and closing the tab does whatever order its autocommands run in", function()
  review_case(function(worktree)
    review_wait(worktree)
    stub_run_fast(glab_answer())
    stub_diffview(worktree)
    stub_notify()
    local none = vim.tbl_map(function()
      return false
    end, commands.REVIEW_KEYS)
    -- review.lua's own TabClosed clears the review's tab before commands.lua's
    -- runs when it was made first, which is not the order in a fresh editor.
    -- It is taken out while the tab closes and put back after.
    local theirs = vim.api.nvim_get_autocmds({ group = "docket/review", event = "TabClosed" })
    vim.api.nvim_clear_autocmds({ group = "docket/review", event = "TabClosed" })
    local ok, err = pcall(function()
      vim.cmd.cd(vim.fn.fnameescape(worktree))
      local r = commands.review_open("!482")
      vim.wait(2000, function()
        return r.tab ~= nil
      end)
      local file = vim.api.nvim_get_current_buf()
      vim.keymap.set("n", "<leader>dq", "<Nop>", { buffer = file, desc = "a map of the buffer's own" })
      vim.wait(1000, function()
        return review_keys_on(file)[1] ~= false
      end)
      vim.cmd.tabclose()
      local own = vim.api.nvim_buf_call(file, function()
        return vim.fn.maparg("<leader>dq", "n", false, true).desc
      end)
      eq(review_keys_on(file), none, "the review's keys are off once its tab closes")
      eq(own, "a map of the buffer's own", "and the buffer's own map is not")
      pcall(vim.keymap.del, "n", "<leader>dq", { buffer = file })
      review.discard(r)

      -- A diff that `:DiffviewClose` leaves open keeps its tab.
      vim.api.nvim_create_user_command("DiffviewClose", function() end, { force = true })
      r = commands.review_open("!482")
      vim.wait(2000, function()
        return r.tab ~= nil
      end)
      file = vim.api.nvim_get_current_buf()
      vim.wait(1000, function()
        return review_keys_on(file)[1] ~= false
      end)
      local tab = r.tab
      commands.review_verb("abandon", {}, false)
      eq(vim.api.nvim_tabpage_is_valid(tab), true, "the diff kept its tab")
      eq(review_keys_on(file), none, "abandoning takes the keys off a diff whose tab stays")
    end)
    for _, autocmd in ipairs(theirs) do
      vim.api.nvim_create_autocmd("TabClosed", { group = "docket/review", callback = autocmd.callback })
    end
    assert(ok, err)
  end)
end)

test("commands: g? in a review's diff lists its keys, the approving submit and diffview's help; a compose window's lists :w and :q!; a refused comment, diffview reopening a file and the tab closing each leave it right", function()
  review_case(function(worktree)
    -- The diff shows new lines 11 to 13, so a comment is refused on line 1.
    local hunk = table.concat({ "diff --git a/x b/x", "@@ -10,2 +11,3 @@ function M.run()", " kept", "+added", " kept", "" }, "\n")
    review_wait(worktree, {
      ["diff -U3 --no-color " .. DIFF_REFS.base_sha .. " HEAD -- " .. REVIEW_FILE] = function(argv)
        return done(argv, hunk)
      end,
    })
    stub_run_fast(glab_answer())
    stub_diffview(worktree)
    stub_notify()
    vim.cmd.cd(vim.fn.fnameescape(worktree))
    local r = commands.review_open("!482")
    vim.wait(2000, function()
      return r.tab ~= nil
    end)
    local file, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.wait(1000, function()
      return buffer_map(file, "g?").buffer == 1
    end)
    local text = lists_every_map(file, "a review's diff", commands.DIFFVIEW_HELP)
    eq(listed_as(text, ":Docket review submit approve"), "Docket: submit the held comments, then approve")
    eq(listed_as(text, ":Docket review abandon"), "Docket: discard every held comment and close the diff")
    eq(commands.DIFFVIEW_HELP:find(":help diffview-maps", 1, true) ~= nil, true, "the list names where diffview's keys are")

    -- A comment refused opens no window, and the diff's g? stays the review's.
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    local refused = stub_notify()
    buffer_map(file, "<leader>dc").callback()
    eq(drained(), true)
    eq(refused[#refused].message:find("is not in the merge request's diff", 1, true) ~= nil, true, vim.inspect(refused))
    eq(vim.api.nvim_get_current_buf(), file, "no compose window opened")
    eq(listed_as(keys_reported(file), ":Docket review submit approve") ~= nil, true, "the diff's g? is the review's")

    -- A compose window gets a g? of its own.
    vim.api.nvim_win_set_cursor(win, { 12, 0 })
    buffer_map(file, "<leader>dc").callback()
    local compose = vim.api.nvim_get_current_buf()
    eq(vim.startswith(vim.api.nvim_buf_get_name(compose), review.SCHEME), true, vim.api.nvim_buf_get_name(compose))
    text = keys_reported(compose)
    eq(listed_as(text, ":w"), "Docket: hold the comment; in a summary's window, submit the review")
    eq(listed_as(text, ":q!"), "Docket: close the window and discard the text")
    vim.api.nvim_win_close(0, true)
    eq(drained(), true)

    -- diffview reopening the file sets its own g? again and fires its event;
    -- the review's is back once the schedule has run.
    vim.keymap.set("n", "g?", "<Nop>", { buffer = file, desc = "diffview: open the help panel" })
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffviewDiffBufWinEnter" })
    local inside = buffer_map(file, "g?").desc
    eq(drained(), true)
    eq(inside, "diffview: open the help panel", "the event runs before the keying")
    eq(listed_as(keys_reported(file), ":Docket review submit approve") ~= nil, true, "the review's g? after the reopen")

    vim.cmd.tabclose()
    eq(buffer_map(file, "g?").buffer, nil, "the worktree's file keeps no g? once the review's tab is gone")
  end)
end)

-- one merge request number in two clones ------------------------------------------------

-- The editor as two clones of one project see it: `vim.fn.getcwd()` answers
-- whichever clone `enter` last named, and entering runs glab's state check
-- there, as every mode's entry does. spawn.run records each glab call with
-- the directory it ran in and holds it until `answer` hands it a payload.
-- `body` runs under pcall, so the editor is put back whatever it raised.
local function two_clones(body)
  glab.forget()
  local cwd, saved_getcwd = "/w/a", vim.fn.getcwd
  vim.fn.getcwd = function()
    return cwd
  end
  local _, restore_wait = stub_wait(function(argv)
    return done(argv, "")
  end)
  local pending, ran, saved_run = {}, {}, spawn.run
  spawn.run = function(argv, opts, on_done)
    local call = { argv = argv, cwd = opts and opts.cwd, on_done = on_done }
    pending[#pending + 1] = call
    ran[#ran + 1] = call
  end
  local clones = {
    enter = function(dir)
      cwd = dir
      glab.auth_status()
    end,
    answer = function(payload)
      local call = table.remove(pending, 1)
      call.on_done(done(call.argv, payload))
      return call
    end,
    pending = pending,
    ran = ran,
  }
  local ok, err = pcall(body, clones)
  spawn.run = saved_run
  vim.fn.getcwd = saved_getcwd
  restore_wait()
  glab.forget()
  assert(ok, err)
end

-- Each call as `glab <verb words>` beside the directory it ran in.
local function where_ran(calls)
  return vim.tbl_map(function(call)
    return { table.concat(call.argv, " ", 1, math.min(#call.argv, 5)), call.cwd }
  end, calls)
end

test("review: every call a submit, a read and a resolve make runs in the review's worktree, whatever clone a state check names meanwhile", function()
  two_clones(function(clones)
    clones.enter("/w/a")
    local r = review.start("glab", "!482", "/w/a")
    r.held = {
      { position = { thread = ("1"):rep(40) }, text = "One." },
      { position = { thread = ("2"):rep(40) }, text = "Two." },
      { position = { thread = ("3"):rep(40) }, text = "Three." },
    }
    local reported
    review.send(r, glab, { approve = true, summary = "Done." }, function(ok, message)
      reported = { ok, message }
    end)
    -- A tab in the other clone runs the state check before each answer.
    while #clones.pending > 0 do
      clones.enter("/w/b")
      clones.answer("")
    end
    eq(reported and reported[1], true, reported and reported[2])
    eq(where_ran(clones.ran), {
      { "glab mr note create 482", "/w/a" },
      { "glab mr note create 482", "/w/a" },
      { "glab mr note create 482", "/w/a" },
      { "glab mr note create 482", "/w/a" },
      { "glab mr approve 482", "/w/a" },
    })

    for index = #clones.ran, 1, -1 do
      clones.ran[index] = nil
    end
    clones.enter("/w/a")
    local loaded
    review.load(r, glab, function(ok, err)
      loaded = { ok, err }
    end)
    clones.enter("/w/b")
    clones.answer(merge_request())
    clones.enter("/w/b")
    clones.answer(vim.tbl_extend("force", merge_request(), { diff_refs = DIFF_REFS }))
    clones.enter("/w/b")
    clones.answer(discussions())
    eq(loaded, { true }, "the read answered")
    clones.enter("/w/b")
    review.resolve_thread(r, glab, { id = ("2"):rep(40), resolvable = true, resolved = false }, function() end)
    clones.answer("")
    eq(where_ran(clones.ran), {
      { "glab mr view 482 -F", "/w/a" },
      { "glab api projects/:id/merge_requests/482", "/w/a" },
      { "glab mr note list 482", "/w/a" },
      { "glab mr note resolve 482", "/w/a" },
    })
    review.discard(r)
  end)
end)

test("buffer: an item buffer's saves, state changes and assignments, and the reads around them, go to the clone it was opened in; opening it from another clone moves it there", function()
  -- Both clones are of one project, so the two opens name one buffer.
  local restore_clone = stub_clone(nil, "git@gitlab.example.test:acme/payments.git")
  two_clones(function(clones)
    local previous = buffer.named(buffer.name("glab", "!482", "acme/payments"))
    if previous then
      vim.api.nvim_buf_delete(previous, { force = true })
    end
    local _, restore_notify = stub_notify()
    -- The last action a merge request offers, Close, and nobody to assign.
    local _, restore_select = stub_select(function(items)
      for _, choice in ipairs(items) do
        if choice.who == adapters.NOBODY then
          return choice
        end
      end
      return items[#items]
    end)
    -- Answers every call as glab_answer() would, in the order they come,
    -- until the editor has nothing left to schedule.
    local function drain()
      for _ = 1, 50 do
        if #clones.pending > 0 then
          local call = clones.pending[1]
          local stdout = glab_answer()(call.argv, {}).stdout
          clones.answer(vim.json.decode(stdout ~= "" and stdout or '""'))
        end
        vim.wait(5)
      end
    end
    local ok, err = pcall(function()
      clones.enter("/w/a")
      local buf = buffer.open("glab", "!482", nil, glab)
      drain()
      clones.enter("/w/b")
      local from = #clones.ran + 1
      buffer.compose(buf)
      local row = vim.api.nvim_buf_line_count(buf) - 1
      vim.api.nvim_buf_set_text(buf, row, 0, row, 0, { "Posted from the first clone." })
      buffer.write(buf)
      drain()
      local body = vim.fn.search("Digests come from the tap.", "nw")
      vim.api.nvim_buf_set_text(buf, body - 1, 0, body - 1, 0, { "Edited. " })
      buffer.write(buf)
      drain()
      commands.transition(buf)
      drain()
      commands.assign(buf)
      drain()
      local ran = where_ran(vim.list_slice(clones.ran, from))
      local verbs = vim.tbl_map(function(entry)
        return entry[1]
      end, ran)
      for _, verb in ipairs({ "glab mr note create 482", "glab mr update 482 --description-file", "glab mr close 482", "glab mr update 482 --unassign" }) do
        eq(vim.tbl_contains(verbs, verb), true, verb .. " ran: " .. vim.inspect(verbs))
      end
      for _, entry in ipairs(ran) do
        eq(entry[2], "/w/a", entry[1])
      end

      clones.enter("/w/b")
      from = #clones.ran + 1
      buffer.open("glab", "!482", nil, glab)
      drain()
      local reopened = where_ran(vim.list_slice(clones.ran, from))
      eq(#reopened > 0, true, "the open read the merge request")
      for _, entry in ipairs(reopened) do
        eq(entry[2], "/w/b", entry[1])
      end
      from = #clones.ran + 1
      commands.transition(buf)
      drain()
      eq(where_ran(vim.list_slice(clones.ran, from))[1], { "glab mr view 482 -F", "/w/b" }, "later calls follow the open")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    restore_select()
    restore_notify()
    restore_clone()
    assert(ok, err)
  end)
end)

-- The address of a project's !482, as its `web_url` carries it.
local function address(project)
  return ("https://gitlab.example.test/%s/-/merge_requests/482"):format(project)
end

test("buffer: !482 opened from clones of two projects is two buffers, :e in one reads it from its own clone, and a read that cannot tell the project is refused", function()
  vim.g.loaded_docket = nil
  dofile(PLUGIN)
  -- /w/a and /w/c are clones of one project, /w/b of another, and anywhere
  -- else is no clone.
  local origins = {
    ["/w/a"] = "git@gitlab.example.test:acme/payments.git",
    ["/w/b"] = "git@gitlab.example.test:acme/other.git",
    ["/w/c"] = "https://gitlab.example.test/acme/payments.git",
  }
  local saved = { root = repo.root, remote_url = repo.remote_url }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  local ok, err = pcall(two_clones, function(clones)
    for _, project in ipairs({ "acme/payments", "acme/other" }) do
      local previous = buffer.named(buffer.name("glab", "!482", project))
      if previous then
        vim.api.nvim_buf_delete(previous, { force = true })
      end
    end
    local notices, restore_notify = stub_notify()
    -- Answers every call as glab_answer() would, with the address of the
    -- project the call's clone is of, until none is left.
    local function drain()
      for _ = 1, 50 do
        if #clones.pending > 0 then
          local call = clones.pending[1]
          local web_url = address(call.cwd == "/w/b" and "acme/other" or "acme/payments")
          local stdout = glab_answer({ web_url = web_url })(call.argv, {}).stdout
          clones.answer(vim.json.decode(stdout ~= "" and stdout or '""'))
        end
        vim.wait(5)
      end
    end
    local inner_ok, inner_err = pcall(function()
      clones.enter("/w/a")
      local first = buffer.open("glab", "!482")
      drain()
      clones.enter("/w/b")
      local second = buffer.open("glab", "!482")
      drain()
      eq(
        { vim.api.nvim_buf_get_name(first), vim.api.nvim_buf_get_name(second) },
        { "docket://glab/acme/payments/!482", "docket://glab/acme/other/!482" },
        "two buffers, each named for its project"
      )
      eq({ vim.b[first].docket.project, vim.b[second].docket.project }, { "acme/payments", "acme/other" })

      -- gx opens the address the buffer's own read answered. The adapter
      -- keeps one address per number, the last read's, which is the other
      -- project's for the first buffer.
      eq(glab.url({ id = "!482" }), address("acme/other"), "the adapter alone answers the last read's address")
      local opened, saved_open = {}, vim.ui.open
      vim.ui.open = function(url)
        opened[#opened + 1] = url
        return nil, nil
      end
      commands.browse(first)
      commands.browse(second)
      vim.ui.open = saved_open
      eq(opened, { address("acme/payments"), address("acme/other") }, "each buffer opens its own project's merge request")

      -- :e in the first, from a tab in the other project's clone.
      vim.api.nvim_set_current_buf(first)
      local from = #clones.ran + 1
      vim.cmd("edit")
      drain()
      local reread = where_ran(vim.list_slice(clones.ran, from))
      eq(#reread > 0, true, ":e read the merge request")
      for _, entry in ipairs(reread) do
        eq(entry[2], "/w/a", entry[1])
      end
      eq(vim.api.nvim_buf_get_lines(first, 1, 2, false), { "# Bump the pinned acli" })

      -- With no reference to go by, a read from another project's clone is
      -- refused, and one from a clone of the buffer's project goes ahead.
      vim.b[first].docket = nil
      from = #clones.ran + 1
      local shown = #notices
      vim.cmd("edit")
      vim.wait(50)
      eq(#clones.ran, from - 1, "nothing ran")
      eq(vim.list_slice(notices, shown + 1), {
        {
          message = "docket://glab/acme/payments/!482: the editor is in a clone of acme/other, whose !482 is another; :e reads this one from a clone of acme/payments",
          level = vim.log.levels.ERROR,
        },
      })
      clones.enter("/w/c")
      vim.cmd("edit")
      eq(where_ran({ clones.pending[1] }), { { "glab mr view 482 -F", "/w/c" } }, "read in the clone the editor is in")
      drain()
      eq(vim.b[first].docket.ref.cwd, "/w/c")

      -- A name that carries no project.
      local bare = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(bare, "docket://glab/!482")
      local read
      from = #clones.ran + 1
      buffer.read(bare, function(read_ok, message)
        read = { read_ok, message }
      end)
      eq(read, {
        false,
        "docket://glab/!482 names no project, and glab numbers its items within one; :Docket !482 opens it from a clone of its project",
      })
      eq(#clones.ran, from - 1, "nothing ran")
      vim.api.nvim_buf_delete(bare, { force = true })

      -- Outside any clone nothing opens, and the message says what to do
      -- before git's own words, which end in a newline.
      clones.enter("/elsewhere")
      local outside
      eq(buffer.open("glab", "!482", function(open_ok, message)
        outside = { open_ok, message }
      end), nil)
      eq(outside, {
        false,
        "!482: glab numbers its items within a project, and the editor's directory names none; :tcd into a clone of the project and run :Docket !482 again\nfatal: not a git repository",
      })
      eq(#clones.ran, from - 1, "nothing ran")

      -- The same for :e with no reference to go by, in the same shape.
      vim.b[first].docket = nil
      vim.api.nvim_set_current_buf(first)
      shown = #notices
      vim.cmd("edit")
      vim.wait(50)
      eq(#clones.ran, from - 1, "nothing ran")
      eq(vim.list_slice(notices, shown + 1), {
        {
          message = "docket://glab/acme/payments/!482: :e reads it only from a clone of acme/payments, and the editor's directory names no project; :tcd into a clone of acme/payments and :e again\nfatal: not a git repository",
          level = vim.log.levels.ERROR,
        },
      })
      vim.api.nvim_buf_delete(first, { force = true })
      vim.api.nvim_buf_delete(second, { force = true })
    end)
    restore_notify()
    assert(inner_ok, inner_err)
  end)
  repo.root, repo.remote_url = saved.root, saved.remote_url
  assert(ok, err)
end)

test("glab: an item carries the project its address names, subgroups included, and none for an address of another shape", function()
  eq(glab.project_of(address("acme/payments")), "acme/payments")
  eq(glab.project_of(address("acme/sub/deeper/payments")), "acme/sub/deeper/payments", "a subgroup's slashes stay in the path")
  eq(glab.project_of("http://gitlab.example.test:8080/acme/payments/-/merge_requests/7#note_3"), "acme/payments", "a port and a fragment are not the path")
  eq(glab.project_of("https://gitlab.example.test/acme/payments/merge_requests/482"), nil, "an address without the /-/ is not read")
  eq(glab.project_of("https://gitlab.example.test/acme/payments"), nil)
  eq(glab.project_of("https://gitlab.example.test/-/merge_requests/482"), nil, "nor one with no path before it")
  eq(glab.project_of("https://gitlab.example.test//-/merge_requests/482"), nil, "nor one whose path is empty")
  eq(glab.project_of(vim.NIL), nil, "a payload with `web_url` null")
  eq(glab.project_of(nil), nil, "or without one")

  glab.forget()
  local read = {}
  for _, web_url in ipairs({ address("acme/sub/payments"), "https://gitlab.example.test/acme/payments/merge_requests/482" }) do
    local _, restore_run = stub_glab({ web_url = web_url })
    glab.item("!482", function(it, err)
      read[#read + 1] = { it and it.project, err, it and it.url }
    end)
    restore_run()
  end
  eq(read, {
    { "acme/sub/payments", nil, address("acme/sub/payments") },
    { nil, nil, "https://gitlab.example.test/acme/payments/merge_requests/482" },
  }, "the item carries the project where the address names one, and the address itself either way")
end)

test("buffer: an answer naming another project than the name is refused with nothing filled; one naming the name's project, in either case, or none, fills", function()
  -- Each directory is a clone whose origin names the project the name is
  -- read off; glab's answer names whatever the test hands it.
  local origins = {
    ["/w/fork"] = "git@gitlab.example.test:me/payments.git",
    ["/w/a"] = "git@gitlab.example.test:acme/payments.git",
    ["/w/sub"] = "git@gitlab.example.test:acme/sub/payments.git",
    ["/w/cased"] = "git@gitlab.example.test:Acme/Payments.git",
  }
  local saved = { root = repo.root, remote_url = repo.remote_url }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  local ok, err = pcall(two_clones, function(clones)
    for _, project in ipairs({ "me/payments", "acme/payments", "acme/sub/payments", "Acme/Payments" }) do
      local previous = buffer.named(buffer.name("glab", "!482", project))
      if previous then
        vim.api.nvim_buf_delete(previous, { force = true })
      end
    end
    local notices, restore_notify = stub_notify()
    -- Answers every call as glab_answer() would, the view with `web_url`,
    -- until none is left.
    local function drain(web_url)
      for _ = 1, 50 do
        if #clones.pending > 0 then
          local call = clones.pending[1]
          local stdout = glab_answer({ web_url = web_url })(call.argv, {}).stdout
          clones.answer(vim.json.decode(stdout ~= "" and stdout or '""'))
        end
        vim.wait(5)
      end
    end
    -- :Docket !482 from `dir`, with glab answering the merge request at
    -- `web_url`: the buffer, and what the read reported. Every buffer made
    -- is deleted once the test is over, whether it passed or not: one left
    -- behind under `Acme/Payments` would stop a later test naming a buffer
    -- `acme/payments`: with 'fileignorecase' set, its default on macOS, the
    -- editor compares buffer names without case, and naming the second
    -- raises E95.
    local made = {}
    local function opened_from(dir, web_url)
      clones.enter(dir)
      local reported
      local buf = buffer.open("glab", "!482", function(read_ok, message)
        reported = { read_ok, message }
      end)
      made[#made + 1] = buf
      drain(web_url)
      return buf, reported
    end
    local inner_ok, inner_err = pcall(function()
      -- From a fork, glab answers the upstream project's !482. The refusal
      -- carries both remedies, since it cannot tell a fork from a clone
      -- whose origin spells this one project another way: the https URL it
      -- names is the answer's host with the answered path.
      local refusal = "docket://glab/me/payments/!482: glab answered !482 of acme/payments, and the name, read off origin, says me/payments, so nothing is filled; :Docket !482 from a clone whose origin is acme/payments opens that one under its own name"
        .. "; where origin spells this project another way -- an ssh URL without the instance's path prefix, or the path the project had before a move or a rename -- git remote set-url origin https://gitlab.example.test/acme/payments.git makes the two agree"
      local fork, reported = opened_from("/w/fork", address("acme/payments"))
      eq(vim.api.nvim_buf_get_name(fork), "docket://glab/me/payments/!482", "the name is origin's project")
      eq(reported, { false, refusal })
      eq(vim.api.nvim_buf_get_lines(fork, 0, -1, false), { "" }, "nothing is filled")
      eq(vim.b[fork].docket, nil)
      eq(notices, { { message = refusal, level = vim.log.levels.ERROR } })
      eq(vim.api.nvim_get_current_buf(), fork, "the empty buffer is what is on screen")

      -- The answer names the name's project.
      local same
      same, reported = opened_from("/w/a", address("acme/payments"))
      eq(vim.api.nvim_buf_get_name(same), "docket://glab/acme/payments/!482")
      eq(reported, { true })
      eq(vim.api.nvim_buf_get_lines(same, 1, 2, false), { "# Bump the pinned acli" })
      eq(vim.b[same].docket.project, "acme/payments")

      -- A subgroup's path, in both.
      local sub
      sub, reported = opened_from("/w/sub", address("acme/sub/payments"))
      eq(vim.api.nvim_buf_get_name(sub), "docket://glab/acme/sub/payments/!482")
      eq(reported, { true })
      eq(vim.b[sub].docket.project, "acme/sub/payments")

      -- Origin spells the path in another case than the instance does. The
      -- buffer of the other spelling goes first, or naming this one raises
      -- E95.
      vim.api.nvim_buf_delete(same, { force = true })
      local cased
      cased, reported = opened_from("/w/cased", address("acme/payments"))
      eq(vim.api.nvim_buf_get_name(cased), "docket://glab/Acme/Payments/!482")
      eq(reported, { true }, "one project, so the case does not refuse it")
      eq(vim.b[cased].docket.url, address("acme/payments"))

      -- And the other way about: origin lower-case, the instance's spelling
      -- mixed. The compare lowers both sides, and one side alone would
      -- refuse this read.
      vim.api.nvim_buf_delete(cased, { force = true })
      local instance_cased
      instance_cased, reported = opened_from("/w/a", address("Acme/Payments"))
      eq(vim.api.nvim_buf_get_name(instance_cased), "docket://glab/acme/payments/!482")
      eq(reported, { true }, "one project, whichever side spells it in capitals")
      eq(vim.b[instance_cased].docket.url, address("Acme/Payments"))

      -- The path alone is compared, so the same path on another host -- a
      -- mirror glab read through another remote -- fills the buffer, and
      -- the address kept is the other host's.
      local mirrored
      mirrored, reported = opened_from("/w/a", "https://gitlab.com/acme/payments/-/merge_requests/482")
      eq(mirrored, instance_cased, "the same buffer")
      eq(reported, { true })
      eq(vim.b[mirrored].docket.url, "https://gitlab.com/acme/payments/-/merge_requests/482")

      -- An address of another shape names no project and is compared with
      -- nothing: from the fork, where an address that could be read was
      -- refused above, the read fills the buffer left empty there.
      local unread
      unread, reported = opened_from("/w/fork", "https://gitlab.example.test/acme/payments/merge_requests/482")
      eq(unread, fork, "the same buffer")
      eq(reported, { true })
      eq(vim.api.nvim_buf_get_lines(fork, 1, 2, false), { "# Bump the pinned acli" })
      eq(vim.b[fork].docket.url, "https://gitlab.example.test/acme/payments/merge_requests/482")
      eq(#notices, 1, "the refusal above is the only notice")

      -- The `:e` path refuses the same answer: a name typed by hand in the
      -- fork's clone passes the check that the editor is in a clone of the
      -- name's project, and the answer is then held against the name.
      vim.api.nvim_buf_delete(fork, { force = true })
      local typed = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(typed, "docket://glab/me/payments/!482")
      made[#made + 1] = typed
      clones.enter("/w/fork")
      reported = nil
      buffer.read(typed, function(read_ok, message)
        reported = { read_ok, message }
      end)
      drain(address("acme/payments"))
      eq(reported, { false, refusal })
      eq(vim.api.nvim_buf_get_lines(typed, 0, -1, false), { "" }, "nothing is filled")
      eq(vim.b[typed].docket, nil)
      eq(#notices, 2, "and the refusal is reported")
    end)
    restore_notify()
    for _, buf in ipairs(made) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    assert(inner_ok, inner_err)
  end)
  repo.root, repo.remote_url = saved.root, saved.remote_url
  assert(ok, err)
end)

test("commands: <CR> on a dash row opens the item from the clone the dash shows, after the tab's directory has moved to another clone or out of any", function()
  jira.forget()
  glab.forget()
  local _, restore_cache = scratch_cache()
  -- /w/a and /w/b are clones of two projects; anywhere else is no clone.
  local origins = {
    ["/w/a"] = "git@gitlab.example.test:acme/payments.git",
    ["/w/b"] = "git@gitlab.example.test:acme/other.git",
  }
  local saved = { root = repo.root, remote_url = repo.remote_url, binding = repo.binding, getcwd = vim.fn.getcwd }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  -- The binding is read for the tickets alone, and the last pass has it
  -- unreadable: an open reads no binding, so <CR> on a merge request still
  -- opens it, where `w` refuses with the reason.
  local bound = true
  repo.binding = function()
    if bound then
      return { kind = "projects", projects = { "PAY" } }
    end
    return nil, "fatal: bad config line 3 in file .git/config"
  end
  local cwd = "/w/a"
  vim.fn.getcwd = function()
    return cwd
  end
  -- The dash checks the state through spawn.run, and <CR> through
  -- spawn.wait, as :Docket <id> does. Each clone's !482 has its own address,
  -- so an item read in the wrong clone is refused, its answer naming the
  -- other project.
  local waits, restore_wait = stub_acli({ signed_in = true, glab = true })
  local runs, restore_run = stub_run(checked({ signed_in = true, glab = true }, function(argv, opts)
    if argv[1] == "glab" then
      return glab_answer({ web_url = address(opts.cwd == "/w/b" and "acme/other" or "acme/payments") })(argv, opts)
    end
    if argv[4] == "view" then
      return done(argv, view_payload())
    end
    return done(argv, { dash_row("PAY-3", "To Do", "Three") })
  end))
  local notices, restore_notify = stub_notify()
  local previous = buffer.named(buffer.name("glab", "!482", "acme/payments"))
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  local ok, err = pcall(function()
    for _, pass in ipairs({ { "/w/b", true }, { "/elsewhere", true }, { "/w/b", false } }) do
      local moved_to
      moved_to, bound = pass[1], pass[2]
      cwd = "/w/a"
      local dash = commands.dash()
      eq(settled(dash), true, "every section answered")
      eq(list.state(dash).binding ~= nil, bound, "the binding is as this pass has it")
      local lnum
      for index, line in ipairs(lines_of(dash)) do
        if line:find("!482", 1, true) then
          lnum = index
        end
      end
      eq(lnum ~= nil, true, "the dash shows !482: " .. table.concat(lines_of(dash), "\n"))
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      -- :cd in the dash's tab, between opening it and pressing <CR>.
      cwd = moved_to
      local from_run, from_wait = #runs + 1, #waits + 1
      commands.open_row(dash)
      vim.wait(1000, function()
        return vim.b[vim.api.nvim_get_current_buf()].docket ~= nil
      end)
      local opened = vim.api.nvim_get_current_buf()
      eq(vim.api.nvim_buf_get_name(opened), "docket://glab/acme/payments/!482", "from " .. moved_to)
      eq(vim.b[opened].docket ~= nil, true, "the item was read: " .. vim.inspect(notices))
      eq(vim.b[opened].docket.url, address("acme/payments"), "the dash's clone's merge request")
      eq(vim.b[opened].docket.ref.cwd, "/w/a", "later calls stay in that clone")
      local checks = vim.list_slice(waits, from_wait)
      eq(#checks, 1, "one state check, blocking")
      eq({ checks[1].argv, checks[1].opts.cwd }, { { "glab", "auth", "status" }, "/w/a" }, "run in the dash's clone")
      local reads = vim.list_slice(runs, from_run)
      eq(#reads > 0, true, "the item was read")
      for _, call in ipairs(reads) do
        eq({ call.argv[1], call.opts.cwd }, { "glab", "/w/a" }, table.concat(call.argv, " "))
      end
      eq(notices, {}, "from " .. moved_to)
      vim.api.nvim_buf_delete(opened, { force = true })
    end
  end)
  restore_notify()
  restore_run()
  restore_wait()
  restore_cache()
  repo.root, repo.remote_url, repo.binding, vim.fn.getcwd = saved.root, saved.remote_url, saved.binding, saved.getcwd
  glab.forget()
  assert(ok, err)
end)

test("buffer: open() given a clone reads there with or without an adapter, :e makes its state check in the clone the buffer's reference names, and a clone whose origin names no project is named in the refusal", function()
  vim.g.loaded_docket = nil
  dofile(PLUGIN)
  glab.forget()
  -- /w/a and /w/b are clones of two GitLab projects, /w/gh of a GitHub
  -- repository, and /w/none a clone whose origin names no project.
  local origins = {
    ["/w/a"] = "git@gitlab.example.test:acme/payments.git",
    ["/w/b"] = "git@gitlab.example.test:acme/other.git",
    ["/w/gh"] = "git@github.com:acme/payments.git",
    ["/w/none"] = "https://gitlab.example.test/",
  }
  local saved = { root = repo.root, remote_url = repo.remote_url, getcwd = vim.fn.getcwd }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  local cwd = "/w/b"
  vim.fn.getcwd = function()
    return cwd
  end
  -- glab's verdict follows the host the directory's remote names: signed in
  -- to the GitLab instance, and to nothing in the GitHub clone.
  local waits, restore_wait = stub_wait(function(argv, opts)
    if opts.cwd == "/w/gh" then
      return failed(argv, 1, "x gitlab.example.test: no token")
    end
    return done(argv, "✓ Logged in to gitlab.example.test as me\n")
  end)
  local runs, restore_run = stub_run(function(argv, opts)
    return glab_answer({ web_url = address(opts.cwd == "/w/b" and "acme/other" or "acme/payments") })(argv, opts)
  end)
  local notices, restore_notify = stub_notify()
  local previous = buffer.named(buffer.name("glab", "!482", "acme/payments"))
  if previous then
    vim.api.nvim_buf_delete(previous, { force = true })
  end
  -- Each call as `glab <verb>` beside the directory it ran in, from `from`.
  local function ran_from(calls, from)
    return vim.tbl_map(function(call)
      return { table.concat(call.argv, " ", 1, math.min(#call.argv, 3)), call.opts.cwd }
    end, vim.list_slice(calls, from))
  end
  local ok, err = pcall(function()
    -- No adapter: the state check is made here, in the clone given, and the
    -- reads follow it rather than the editor's directory.
    local reported
    local buf = buffer.open("glab", "!482", function(read_ok, message)
      reported = { read_ok, message }
    end, nil, "/w/a")
    eq(vim.api.nvim_buf_get_name(buf), "docket://glab/acme/payments/!482")
    vim.wait(1000, function()
      return reported ~= nil
    end)
    eq(reported, { true })
    eq(ran_from(waits, 1), { { "glab auth status", "/w/a" } }, "the check ran in the clone given")
    eq(#runs > 0, true)
    for _, call in ipairs(ran_from(runs, 1)) do
      eq(call[2], "/w/a", call[1])
    end
    eq(vim.b[buf].docket.url, address("acme/payments"), "that clone's merge request")
    eq(vim.b[buf].docket.ref.cwd, "/w/a")

    -- :e from a tab in the GitHub clone, where glab is signed in to nothing:
    -- the check runs in the clone the reference names, so the read succeeds.
    cwd = "/w/gh"
    vim.api.nvim_set_current_buf(buf)
    local from_wait, from_run = #waits + 1, #runs + 1
    vim.cmd("edit")
    vim.wait(1000, function()
      return vim.b[buf].docket ~= nil
    end)
    eq(ran_from(waits, from_wait), { { "glab auth status", "/w/a" } }, "the check ran where the read did")
    local reread = ran_from(runs, from_run)
    eq(#reread > 0, true, ":e read the merge request")
    for _, call in ipairs(reread) do
      eq(call[2], "/w/a", call[1])
    end
    eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false), { "# Bump the pinned acli" })
    eq(notices, {}, "nothing was refused")

    -- A clone given whose origin names no project: the refusal names that
    -- clone and not the editor's directory, which was never read, and
    -- nothing runs.
    cwd = "/w/b"
    from_wait, from_run = #waits + 1, #runs + 1
    local refused
    eq(
      buffer.open("glab", "!482", function(open_ok, message)
        refused = { open_ok, message }
      end, glab, "/w/none"),
      nil
    )
    eq(refused, {
      false,
      "!482: glab numbers its items within a project, and /w/none, the clone it is opened from, names none; :Docket !482 from a clone of the project opens it\norigin is https://gitlab.example.test/, which names no project",
    })
    eq(notices, { { message = refused[2], level = vim.log.levels.ERROR } })
    eq({ #waits, #runs }, { from_wait - 1, from_run - 1 }, "nothing ran")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  restore_notify()
  restore_run()
  restore_wait()
  repo.root, repo.remote_url, vim.fn.getcwd = saved.root, saved.remote_url, saved.getcwd
  glab.forget()
  assert(ok, err)
end)

test("commands: <CR> on a pull request row makes its state check in the dash's clone and hands octo.nvim the row's address", function()
  jira.forget()
  gh.forget()
  local _, restore_cache = scratch_cache()
  local saved = { root = repo.root, remote_url = repo.remote_url, binding = repo.binding, getcwd = vim.fn.getcwd }
  repo.root = function(cwd)
    if cwd == "/w/gh" or cwd == "/w/other" then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return dir == "/w/gh" and "git@github.com:acme/payments.git" or "git@github.com:acme/other.git"
  end
  repo.binding = function()
    return { kind = "projects", projects = { "PAY" } }
  end
  local cwd = "/w/gh"
  vim.fn.getcwd = function()
    return cwd
  end
  local waits, restore_wait = stub_acli({ signed_in = true, gh = true })
  -- Two rows: one on github.com and one on an Enterprise instance, each
  -- handed over by the address it carries, host and all.
  local _, restore_run = stub_run(checked({ signed_in = true, gh = true }, function(argv)
    if argv[1] == "gh" then
      return done(argv, {
        pull_request(),
        pull_request({
          number = 7,
          title = "Pin the runner",
          headRefName = "pin-runner",
          url = "https://ghe.example.test/acme/payments/pull/7",
        }),
      })
    end
    return done(argv, { dash_row("PAY-3", "To Do", "Three") })
  end))
  -- octo.nvim stands in as its command alone, recording what it is handed
  -- and the directory the editor is in when it is.
  local handed = {}
  vim.api.nvim_create_user_command("Octo", function(command)
    handed[#handed + 1] = { command.args, vim.fn.getcwd() }
  end, { nargs = "*" })
  local notices, restore_notify = stub_notify()
  local ok, err = pcall(function()
    for _, case in ipairs({
      { "#12", "https://github.com/acme/payments/pull/12" },
      { "#7", "https://ghe.example.test/acme/payments/pull/7" },
    }) do
      cwd = "/w/gh"
      local dash = commands.dash()
      eq(settled(dash), true, "every section answered")
      local lnum
      for index = 1, vim.api.nvim_buf_line_count(dash) do
        local r = list.row_at(dash, index)
        if r and r.id == case[1] then
          lnum = index
        end
      end
      eq(lnum ~= nil, true, "the dash shows " .. case[1] .. ": " .. table.concat(lines_of(dash), "\n"))
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      -- :cd in the dash's tab into another repository's clone, then <CR>.
      cwd = "/w/other"
      local from_wait, from_handed = #waits + 1, #handed + 1
      commands.open_row(dash)
      vim.wait(1000, function()
        return #handed >= from_handed
      end)
      local checks = vim.list_slice(waits, from_wait)
      eq(#checks, 1, "one state check, blocking")
      -- The host the rows taught the adapter follows the verb, so the verb
      -- alone is compared.
      eq({ vim.list_slice(checks[1].argv, 1, 3), checks[1].opts.cwd }, { { "gh", "auth", "status" }, "/w/gh" }, "run in the dash's clone")
      -- The row's address names its repository and host, so the command is
      -- handed that and not the number, whatever the tab's directory: the
      -- dash's clone reaches the check and nothing after it.
      eq(vim.list_slice(handed, from_handed), { { case[2], "/w/other" } }, case[1])
      eq(notices, {})
      eq(buffer.named("docket://gh/" .. case[1]), nil, "no item buffer is made")
    end
  end)
  vim.api.nvim_del_user_command("Octo")
  restore_notify()
  restore_run()
  restore_wait()
  restore_cache()
  repo.root, repo.remote_url, repo.binding, vim.fn.getcwd = saved.root, saved.remote_url, saved.binding, saved.getcwd
  gh.forget()
  assert(ok, err)
end)

test("gh and jira: project_of reads owner/repo off a pull request's address and nothing off a ticket's, and same_project drops case", function()
  eq(gh.project_of("https://github.com/acme/payments/pull/12"), "acme/payments")
  eq(gh.project_of("https://ghe.example.test/acme/payments/pull/12/files"), "acme/payments", "whatever the host, and whatever follows the number")
  eq(gh.project_of("http://github.com/acme/payments/pull/12"), "acme/payments")
  eq(gh.project_of("https://github.com/acme/payments/issues/12"), nil, "an issue's address is not read")
  eq(gh.project_of("https://github.com/acme/payments/pull/new/topic"), nil, "a pull path with no number is not read")
  eq(gh.project_of("https://github.com/acme/payments"), nil)
  eq(gh.project_of("https://github.com/acme/pull/12"), nil, "one path part is no repository")
  eq(gh.project_of("https://github.com/acme/sub/payments/pull/12"), nil, "nor are three")
  eq(gh.project_of(nil), nil)
  eq(gh.project_of(12), nil)
  eq(jira.project_of("https://example.atlassian.net/browse/PAY-1"), nil, "a key names its project itself")
  eq(jira.project_of(nil), nil)
  eq(repo.same_project("Acme/Payments", "acme/payments"), true)
  eq(repo.same_project("acme/payments", "acme/payments"), true)
  eq(repo.same_project("acme/payments", "acme/other"), false)
  eq(repo.same_project("acme/payments", "prefix/acme/payments"), false, "a path prefix is another path")
end)

test("commands: a dash row of another project than the dash's clone is refused by <CR>, w and R, against the dash's clone and before the launcher's own checks, with the set-url remedy; a pull request row of another repository opens in octo.nvim by its address; a row of the clone's project in another case, one with no address, a ticket, a clone naming no project, and a fork's clone whose upstream lists the row are not refused; a clone whose origin spells the rows' project another way is", function()
  jira.forget()
  glab.forget()
  gh.forget()
  local _, restore_cache = scratch_cache()
  -- /w/b is a clone of acme/other on GitLab, and /w/pay one of acme/payments;
  -- /w/none a clone whose origin names no project; /w/ssh a clone of
  -- acme/other by its ssh URL on an instance served under /gitlab, which its
  -- web addresses carry and the ssh URL does not; and /w/fork a clone of a
  -- GitHub fork, with acme/payments as `upstream` beside origin.
  local origins = {
    ["/w/b"] = "git@gitlab.example.test:acme/other.git",
    ["/w/pay"] = "git@gitlab.example.test:acme/payments.git",
    ["/w/none"] = "https://gitlab.example.test/",
    ["/w/ssh"] = "git@gitlab.example.test:acme/other.git",
    ["/w/fork"] = "git@github.com:me/payments.git",
  }
  local upstreams = {
    ["/w/fork"] = "https://github.com/acme/payments.git",
  }
  local saved = {
    root = repo.root,
    remote_url = repo.remote_url,
    remotes = repo.remotes,
    binding = repo.binding,
    getcwd = vim.fn.getcwd,
    launch = env.launch,
    echo = vim.api.nvim_echo,
  }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  repo.remotes = function(dir)
    local listed = { { name = "origin", url = origins[dir] } }
    if upstreams[dir] then
      listed[#listed + 1] = { name = "upstream", url = upstreams[dir] }
    end
    return listed
  end
  local binding, binding_err = { kind = "projects", projects = { "PAY" } }, nil
  repo.binding = function()
    return binding, binding_err
  end
  local cwd = "/w/b"
  vim.fn.getcwd = function()
    return cwd
  end
  -- The launcher records what it is asked for and goes no further; the
  -- progress line drawn before it is silenced.
  local launched = {}
  env.launch = function(opts)
    launched[#launched + 1] = opts
    return nil, "launched no further"
  end
  vim.api.nvim_echo = function() end
  -- Beside a ticket section and the clone's own reviews, sections that run
  -- in every clone: another project's merge requests by -R, the clone's own
  -- project by -R in the case the instance spells it, another repository's
  -- pull requests by --repo, and a group's, whose rows carry no address.
  config.configure({
    sections = {
      { title = "All open tickets", adapter = "jira", query = "<projects> AND statusCategory != Done ORDER BY updated DESC" },
      {
        title = "Review requested",
        adapter = "review",
        query = { glab = { "mr", "list", "--reviewer=@me" }, gh = { "pr", "list", "--search", "review-requested:@me" } },
      },
      { title = "Payments", adapter = "glab", query = { "mr", "list", "-R", "acme/payments", "--reviewer=@me" } },
      { title = "Other, as the instance spells it", adapter = "glab", query = { "mr", "list", "-R", "Acme/Other" } },
      { title = "Tools", adapter = "gh", query = { "pr", "list", "--repo", "acme/tools" } },
      { title = "The group", adapter = "glab", query = { "mr", "list", "--group", "acme" } },
    },
  })
  local function mr_url(project, iid)
    return ("https://gitlab.example.test/%s/-/merge_requests/%d"):format(project, iid)
  end
  -- A merge request whose address names `project`, or, with none, one whose
  -- list left it without an address, as JSON null decodes; with no `branch`,
  -- one the list left without a source branch.
  local function mr_at(iid, project, branch)
    local payload = merge_request({ iid = iid, title = ("Change %d"):format(iid), source_branch = branch })
    payload.source_branch = branch
    payload.web_url = project and mr_url(project, iid) or nil
    payload.references = { short = "!" .. iid, full = (project or "acme/other") .. "!" .. iid }
    return payload
  end
  -- A merge request from a fork, on a branch of the name origin also has:
  -- the two project ids glab marks one with.
  local function from_fork(iid, project, branch)
    local payload = mr_at(iid, project, branch)
    payload.source_project_id, payload.target_project_id = 91, 77
    return payload
  end
  local views = {
    ["482"] = mr_at(482, "acme/payments", "feature/acli.bump"),
    ["483"] = mr_at(483, "acme/payments", nil),
    ["484"] = from_fork(484, "acme/payments", "main"),
    ["11"] = mr_at(11, "Acme/Other", "spelt-so"),
    ["5"] = mr_at(5, "acme/other", "unaddressed"),
    ["7"] = mr_at(7, "acme/other", "drop-flag"),
    prefixed = mr_at(7, "gitlab/acme/other", "drop-flag"),
  }
  local waits, restore_wait = stub_acli({ signed_in = true, glab = true, gh = true })
  local runs, restore_run = stub_run(checked({ signed_in = true, glab = true, gh = true }, function(argv, opts)
    if argv[1] == "gh" then
      if has(argv, "acme/tools") then
        return done(argv, {
          pull_request({ number = 7, title = "Pin the runner", headRefName = "pin-runner", url = "https://github.com/acme/tools/pull/7" }),
        })
      end
      -- The fork's clone, where gh lists upstream's pull requests: the
      -- fixture's #12 of acme/payments, the clone's own pull request from
      -- me/payments, which gh marks as from a fork.
      return done(argv, { pull_request({ isCrossRepository = true }) })
    end
    if argv[1] == "glab" and argv[2] == "mr" and argv[3] == "list" then
      if has(argv, "acme/payments") then
        return done(argv, { views["482"], views["483"], views["484"] })
      elseif has(argv, "Acme/Other") then
        return done(argv, { views["11"] })
      elseif has(argv, "--group") then
        return done(argv, { mr_at(5, nil, "unaddressed"), from_fork(6, nil, "main") })
      elseif opts.cwd == "/w/ssh" then
        return done(argv, { views.prefixed })
      end
      return done(argv, { views["7"] })
    end
    if argv[1] == "glab" and argv[2] == "mr" and argv[3] == "view" then
      return done(argv, views[argv[4]])
    end
    if argv[1] == "glab" then
      return glab_answer()(argv, opts)
    end
    if argv[4] == "view" then
      return done(argv, view_payload())
    end
    return done(argv, { dash_row("PAY-3", "To Do", "Three") })
  end))
  -- octo.nvim stands in as its command alone, as the test above has it.
  local handed = {}
  vim.api.nvim_create_user_command("Octo", function(command)
    handed[#handed + 1] = command.args
  end, { nargs = "*" })
  local notices, restore_notify = stub_notify()
  for _, name in ipairs({ "docket://glab/acme/other/!482", "docket://glab/acme/payments/!482" }) do
    local previous = buffer.named(name)
    if previous then
      vim.api.nvim_buf_delete(previous, { force = true })
    end
  end
  local ERROR = vim.log.levels.ERROR
  local ok, err = pcall(function()
    local function cursor_on(dash, source, id)
      for index = 1, vim.api.nvim_buf_line_count(dash) do
        local r = list.row_at(dash, index)
        if r and r.source == source and r.id == id then
          vim.api.nvim_win_set_cursor(0, { index, 0 })
          return dash
        end
      end
      error(("the dash shows no %s row %s:\n%s"):format(source, id, table.concat(lines_of(dash), "\n")))
    end
    local function dash_at(source, id)
      local dash = commands.dash()
      eq(settled(dash), true, "every section answered")
      return cursor_on(dash, source, id)
    end
    -- What the dash's own opens leave: the buffer on screen once its read
    -- has landed.
    local function opened()
      vim.wait(1000, function()
        return vim.b[vim.api.nvim_get_current_buf()].docket ~= nil
      end)
      return vim.api.nvim_get_current_buf()
    end

    -- Every refusal ends with the remedy for a clone whose origin spells the
    -- row's project another way than the address does, as the item buffer's
    -- refusal of an answer naming another project does: the compare cannot
    -- tell the two apart.
    local function remedy(site, project)
      return ("; where origin spells this project another way -- an ssh URL without the instance's path prefix, or the path the project had before a move or a rename -- git remote set-url origin %s/%s.git makes the two agree"):format(
        site,
        project
      )
    end
    local function refused(id, theirs, ours, site)
      return {
        {
          message = ("%s is %s's, and the dash's clone is of %s, whose %s is another; :Docket %s from a clone of %s opens it%s"):format(
            id,
            theirs,
            ours,
            id,
            id,
            theirs,
            remedy(site, theirs)
          ),
          level = ERROR,
        },
        {
          message = ("%s is %s's, and the dash's clone is of %s, where a branch of its name is another's code; w in the dash of a clone of %s builds it%s"):format(
            id,
            theirs,
            ours,
            theirs,
            remedy(site, theirs)
          ),
          level = ERROR,
        },
        {
          message = ("%s is %s's, and the dash's clone is of %s, where a branch of its name is another's code; R in the dash of a clone of %s reviews it%s"):format(
            id,
            theirs,
            ours,
            theirs,
            remedy(site, theirs)
          ),
          level = ERROR,
        },
      }
    end
    local GITLAB, GITHUB = "https://gitlab.example.test", "https://github.com"

    -- The other project's merge request: every key refuses it, nothing is
    -- read, no state check is made and nothing is built.
    local dash = dash_at("glab", "!482")
    local from_run, from_wait = #runs + 1, #waits + 1
    commands.open_row(dash)
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.api.nvim_get_current_buf(), dash, "nothing opened")
    eq({ #runs, #waits }, { from_run - 1, from_wait - 1 }, "nothing ran")
    eq(launched, {})
    local payments = refused("!482", "acme/payments", "acme/other", GITLAB)
    eq(notices, payments)
    eq(buffer.named("docket://glab/acme/other/!482"), nil)
    eq(buffer.named("docket://glab/acme/payments/!482"), nil)

    -- The tab's directory moved into a clone of the row's own project: the
    -- compare is against the dash's clone, so w and R refuse as before.
    cwd = "/w/pay"
    local shown = #notices
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.list_slice(notices, shown + 1), { payments[2], payments[3] }, "the same two refusals")
    eq(launched, {})
    cwd = "/w/b"

    -- The other project's merge request with no branch: foreign() answers
    -- before the branch check, so the refusal names the project and not
    -- `carries no branch`.
    cursor_on(dash, "glab", "!483")
    shown = #notices
    commands.work_row(dash)
    commands.review_row(dash)
    local unbranched = refused("!483", "acme/payments", "acme/other", GITLAB)
    eq(vim.list_slice(notices, shown + 1), { unbranched[2], unbranched[3] })
    eq(launched, {})

    -- The other repository's pull request: w and R refuse it, and <CR> opens
    -- it in octo.nvim as that repository's, by the address the row carries.
    cursor_on(dash, "gh", "#7")
    shown = #notices
    commands.work_row(dash)
    commands.review_row(dash)
    local tools = refused("#7", "acme/tools", "acme/other", GITHUB)
    eq(vim.list_slice(notices, shown + 1), { tools[2], tools[3] })
    eq(launched, {})
    shown = #notices
    commands.open_row(dash)
    vim.wait(1000, function()
      return #handed > 0
    end)
    eq(handed, { "https://github.com/acme/tools/pull/7" }, "the address, not the number alone")
    eq(#notices, shown, "nothing refused")
    eq(vim.api.nvim_get_current_buf(), dash, "the stand-in opens nothing, so the dash stays")

    -- The clone's own project, spelt as the instance does: one project, so
    -- w builds it and <CR> reads it in the clone.
    dash = dash_at("glab", "!11")
    shown = #notices
    commands.work_row(dash)
    eq(launched, { { root = "/w/b", binding = binding, branch = "spelt-so" } })
    eq(vim.list_slice(notices, shown + 1), { { message = "launched no further", level = ERROR } }, "the launcher's own refusal, and no other")
    shown = #notices
    commands.open_row(dash)
    local buf = opened()
    eq(vim.api.nvim_buf_get_name(buf), "docket://glab/acme/other/!11")
    eq(vim.b[buf].docket.url, mr_url("Acme/Other", 11))
    eq(vim.b[buf].docket.ref.cwd, "/w/b")
    eq(#notices, shown, "nothing refused")
    vim.api.nvim_buf_delete(buf, { force = true })

    -- A row with no address names no project, so it is compared with
    -- nothing and opens as the clone's.
    dash = dash_at("glab", "!5")
    commands.open_row(dash)
    buf = opened()
    eq(vim.api.nvim_buf_get_name(buf), "docket://glab/acme/other/!5")
    eq(vim.b[buf].docket.url, mr_url("acme/other", 5))
    eq(#notices, shown, "nothing refused")
    vim.api.nvim_buf_delete(buf, { force = true })

    -- A row with no address that its list marks as from a fork: nothing says
    -- whose the row is, so w and R refuse it as from a fork, before the
    -- launcher.
    local forked = function(id, branch)
      return {
        message = ("%s comes from a fork, so origin's %s is not its branch and no worktree is made for it"):format(id, branch),
        level = ERROR,
      }
    end
    dash = dash_at("glab", "!6")
    shown = #notices
    local built = #launched
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.list_slice(notices, shown + 1), { forked("!6", "main"), forked("!6", "main") })
    eq(#launched, built)

    -- A ticket names its project in its key, and w builds it; R refuses it
    -- as a ticket, which is its own reason.
    dash = dash_at("jira", "PAY-3")
    shown = #notices
    commands.work_row(dash)
    commands.review_row(dash)
    eq(launched[#launched], { root = "/w/b", binding = binding, key = "PAY-3", summary = "Three" })
    eq(vim.list_slice(notices, shown + 1), {
      { message = "launched no further", level = ERROR },
      { message = "PAY-3 is a ticket; R starts a review on a merge request", level = ERROR },
    })

    -- A dash in a clone whose origin names no project holds nothing against
    -- a row: <CR> goes on to the open, which refuses for its own reason, and
    -- w to the launcher.
    cwd = "/w/none"
    dash = dash_at("glab", "!482")
    shown = #notices
    commands.open_row(dash)
    eq(vim.api.nvim_get_current_buf(), dash, "nothing opened")
    eq(#notices, shown + 1)
    eq(
      notices[#notices].message:find(
        "!482: glab numbers its items within a project, and /w/none, the clone it is opened from, names none; :Docket !482 from a clone of the project opens it",
        1,
        true
      ),
      1,
      notices[#notices].message
    )
    commands.work_row(dash)
    eq(launched[#launched], { root = "/w/none", binding = binding, branch = "feature/acli.bump" })
    -- A row from a fork there: nothing says the clone is a fork of the row's
    -- project, so w and R refuse it as from a fork.
    cursor_on(dash, "glab", "!484")
    shown = #notices
    built = #launched
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.list_slice(notices, shown + 1), { forked("!484", "main"), forked("!484", "main") })
    eq(#launched, built)

    -- A clone by the ssh URL of an instance served under a path prefix: the
    -- rows' addresses carry the prefix and origin does not, so the clone's
    -- own rows are refused, nothing is read or built, and each refusal ends
    -- with the set-url that makes the two agree.
    cwd = "/w/ssh"
    dash = dash_at("glab", "!7")
    shown = #notices
    built = #launched
    from_run, from_wait = #runs + 1, #waits + 1
    commands.open_row(dash)
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.api.nvim_get_current_buf(), dash, "nothing opened")
    eq({ #runs, #waits }, { from_run - 1, from_wait - 1 }, "nothing ran")
    eq(#launched, built)
    eq(vim.list_slice(notices, shown + 1), refused("!7", "gitlab/acme/other", "acme/other", GITLAB))

    -- A fork's clone on GitHub, with acme/payments as upstream: gh lists
    -- upstream's pull requests there, and upstream is one of the clone's
    -- remotes, so w and R take the row's branch to the launcher, marked as
    -- from a fork though it is -- origin is the fork its branch lives in; a
    -- row of a project no remote names, acme/tools by --repo, is refused as
    -- anywhere, naming origin's project as the clone's.
    cwd = "/w/fork"
    dash = dash_at("gh", "#12")
    eq(list.row_at(dash, vim.api.nvim_win_get_cursor(0)[1]).fork, true, "#12 reaches the dash marked")
    shown = #notices
    built = #launched
    commands.work_row(dash)
    commands.review_row(dash)
    eq(vim.list_slice(launched, built + 1), {
      { root = "/w/fork", binding = binding, branch = "teardown" },
      { root = "/w/fork", binding = binding, branch = "teardown", review = "#12" },
    })
    eq(vim.list_slice(notices, shown + 1), {
      { message = "launched no further", level = ERROR },
      { message = "launched no further", level = ERROR },
    }, "the launcher's own refusal, and no other")
    cursor_on(dash, "gh", "#7")
    shown = #notices
    built = #launched
    commands.work_row(dash)
    eq(vim.list_slice(notices, shown + 1), { refused("#7", "acme/tools", "me/payments", GITHUB)[2] })
    eq(#launched, built)

    -- A binding that cannot be read is the launcher's refusal, and foreign()
    -- answers before the launcher: w reports the row's project.
    cwd = "/w/b"
    binding, binding_err = nil, "fatal: bad config line 3 in file .git/config"
    dash = dash_at("glab", "!482")
    shown = #notices
    commands.work_row(dash)
    eq(vim.list_slice(notices, shown + 1), { payments[2] }, "the project's refusal, not the binding's")
  end)
  vim.api.nvim_del_user_command("Octo")
  restore_notify()
  restore_run()
  restore_wait()
  restore_cache()
  config.configure({})
  env.launch, vim.api.nvim_echo, vim.fn.getcwd = saved.launch, saved.echo, saved.getcwd
  repo.root, repo.remote_url, repo.remotes, repo.binding = saved.root, saved.remote_url, saved.remotes, saved.binding
  jira.forget()
  glab.forget()
  gh.forget()
  assert(ok, err)
end)

test("commands: w and R refuse a merge request and a pull request from a fork on the rows the adapters built, before the launcher; a row of the clone's own project, and one whose list left the fork fields out, reach the launcher with the row's branch", function()
  glab.forget()
  gh.forget()
  local _, restore_cache = scratch_cache()
  -- A clone of acme/payments, which every row below is of, so nothing is
  -- refused as another project's; the launcher records what it is asked for
  -- and goes no further, and the progress line drawn before it is silenced.
  local binding = { kind = "projects", projects = { "PAY" } }
  local restore_clone = stub_clone(binding, "git@gitlab.example.test:acme/payments.git")
  local saved = { launch = env.launch, echo = vim.api.nvim_echo }
  local launched = {}
  env.launch = function(opts)
    launched[#launched + 1] = opts
    return nil, "launched no further"
  end
  vim.api.nvim_echo = function() end
  config.configure({
    sections = {
      { title = "Merge requests", adapter = "glab", query = { "mr", "list", "--assignee=@me" } },
      { title = "Pull requests", adapter = "gh", query = { "pr", "list", "--assignee", "@me" } },
    },
  })
  local function pr_url(number)
    return ("https://github.com/acme/payments/pull/%d"):format(number)
  end
  local _, restore_wait = stub_acli({ signed_in = true, glab = true, gh = true })
  local _, restore_run = stub_run(checked({ signed_in = true, glab = true, gh = true }, function(argv)
    if argv[1] == "gh" then
      return done(argv, {
        pull_request({ headRefName = "main", isCrossRepository = true }),
        pull_request({ number = 3, title = "Same repository", headRefName = "same", isCrossRepository = false, url = pr_url(3) }),
        pull_request({ number = 4, title = "Unmarked", headRefName = "patch-1", url = pr_url(4) }),
      })
    end
    return done(argv, {
      merge_request({ iid = 482, source_branch = "main", source_project_id = 91, target_project_id = 77 }),
      merge_request({ iid = 7, title = "Drop the flag", source_branch = "drop-flag", source_project_id = 77, target_project_id = 77 }),
      merge_request({ iid = 9, title = "Unmarked", source_branch = "patch-1" }),
    })
  end))
  local notices, restore_notify = stub_notify()
  local ERROR = vim.log.levels.ERROR
  local ok, err = pcall(function()
    local dash = commands.dash()
    eq(settled(dash), true, "both sections answered")
    local function cursor_on(source, id)
      for index = 1, vim.api.nvim_buf_line_count(dash) do
        local r = list.row_at(dash, index)
        if r and r.source == source and r.id == id then
          vim.api.nvim_win_set_cursor(0, { index, 0 })
          return r
        end
      end
      error(("the dash shows no %s row %s:\n%s"):format(source, id, table.concat(lines_of(dash), "\n")))
    end
    local function refusal(id, branch)
      return {
        message = ("%s comes from a fork, so origin's %s is not its branch and no worktree is made for it"):format(id, branch),
        level = ERROR,
      }
    end
    -- The rows from a fork, each on a branch origin has under the same name:
    -- w and R refuse, and the launcher is not reached.
    for _, from in ipairs({ { "glab", "!482" }, { "gh", "#12" } }) do
      local r = cursor_on(from[1], from[2])
      eq(r.fork, true, from[2] .. " reaches the dash marked")
      eq(r.branch, "main")
      local shown = #notices
      commands.work_row(dash)
      commands.review_row(dash)
      eq(vim.list_slice(notices, shown + 1), { refusal(from[2], "main"), refusal(from[2], "main") }, from[2])
      eq(launched, {}, "the launcher is not reached for " .. from[2])
    end
    -- A row of the clone's own project, and one whose list said nothing
    -- about a fork: each reaches the launcher with the row's branch, and
    -- the launcher's own answer is the only notice.
    for _, same in ipairs({ { "glab", "!7", "drop-flag" }, { "glab", "!9", "patch-1" }, { "gh", "#3", "same" }, { "gh", "#4", "patch-1" } }) do
      local r = cursor_on(same[1], same[2])
      eq(r.fork, nil, same[2] .. " is not marked")
      local shown, built = #notices, #launched
      commands.work_row(dash)
      commands.review_row(dash)
      eq(vim.list_slice(launched, built + 1), {
        { root = "/w/repo", binding = binding, branch = same[3] },
        { root = "/w/repo", binding = binding, branch = same[3], review = same[2] },
      }, same[2])
      eq(vim.list_slice(notices, shown + 1), {
        { message = "launched no further", level = ERROR },
        { message = "launched no further", level = ERROR },
      }, same[2])
    end
  end)
  restore_notify()
  restore_run()
  restore_wait()
  restore_clone()
  restore_cache()
  config.configure({})
  env.launch, vim.api.nvim_echo = saved.launch, saved.echo
  glab.forget()
  gh.forget()
  assert(ok, err)
end)

test("buffer: !482 from a clone whose origin spells the path in another case opens the buffer that exists under 'fileignorecase', reads it from that clone, and :e there with nothing read reads it; with the option off it is a second buffer", function()
  vim.g.loaded_docket = nil
  dofile(PLUGIN)
  -- Two clones of one project, whose origins spell its path in two cases.
  local origins = {
    ["/w/cased"] = "git@gitlab.example.test:Acme/Payments.git",
    ["/w/a"] = "git@gitlab.example.test:acme/payments.git",
  }
  local saved = { root = repo.root, remote_url = repo.remote_url, fold = vim.o.fileignorecase }
  repo.root = function(cwd)
    if origins[cwd] then
      return { root = cwd, bare = false }
    end
    return nil, "fatal: not a git repository"
  end
  repo.remote_url = function(dir)
    return origins[dir]
  end
  local ok, err = pcall(two_clones, function(clones)
    for _, project in ipairs({ "Acme/Payments", "acme/payments" }) do
      local previous = buffer.named(buffer.name("glab", "!482", project))
      if previous then
        vim.api.nvim_buf_delete(previous, { force = true })
      end
    end
    local notices, restore_notify = stub_notify()
    -- Answers every call as glab_answer() would, the instance spelling the
    -- path in lower case, until none is left.
    local function drain()
      for _ = 1, 50 do
        if #clones.pending > 0 then
          local call = clones.pending[1]
          local stdout = glab_answer({ web_url = address("acme/payments") })(call.argv, {}).stdout
          clones.answer(vim.json.decode(stdout ~= "" and stdout or '""'))
        end
        vim.wait(5)
      end
    end
    -- The reads since `from`, each asserted to have run in `dir`.
    local function read_from(from, dir)
      local reads = where_ran(vim.list_slice(clones.ran, from))
      eq(#reads > 0, true, "the merge request was read")
      for _, entry in ipairs(reads) do
        eq(entry[2], dir, entry[1])
      end
    end
    local made = {}
    local inner_ok, inner_err = pcall(function()
      vim.o.fileignorecase = true
      clones.enter("/w/cased")
      local first = buffer.open("glab", "!482")
      made[#made + 1] = first
      drain()
      eq(vim.api.nvim_buf_get_name(first), "docket://glab/Acme/Payments/!482")
      eq(vim.b[first].docket.ref.cwd, "/w/cased")

      -- From the clone spelling the path in lower case: the buffer that
      -- exists, read again from this clone, and not a second buffer, which
      -- the editor would refuse with E95.
      clones.enter("/w/a")
      local from = #clones.ran + 1
      local reported
      local second = buffer.open("glab", "!482", function(read_ok, message)
        reported = { read_ok, message }
      end)
      drain()
      eq(second, first, "the one buffer")
      eq(reported, { true })
      eq(vim.api.nvim_get_current_buf(), first)
      eq(vim.api.nvim_buf_get_name(first), "docket://glab/Acme/Payments/!482", "the name keeps the spelling it was opened under")
      read_from(from, "/w/a")
      eq(vim.b[first].docket.ref.cwd, "/w/a", "later calls go to the clone it was opened from last")
      eq(vim.b[first].docket.url, address("acme/payments"))
      eq(notices, {})
      eq(buffer.named("docket://glab/acme/payments/!482"), first, "found under either spelling, as the editor finds it")
      eq(buffer.named("docket://glab/ACME/PAYMENTS/!482"), first)

      -- :e with nothing read, from the lower-case clone: the two spellings
      -- are one project, so it reads rather than refusing.
      vim.b[first].docket = nil
      from = #clones.ran + 1
      vim.cmd("edit")
      drain()
      read_from(from, "/w/a")
      eq(vim.b[first].docket.ref.cwd, "/w/a")
      eq(vim.api.nvim_buf_get_lines(first, 1, 2, false), { "# Bump the pinned acli" })
      eq(notices, {})

      -- With the option off the editor keeps the two names apart, and so
      -- does named(): the open from the lower-case clone is a second buffer.
      vim.o.fileignorecase = false
      eq(buffer.named("docket://glab/acme/payments/!482"), nil, "the compare is exact, as the editor's is")
      from = #clones.ran + 1
      local third = buffer.open("glab", "!482")
      made[#made + 1] = third
      drain()
      eq(third ~= first, true, "a second buffer")
      eq(vim.api.nvim_buf_get_name(third), "docket://glab/acme/payments/!482")
      read_from(from, "/w/a")
      -- And :e with nothing read in the first, still from the lower-case
      -- clone, reads it: the project compare drops case whatever the option.
      vim.b[first].docket = nil
      vim.api.nvim_set_current_buf(first)
      from = #clones.ran + 1
      vim.cmd("edit")
      drain()
      read_from(from, "/w/a")
      eq(vim.b[first].docket.ref.cwd, "/w/a")
      eq(notices, {})
    end)
    restore_notify()
    for _, buf in ipairs(made) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    assert(inner_ok, inner_err)
  end)
  vim.o.fileignorecase = saved.fold
  repo.root, repo.remote_url = saved.root, saved.remote_url
  assert(ok, err)
end)

-- the suite's own isolation ---------------------------------------------------------------

-- Last, so that every module a test required lazily is loaded by now.
test("suite: every docket module is read from the source tree, and an installed copy is on neither path", function()
  -- Each module file in the source tree is required, so the check covers
  -- every one whichever tests ran.
  for _, file in ipairs(vim.fn.globpath(lua, "docket/**/*.lua", false, true)) do
    require((file:sub(#lua + 2, -5):gsub("/init$", ""):gsub("/", ".")))
  end
  local outside = {}
  for name in pairs(package.loaded) do
    if name == "docket" or vim.startswith(name, "docket.") then
      local origin = origins[name]
      if not origin or not vim.startswith(origin, lua .. "/") then
        outside[#outside + 1] = ("%s from %s"):format(name, origin or "a path the recorder never saw")
      end
    end
  end
  table.sort(outside)
  eq(outside, {}, "modules read from outside " .. lua)
  eq(vim.api.nvim_get_runtime_file("lua/docket/*.lua", true), {}, "no docket module on the runtime search path")
  eq(vim.api.nvim_get_runtime_file("doc/docket.txt", true), {}, "no help file on the runtime search path")

  -- A copy in a package under another folder name, and one on the runtime
  -- path itself, stand in for what a machine may have installed.
  local fake = vim.fn.tempname()
  local copies = { fake .. "/pack/plugins/start/docket.nvim", fake .. "/site" }
  for _, copy in ipairs(copies) do
    vim.fn.mkdir(copy .. "/lua/docket", "p")
    vim.fn.mkdir(copy .. "/doc", "p")
    vim.fn.writefile({ "return {}" }, copy .. "/lua/docket/config.lua")
    vim.fn.writefile({ "*docket.txt*" }, copy .. "/doc/docket.txt")
  end
  local saved = { runtimepath = vim.o.runtimepath, packpath = vim.o.packpath }
  vim.o.packpath = fake
  vim.opt.runtimepath:prepend(fake .. "/site")
  local seen = #vim.api.nvim_get_runtime_file("lua/docket/config.lua", true)
  isolate()
  local found = {
    modules = vim.api.nvim_get_runtime_file("lua/docket/config.lua", true),
    help = vim.api.nvim_get_runtime_file("doc/docket.txt", true),
  }
  local kept = vim.o.runtimepath:find(vim.env.VIMRUNTIME, 1, true) ~= nil
  vim.o.runtimepath, vim.o.packpath = saved.runtimepath, saved.packpath
  eq(seen, #copies, "both stand-in copies are where the editor looks before isolate()")
  eq(found, { modules = {}, help = {} }, "neither is found after it")
  eq(kept, true, "the editor's own runtime stays on the path")
end)

-- runner -----------------------------------------------------------------------------------

local passed = 0
for _, case in ipairs(tests) do
  local ok, err = pcall(case.body)
  -- A test that failed before its own restore leaves a stub in spawn and the
  -- cache wherever it pointed it; the tests after it get the guard and this
  -- run's own directory again.
  spawn.run, spawn.wait = unstubbed, unstubbed
  vim.env.XDG_CACHE_HOME = CACHE_HOME
  config.options.cache_dir = config.cache_dir()
  if ok then
    passed = passed + 1
    io.stdout:write("ok    ", case.name, "\n")
  else
    io.stdout:write("FAIL  ", case.name, "\n      ", tostring(err):gsub("\n", "\n      "), "\n")
  end
end
io.stdout:write(("\n%d/%d passed\n"):format(passed, #tests))
os.exit(passed == #tests and 0 or 1)
