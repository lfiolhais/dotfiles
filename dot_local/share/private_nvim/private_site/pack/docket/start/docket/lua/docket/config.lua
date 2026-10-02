-- The defaults docket ships: the dashboard's sections, the cache directory,
-- the timeouts spawn allows each kind of process, and the Jira statuses given a
-- colour of their own, none by default. Imports nothing local and
-- reaches no process; everything here is a value, which is what lets the suite
-- read it without an editor. setup{} overrides it through configure().

local M = {}

-- A Jira section's query carries PLACEHOLDER, which repo.jql() fills from the
-- repository's binding: `<projects>` becomes `project IN (PAY, OPS)`, or
-- `project IN (PAY) AND parent = PAY-10` in a repository bound to an epic. A
-- review section names no client, because the client is chosen from the
-- remote when the dashboard opens, so its query is one argument list per
-- client, keyed by the adapter's name. `Mine` as `reporter = currentUser()`
-- is a default chosen here; changing it is this one string in setup{}.
M.PLACEHOLDER = "<projects>"

--- The cache directory: `$XDG_CACHE_HOME/docket`, with `~/.cache` standing in
--- when the variable is unset or empty, as the XDG Base Directory Specification
--- requires.
---
--- `defaults` names no `cache_dir` because it is computed rather than written
--- down: the suite sets the environment and calls this function, where a constant
--- in `defaults` would answer with whatever the environment held when the module
--- was first required. `options.cache_dir` is set from here, and setup{}
--- overrides it like any other option.
---
--- Read directly rather than through `vim.fn.stdpath("cache")`, which honours
--- the variable and then appends `nvim/`. What is cached is keyed to a Jira
--- account and a set of repositories rather than to an editor, so a second
--- front end or a shell command asking the same question shares it. Never the
--- source tree either: tests/check.py fails on a program-written file there.
---
--- Both variables are read with `os.getenv`, which reports an empty variable as
--- the empty string. `vim.env` reports it as nil, so reading it there would
--- collapse the empty case into the unset one and leave the branch below
--- untestable.
---@return string dir
function M.cache_dir()
  local base = os.getenv("XDG_CACHE_HOME")
  if base == nil or base == "" then
    local home = os.getenv("HOME")
    if home == nil or home == "" then
      -- The passwd entry answers whether HOME is unset or empty. `expand("~")`
      -- answers with the working directory when it is empty, which would put
      -- the cache in whatever repository the editor was started in, and
      -- `vim.uv.os_homedir()` answers with the empty string.
      home = vim.uv.os_get_passwd().homedir
    end
    base = home .. "/.cache"
  end
  return base .. "/docket"
end

M.defaults = {
  sections = {
    {
      title = "All open tickets",
      adapter = "jira",
      query = "<projects> AND statusCategory != Done ORDER BY updated DESC",
    },
    {
      title = "Assigned to me",
      adapter = "jira",
      query = "<projects> AND assignee = currentUser() AND statusCategory != Done"
        .. " ORDER BY updated DESC",
    },
    {
      title = "Mine",
      adapter = "jira",
      query = "<projects> AND reporter = currentUser() AND statusCategory != Done"
        .. " ORDER BY updated DESC",
    },
    {
      title = "Review requested",
      adapter = "review",
      query = {
        glab = { "mr", "list", "--reviewer=@me" },
        gh = { "pr", "list", "--search", "review-requested:@me" },
      },
    },
    {
      title = "My open reviews",
      adapter = "review",
      query = {
        glab = { "mr", "list", "--assignee=@me" },
        gh = { "pr", "list", "--assignee", "@me" },
      },
    },
  },
  -- Milliseconds spawn allows each kind of process before killing it. A client
  -- call crosses the network. The omnifunc is synchronous and holds the editor
  -- for its whole wait, so it gets the shortest. git covers `wt-add`, which
  -- fetches when a ref is unknown, and `ls-remote`, which always asks the
  -- remote. tmux answers locally.
  timeouts = { client = 30000, complete = 2000, git = 60000, tmux = 5000 },
  -- `site` and `email` for a machine where the first Jira login is not to
  -- prompt for them. Empty by default, because the site names the employer and
  -- this file is tracked; acli keeps both after the first login in any case.
  jira = {},
  -- Jira statuses with a colour of their own, keyed by the status as Jira
  -- prints it: `#rrggbb` as the foreground, a highlight group's name to link
  -- to, or the table nvim_set_hl() takes. highlight.define() sets them.
  statuses = {},
}

-- The live options: the defaults, plus cache_dir, which defaults does not name
-- -- so a caller that never runs setup{} has it too.
M.options = vim.deepcopy(M.defaults)
M.options.cache_dir = M.cache_dir()

--- Overrides the defaults with what setup{} was given.
---
--- Scalars and nested tables merge over the defaults. `sections` is a list
--- and replaces the default list whole, because merging two lists by index
--- would interleave them.
---@param opts table|nil
---@return table options
function M.configure(opts)
  opts = opts or {}
  local sections = opts.sections
  local rest = vim.deepcopy(opts)
  rest.sections = nil
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), rest)
  -- Recomputed here, because the merge above drops it: defaults names no
  -- cache_dir, so only an explicit setup{ cache_dir = ... } survives the extend.
  M.options.cache_dir = M.options.cache_dir or M.cache_dir()
  if sections ~= nil then
    M.options.sections = vim.deepcopy(sections)
  end
  return M.options
end

return M
