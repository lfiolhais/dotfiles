-- The repository in hand: where its root is, which Jira projects and which
-- epic it is bound to, which review client its remote implies and which
-- project path it names,
-- which project paths its other remotes name, and which worktrees it has.
-- Imports config and spawn. The lookups run git through spawn's blocking form,
-- because the dashboard cannot draw its sections before it knows them and each
-- answers from the local clone in well under a second; the assembly and the
-- parsing are pure functions, and those are what the suite tests.
--
-- The binding lives in git config, which in the bare-clone layout is
-- `.bare/config`: every config call here runs with the root as its working
-- directory and `extensions.worktreeConfig` is never set, so the value is
-- shared by every worktree of the clone, including ones created later.

local config = require("docket.config")
local spawn = require("docket.spawn")

local M = {}

-- The directory git-wt-clone puts the bare clone in.
M.BARE_DIR = ".bare"
-- The command that binds a repository, and the one that lists the keys to
-- bind it to. Printed wherever the binding is missing.
M.BIND_COMMAND = "git config --add dotfiles.jira.project <KEY>"
-- `--paginate` because the listing stops at 30 projects without it.
M.LIST_COMMAND = "acli jira project list --paginate"
-- A work item key, capturing its project: the shape jira.KEY and
-- commands.KEY spell, which the suite holds to env.KEY_PATTERN. An epic is
-- bound by its key, and the key names the epic's project.
M.KEY = "^(%u[%u%d]+)%-%d+$"

local function git(cwd, ...)
  return spawn.wait({ "git", ... }, { cwd = cwd, timeout = config.options.timeouts.git })
end

--- Finds the clone a directory belongs to.
---
--- `--git-common-dir` is `.bare` from any worktree of a bare-clone layout and
--- `.git` from a plain clone; its parent is the root either way. git prints
--- it relative to the working directory from the main worktree, so it is
--- resolved before its parent is taken.
---@param cwd string
---@return { root: string, bare: boolean }|nil repo
---@return string|nil err
function M.root(cwd)
  local result = git(cwd, "rev-parse", "--git-common-dir")
  if not result.ok then
    return nil, spawn.message(result)
  end
  local common = vim.trim(result.stdout)
  if common:sub(1, 1) ~= "/" then
    common = cwd .. "/" .. common
  end
  common = vim.uv.fs_realpath(common) or common
  return { root = vim.fs.dirname(common), bare = vim.fs.basename(common) == M.BARE_DIR }
end

-- `git config` exits 1 for a key that is not set and writes nothing to
-- stderr, which is an answer rather than a failure; anything else is one.
local function config_value(root, ...)
  local result = git(root, "config", ...)
  if result.ok then
    return vim.trim(result.stdout)
  end
  if result.code == 1 and result.stderr == "" then
    return nil
  end
  return nil, spawn.message(result)
end

-- `dotfiles.jira.epic`: nil when it is not set or empty, the key when it is
-- one, and an error naming the value and the command that clears it when it
-- is not, because a value that is no key would reach a query as written.
local function epic_of(root)
  local epic, err = config_value(root, "--get", "dotfiles.jira.epic")
  if err then
    return nil, err
  end
  if not epic or epic == "" then
    return nil
  end
  if not epic:match(M.KEY) then
    return nil,
      ("dotfiles.jira.epic is %s, which is not a work item key such as PROJ-142; git config --unset dotfiles.jira.epic clears it"):format(
        epic
      )
  end
  return epic
end

--- Reads the repository's Jira binding, in the resolution order:
---
---  1. `dotfiles.jira.jql`, a complete query used as given, with
---     `dotfiles.jira.epic` read beside it so that sections() can say the
---     epic narrows nothing there;
---  2. `dotfiles.jira.project`, one or more keys, and `dotfiles.jira.epic`,
---     an epic's key, each alone or both together, assembled by clause();
---     with the epic alone, the projects are the one its key names;
---  3. `dotfiles.jira.ignore`, set on a repository with no Jira, so that its
---     absence stops being reported; read only when neither the projects nor
---     the epic is set, so either binds the clone whatever it says;
---  4. nothing set: unbound.
---
--- A project key is never derived from the remote URL. A repository named
--- `platform-utils` is not project `PLATFORM-UTILS`, and a query that returns
--- nothing is indistinguishable from a missing login. An epic that is not a
--- work item key is the error, with the command that clears it.
---@param root string
---@return { kind: string, jql: string|nil, projects: string[]|nil, epic: string|nil }|nil binding
---@return string|nil err
function M.binding(root)
  local jql, err = config_value(root, "--get", "dotfiles.jira.jql")
  if err then
    return nil, err
  end
  local epic
  if jql and jql ~= "" then
    epic, err = epic_of(root)
    if err then
      return nil, err
    end
    return { kind = "jql", jql = jql, epic = epic }
  end

  local projects
  projects, err = config_value(root, "--get-all", "dotfiles.jira.project")
  if err then
    return nil, err
  end
  epic, err = epic_of(root)
  if err then
    return nil, err
  end
  if projects and projects ~= "" then
    return { kind = "projects", projects = vim.split(projects, "\n", { trimempty = true }), epic = epic }
  end
  if epic then
    return { kind = "projects", projects = { epic:match(M.KEY) }, epic = epic }
  end

  local ignore
  ignore, err = config_value(root, "--type=bool", "dotfiles.jira.ignore")
  if err then
    return nil, err
  end
  if ignore == "true" then
    return { kind = "ignored" }
  end

  return { kind = "unbound" }
end

--- The clause a binding supplies for config.PLACEHOLDER:
--- `project IN (PAY, OPS)`, and with an epic
--- `project IN (PAY) AND parent = PAY-10`, which lists the epic's children.
--- The project clause stays beside the epic so that every row is a ticket of
--- a bound project, the only kind the launcher builds a worktree for: a child
--- filed in another project is left off.
--- UNVERIFIED against a Jira instance: that a child's sub-tasks, whose parent
--- is the child, are left off too. This lists a row of a sub-task type when
--- they are not:
---
---   acli jira workitem search --jql 'parent = <epic>' --fields key,issuetype,status --json
---@param binding table
---@return string|nil clause nil when the binding supplies none
function M.clause(binding)
  if binding.kind == "projects" then
    local clause = "project IN (" .. table.concat(binding.projects, ", ") .. ")"
    if binding.epic then
      clause = clause .. " AND parent = " .. binding.epic
    end
    return clause
  end
  return nil
end

-- The placeholder as a pattern: `<` and `>` are plain, but a placeholder
-- changed to carry a magic character would otherwise break silently.
local function placeholder_pattern()
  return (config.PLACEHOLDER:gsub("%p", "%%%0"))
end

--- One Jira section's query under a binding.
---
--- A binding by project, with its epic or without, fills the placeholder
--- with clause(). A complete query is returned as given. Unbound, the
--- placeholder stands for a constraint being lifted, so the correct rewrite
--- sets it to true; `AND` binds tighter than `OR` in JQL, so `x AND true`
--- collapses to `x` at any position in an `AND` chain, and the placeholder
--- is dropped together with the `AND` joining it. The query then spans every
--- project the account can see; only a template scoped to the account by
--- `currentUser()` is allowed to, which is why the section is labelled and
--- the worktree action refuses there. A placeholder joined by `OR` is
--- refused: `a OR true` is every work item in the instance, and dropping the
--- disjunct gives `a`, which is not the query written either, so nothing
--- runs. JQL keywords are case-insensitive, so `and` matches too.
---@param template string
---@param binding table
---@return string|nil query nil for a binding that shows no ticket sections, or for a template whose placeholder cannot be dropped
---@return string|nil err
function M.jql(template, binding)
  if binding.kind == "jql" then
    return binding.jql
  end
  if binding.kind == "projects" then
    return (template:gsub(placeholder_pattern(), M.clause(binding)))
  end
  if binding.kind == "unbound" then
    local ph = placeholder_pattern()
    local query = template:gsub("^" .. ph .. "%s+[Aa][Nn][Dd]%s+", ""):gsub("%s+[Aa][Nn][Dd]%s+" .. ph, "")
    if query:find(config.PLACEHOLDER, 1, true) then
      return nil,
        ("%s: the placeholder is not joined to the rest by AND, so it cannot be dropped for an unbound repository"):format(
          template
        )
    end
    if not query:find("currentUser()", 1, true) then
      return nil,
        ("%s: with no project bound this would search every project the account can see, so only a query scoped to the account by currentUser() runs unbound"):format(
          template
        )
    end
    return query
  end
  return nil
end

-- The section that stands in for a missing binding: rows for the account
-- itself, since across every project that is the only query with a usable
-- answer. It is picked from the configured list by the clause that names the
-- account rather than by title, so a renamed section still qualifies: the
-- assignee clause first, then any clause naming the account. With neither,
-- the first Jira section is returned and jql() refuses its template, so the
-- dashboard shows the reason rather than a search of every project.
local function assigned_section(sections)
  for _, needle in ipairs({ "assignee = currentUser()", "currentUser()" }) do
    for _, section in ipairs(sections) do
      if section.adapter == "jira" and section.query:find(needle, 1, true) then
        return section
      end
    end
  end
  for _, section in ipairs(sections) do
    if section.adapter == "jira" then
      return section
    end
  end
  return nil
end

--- The sections the dashboard shows, from the configured list.
---
--- Bound by project, every section appears with its placeholder filled.
--- Bound by a complete query, the first Jira section runs it as given and
--- the others are left out: they differ only in the clause they add to the
--- placeholder, and a complete query has no placeholder to add it to. An
--- epic bound beside a complete query narrows nothing, so that section
--- carries a `reason` saying so and naming the clause to put in the query.
--- Ignored, the Jira sections are left out. Unbound, one Jira section shows
--- the account's own tickets across every project, labelled as unbound and
--- carrying the binding command as its `reason`.
---
--- `review` is the adapter the remote selected, as `{ adapter = "glab" }`,
--- or `{ reason = "..." }` when it selected none; the review sections then
--- take the client's own query, or are replaced by one section stating the
--- reason.
---@param binding table
---@param configured table[] the section list from config
---@param review { adapter: string|nil, reason: string|nil }
---@return table[] sections
function M.sections(binding, configured, review)
  local shown = {}

  if binding.kind == "unbound" then
    local base = assigned_section(configured)
    if base then
      local query, err = M.jql(base.query, binding)
      shown[#shown + 1] = {
        title = base.title .. " (unbound)",
        adapter = "jira",
        query = query,
        unbound = true,
        reason = err or ("rows come from every project; bind this repository with\n  %s\n%s lists the keys"):format(
          M.BIND_COMMAND,
          M.LIST_COMMAND
        ),
      }
    end
  end

  local jql_taken = false
  for _, section in ipairs(configured) do
    if section.adapter == "jira" then
      if binding.kind == "projects" or (binding.kind == "jql" and not jql_taken) then
        jql_taken = true
        local query, reason = M.jql(section.query, binding)
        if not reason and binding.kind == "jql" and binding.epic then
          reason = ("dotfiles.jira.epic is %s, and dotfiles.jira.jql runs as written, so the epic narrows nothing; put parent = %s into the query"):format(
            binding.epic,
            binding.epic
          )
        end
        shown[#shown + 1] = {
          title = section.title,
          adapter = "jira",
          query = query,
          reason = reason,
        }
      end
    elseif section.adapter == "review" then
      if review.adapter then
        shown[#shown + 1] = {
          title = section.title,
          adapter = review.adapter,
          query = section.query[review.adapter],
        }
      end
    else
      shown[#shown + 1] = section
    end
  end

  if not review.adapter then
    shown[#shown + 1] = { title = "Reviews", adapter = nil, query = nil, reason = review.reason }
  end

  return shown
end

-- The host in a remote URL: `scheme://[user@]host[:port]/path`, or the
-- scp-like `[user@]host:path`. A local path names no host.
local function host_of(url)
  local host = url:match("^%a[%w+.-]*://([^/]+)")
  if host then
    host = host:gsub("^[^@]*@", ""):gsub(":%d+$", "")
    return host
  end
  local rest = url:gsub("^[^@/:]+@", "")
  return rest:match("^([^/:]+):")
end

--- Chooses the review client from the remote's host, not the operating
--- system, so that one machine handles both.
---@param url string what `git remote get-url origin` printed
---@return string|nil adapter "glab" or "gh"
---@return string|nil reason why no review sections are shown
function M.adapter_for(url)
  local host = host_of(url)
  if not host then
    return nil, ("origin is %s, which names no host, so there are no review sections"):format(url)
  end
  local lowered = host:lower()
  if lowered:find("gitlab", 1, true) then
    return "glab"
  end
  if lowered:find("github", 1, true) then
    return "gh"
  end
  return nil, ("origin is on %s, which is neither GitLab nor GitHub, so there are no review sections"):format(host)
end

--- The path a remote URL names on its host, less a trailing `.git` and any
--- slash at either end: `acme/payments` for
--- `git@gitlab.example.com:acme/payments.git`, and for the same project over
--- `https://` or `ssh://` with a port. On GitLab that is the project's full
--- path, its group and subgroups included. UNVERIFIED against the instance:
--- phase 0 recorded no remote URL, so this rests on GitLab's usual clone
--- URLs. The item buffer's name carries the path, so a URL that spells one
--- project with the instance's path prefix names another buffer than one
--- without it, and `:e` with no reference is refused in the other's clone: an
--- instance served under a path prefix puts the prefix in its https URLs and
--- not in its ssh ones. The path keeps origin's case, `Acme/Payments` beside
--- `acme/payments`, and same_project() compares two paths without it. The
--- host is not in the path, so one path on two GitLab hosts names one buffer.
--- nil for a URL
--- that names no host, such as a local path, and for one whose path is
--- empty.
---@param url string what `git remote get-url origin` printed
---@return string|nil path
function M.project_of(url)
  if not host_of(url) then
    return nil
  end
  local path
  if url:match("^%a[%w+.-]*://") then
    path = url:match("^%a[%w+.-]*://[^/]+/(.*)$")
  else
    path = url:gsub("^[^@/:]+@", ""):match("^[^/:]+:(.*)$")
  end
  if not path then
    return nil
  end
  path = path:gsub("/+$", ""):gsub("%.git$", ""):gsub("^/+", "")
  if path == "" then
    return nil
  end
  return path
end

--- Whether two project paths name one project. Compared without case: an
--- item buffer's name keeps the case origin's URL spells the path in,
--- `Acme/Payments`, an answer writes it as the instance stores it, and GitLab
--- and GitHub each keep their paths unique whatever their case, so both
--- spell one project and a compare that saw case would refuse a correct read
--- from such a clone. The item buffer holds an answer's project against its
--- name's through this, and the dashboard holds a row's project against its
--- clone's. UNVERIFIED against the instance, which no payload has shown; a
--- clone by a path in another case succeeding is what shows it. An instance
--- served under a path prefix is what this does not cover: project_of() says
--- the prefix is in its https URLs and not in its ssh ones, so an answer,
--- which carries it, meets a name from an ssh origin that does not: every
--- read there is refused, and on the dash so is every `<CR>`, `w` and `R` on
--- a GitLab row, until origin is the https URL.
---@param a string
---@param b string
---@return boolean
function M.same_project(a, b)
  return a:lower() == b:lower()
end

--- The clause a refusal ends with when the clone's origin may spell the
--- project an address names another way than the instance writes it: an ssh
--- URL on an instance served under a path prefix, which same_project()
--- describes, or the path the project had before a move or a rename, which
--- the instance still resolves. The remedy is to point origin at the
--- project's https URL, made from the address's scheme and host and the path
--- it names; nil for an address that carries no scheme and host, where no
--- URL can be made. The item buffer's refusal of an answer naming another
--- project than its name and the dash's refusal of a row naming another
--- project than its clone's remotes both end with it, because neither
--- compare can tell such a clone from one of another project, so both
--- remedies are given.
---@param url any the address the answer or the row carries
---@param project string the path the address names
---@return string|nil clause
function M.set_url_remedy(url, project)
  local site = type(url) == "string" and url:match("^(https?://[^/]+)") or nil
  if not site then
    return nil
  end
  return ("; where origin spells this project another way -- an ssh URL without the instance's path prefix, or the path the project had before a move or a rename -- git remote set-url origin %s/%s.git makes the two agree"):format(
    site,
    project
  )
end

--- Reads origin's URL.
---@param root string
---@return string|nil url
---@return string|nil err
function M.remote_url(root)
  local result = git(root, "remote", "get-url", "origin")
  if not result.ok then
    return nil, spawn.message(result)
  end
  return vim.trim(result.stdout)
end

--- The project path of the clone a directory belongs to, which project_of()
--- reads off origin's URL. An item buffer on a backend whose identifiers are
--- numbered per project carries it in its name; buffer.lua says why.
---@param cwd string
---@return string|nil project
---@return string|nil err
function M.project(cwd)
  local found, err = M.root(cwd)
  if not found then
    return nil, err
  end
  local url
  url, err = M.remote_url(found.root)
  if not url then
    return nil, err
  end
  local path = M.project_of(url)
  if not path then
    return nil, ("origin is %s, which names no project"):format(url)
  end
  return path
end

--- Reads the remotes out of `git remote -v`: each once, with its fetch URL,
--- in the order git lists them. The push URL is left out, because the rows a
--- client lists and the branches the launcher asks origin for both come over
--- the fetch URL.
---@param text string
---@return { name: string, url: string }[]
function M.parse_remotes(text)
  local found = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name, url = line:match("^(%S+)%s+(%S+)%s+%(fetch%)$")
    if name then
      found[#found + 1] = { name = name, url = url }
    end
  end
  return found
end

--- Lists the clone's remotes, each with its fetch URL. The dash holds a
--- row's project against the path every one of them names, not origin's
--- alone, because the client that listed the rows picks its project from the
--- remotes on its own: in a clone `gh repo fork --clone` made, gh lists the
--- pull requests of `upstream`, whose path origin, the fork, does not carry.
--- UNVERIFIED against gh; `gh repo set-default --view` in such a clone prints
--- the repository gh resolves it to.
---@param root string
---@return { name: string, url: string }[]|nil remotes
---@return string|nil err
function M.remotes(root)
  local result = git(root, "remote", "-v")
  if not result.ok then
    return nil, spawn.message(result)
  end
  return M.parse_remotes(result.stdout)
end

--- Reads the worktree and branch pairs out of `git worktree list --porcelain`.
---
--- A detached worktree has no `branch` line and keeps `branch` nil.
---@param porcelain string
---@return { path: string, branch: string|nil }[]
function M.parse_worktrees(porcelain)
  local found, current = {}, nil
  for line in (porcelain .. "\n"):gmatch("(.-)\n") do
    local path = line:match("^worktree (.+)$")
    if path then
      current = { path = path }
      found[#found + 1] = current
    elseif current then
      local branch = line:match("^branch refs/heads/(.+)$")
      if branch then
        current.branch = branch
      end
    end
  end
  return found
end

--- Lists the clone's registered worktrees.
---@param root string
---@return { path: string, branch: string|nil }[]|nil worktrees
---@return string|nil err
function M.worktrees(root)
  local result = git(root, "worktree", "list", "--porcelain")
  if not result.ok then
    return nil, spawn.message(result)
  end
  return M.parse_worktrees(result.stdout)
end

--- The registered worktree whose branch begins `<KEY>-`, if there is one.
---
--- A summary can be edited after a worktree exists, so a second choice of the
--- same ticket would generate a different branch; the key prefix is what
--- finds the worktree already made for it.
---@param worktrees { path: string, branch: string|nil }[]
---@param key string
---@return { path: string, branch: string }|nil
function M.worktree_for_key(worktrees, key)
  local prefix = key .. "-"
  for _, worktree in ipairs(worktrees) do
    if worktree.branch and worktree.branch:sub(1, #prefix) == prefix then
      return worktree
    end
  end
  return nil
end

--- The registered worktree on exactly this branch, if there is one.
---@param worktrees { path: string, branch: string|nil }[]
---@param branch string
---@return { path: string, branch: string }|nil
function M.worktree_for_branch(worktrees, branch)
  for _, worktree in ipairs(worktrees) do
    if worktree.branch == branch then
      return worktree
    end
  end
  return nil
end

return M
