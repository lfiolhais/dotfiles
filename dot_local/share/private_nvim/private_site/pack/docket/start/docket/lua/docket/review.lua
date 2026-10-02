-- The review mode: a merge request's diff in diffview.nvim, the line comments
-- held against it until the review is submitted, and its existing discussions
-- drawn at the lines they belong to. Imports adapters, auth, config, flight,
-- highlight and spawn.
--
-- The diff is `:DiffviewOpen origin/<target>...HEAD --imply-local`, run in
-- the merge request's worktree, with the target branch from the adapter's
-- diff(). `...` diffs HEAD against its merge base with the target, which is
-- the change the merge request carries. `--imply-local` shows the end of the
-- range that is HEAD as the worktree's own files, so the language server
-- attaches to the new side and a comment there is placed from the file's own
-- path and line; diffview's own view is asked only for the old side.
-- UNVERIFIED: both the `A...B` form and `--imply-local` come from diffview's
-- README and help, and no diffview is within reach of the session that wrote
-- this. `:DiffviewOpen origin/<target>...HEAD` without the flag is the
-- fallback, which leaves the new side a diffview buffer that only locate()'s
-- first route finds.
--
-- A review is one batch. Comments are held here, in the editor, until the
-- review is submitted: nothing reaches the merge request while they are
-- written, and a review abandoned -- or an editor quit with comments held --
-- sends nothing. That is what octo.nvim does for GitHub. Submitting posts the
-- held comments one at a time through line_comment() and then applies the
-- verdict through submit(): nothing, an approval, a summary note, or both.
--
-- Every write verb in glab's note family is experimental and unexercised, so
-- a failure is expected rather than exceptional, and what it does to the
-- batch is decided in send(): the first failure stops the batch, and the
-- comment that failed stays held with every comment after it.
--
-- Existing discussions come from threads(), which leaves out the notes GitLab
-- wrote itself -- a status change, a force-push -- so the merge request's own
-- history is not drawn in front of the diff, and drops a discussion that held
-- nothing else. `individual` is GitLab's `individual_note`: a standalone
-- comment, which nobody can reply into, so reply() offers only threads.
-- `resolvable` and `resolved` are GitLab's own, so resolve() is offered only
-- where GitLab allows it. A body is markdown and is drawn as its own lines; it
-- never goes through adf, which is the Jira document tree alone.
--
-- A review is held in `reviews`, keyed by the worktree and the merge
-- request's identifier. Its fields:
--
--   key, source, id   the registry key, the adapter's name, `!482`
--   root              the worktree's top level, resolved through realpath
--   head, branch      HEAD's sha and branch name when the review was opened
--   base              the merge base of origin/<target> and HEAD, set when
--                     the diff opens
--   source_branch, target, refs, threads
--                     what diff() and threads() answered; `refs` is
--                     `{ base_sha, start_sha, head_sha }`
--   held              the comments in the order they were held, each
--                     `{ position, text, head, base }`; `position` is what
--                     line_comment() takes -- `{ file, line }` for the new
--                     side, `{ file, old_line }` for the old side,
--                     `{ thread }` for a reply -- and `head` and `base` are
--                     the versions it was placed against
--   tab               the tab diffview opened, nil until it has
--   marked, composing the buffers carrying this review's marks, and the
--                     compose buffers it has open, each by buffer number
--
-- One request per key is in flight, through flight.lua: a read of the merge
-- request, a submit, and a resolve of each thread. A second open joins the
-- read already running; a second submit is refused rather than joined, since
-- joining would drop the second caller's verdict unasked.
--
-- Every adapter callback arrives in a fast-event context, where a buffer, a
-- window, vim.fn and vim.notify all raise, so the callbacks here touch only
-- the review's own tables and schedule the rest. The module loads from a user
-- command, on the main loop, and still makes no call at load that would raise
-- in a fast event: the namespace and the autocommand group are created on
-- first use.

local adapters = require("docket.adapters")
local auth = require("docket.auth")
local config = require("docket.config")
local flight = require("docket.flight")
local highlight = require("docket.highlight")
local spawn = require("docket.spawn")

local M = {}

-- The command that opens a review, and the verbs the messages below name.
-- commands.lua dispatches them; a change to one is a change to both.
M.COMMAND = ":Docket review"
M.VERBS = {
  comment = ":Docket review comment",
  submit = ":Docket review submit",
  force = ":Docket! review submit",
}

-- The calls a review makes, each an adapter capability.
M.NEEDS = { "diff", "threads", "line_comment", "thread_resolve", "submit" }

-- What a machine without diffview.nvim is told, on one line.
M.NO_DIFFVIEW = "docket: the review mode shows its diff in diffview.nvim, which is not installed here"

-- The diffview flag that shows HEAD's end of the range as the worktree's own
-- files; the header says what it buys and that it is unverified.
M.IMPLY_LOCAL = "--imply-local"

-- The two sides of the diff.
M.NEW = "new"
M.OLD = "old"

-- The name a compose buffer takes. It is not `docket://`, because
-- plugin/docket.lua routes every write under that scheme to the item buffer.
M.SCHEME = "docket-review://"
M.COMPOSE_HEIGHT = 12

-- What the drawn discussions and held comments are made of.
M.BAR = "▍"
M.BODY_GROUP = "Comment"

local notify_levels = vim.log.levels
local unpack = unpack or table.unpack

local namespace = nil
local augroup = nil

-- The namespace the marks live in. Created on first use, on the main loop,
-- because nvim_create_namespace raises E5560 in a fast event.
local function ns()
  if namespace == nil then
    namespace = vim.api.nvim_create_namespace("docket/review")
  end
  return namespace
end

local function notify(message, level)
  vim.notify(message, level or notify_levels.INFO)
end

local function short(sha)
  if type(sha) ~= "string" or sha == "" then
    return "unknown"
  end
  return sha:sub(1, 8)
end

local function git(cwd, ...)
  return spawn.wait({ "git", ... }, { cwd = cwd, timeout = config.options.timeouts.git })
end

-- The worktree a directory is in, resolved through realpath so that two
-- spellings of one directory compare equal.
local function toplevel(cwd)
  local result = git(cwd, "rev-parse", "--show-toplevel")
  if not result.ok then
    return nil, spawn.message(result)
  end
  local top = vim.trim(result.stdout)
  return vim.uv.fs_realpath(top) or top
end

-- One line of git output, or nil and the reason.
local function git_line(cwd, ...)
  local result = git(cwd, ...)
  if not result.ok then
    return nil, spawn.message(result)
  end
  return vim.trim(result.stdout)
end

-- Leading and trailing blank lines dropped, the rest joined, as diff.lua
-- trims a region: a line opened above or below the text is not part of it.
local function trimmed(lines)
  local first, last = 1, #lines
  while first <= last and lines[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return table.concat(lines, "\n", first, last)
end

-- The registry -----------------------------------------------------------------

local reviews = {}

local function key_of(root, id)
  return root .. "\n" .. id
end

--- The review of a merge request in a worktree, made and registered when
--- there is none. Nothing is read: load() does that.
---@param source string the adapter's name
---@param id string `!482`
---@param root string the worktree's top level
---@return table review
function M.start(source, id, root)
  local key = key_of(root, id)
  local review = reviews[key]
  if not review then
    review = {
      key = key,
      source = source,
      id = id,
      root = root,
      held = {},
      threads = {},
      marked = {},
      composing = {},
    }
    reviews[key] = review
  end
  return review
end

--- What every adapter call a review makes is given in place of its
--- identifier: the reference adapters/init.lua describes, naming the
--- worktree. glab finds the project an iid belongs to from the directory it
--- runs in, so the review's calls run in its worktree rather than where the
--- last state check ran, which may be a tab in another clone, where the same
--- number is another merge request.
---@param review table
---@return { id: string, cwd: string } ref
function M.ref(review)
  return { id = review.id, cwd = review.root }
end

--- The review of a merge request in a worktree, or nil.
---@param root string
---@param id string
---@return table|nil review
function M.get(root, id)
  return reviews[key_of(root, id)]
end

--- The review whose diff is in the current tab.
---@return table|nil review
---@return string|nil err
function M.current()
  local tab = vim.api.nvim_get_current_tabpage()
  for _, review in pairs(reviews) do
    if review.tab == tab then
      return review
    end
  end
  return nil, ("no review in this tab; %s <id> opens one"):format(M.COMMAND)
end

-- In flight ------------------------------------------------------------------

-- A read of the merge request. What it answers is kept on the review, once,
-- before any waiter sees it; a review discarded while it read is refused
-- instead, so a late answer cannot bring it back.
local reading = flight.new({
  refusal = "the review was abandoned while the merge request was being read; nothing of it is kept",
  accept = function(key, data)
    local review = reviews[key]
    if review and data then
      review.source_branch = data.diff.source
      review.target = data.diff.target
      review.refs = data.diff.refs
      review.threads = data.threads
    end
  end,
})

-- A submit. Its key is never moved on: discard() refuses while one is in
-- flight, because the posts it has started land whatever happens here.
local submitting = flight.new({
  refusal = "the review was discarded while it was being submitted; what was posted is on the merge request",
})

-- A resolve, one per thread.
local resolving = flight.new({
  refusal = "the review was discarded while a thread was being resolved; the merge request says whether it was",
})

--- Reads the merge request: diff() for the branches and the shas, then
--- threads() for the discussions. A second call while one runs joins it.
---
--- on_done runs in the context the adapter answered in, which is a fast
--- event for every real client.
---@param review table
---@param adapter table
---@param on_done fun(ok: boolean, err: string|nil)
function M.load(review, adapter, on_done)
  reading:join(review.key, function(settle)
    local ref = M.ref(review)
    adapter.diff(ref, function(found, err)
      if not found then
        return settle(nil, err)
      end
      if type(found.target) ~= "string" or found.target == "" or type(found.refs) ~= "table" then
        return settle(nil, ("%s: the merge request names no target branch or no diff_refs"):format(review.id))
      end
      adapter.threads(ref, function(threads, threads_err)
        if not threads then
          return settle(nil, threads_err)
        end
        settle({ diff = found, threads = threads })
      end)
    end)
  end, function(data, err)
    on_done(data ~= nil, err)
  end)
end

-- Positions ------------------------------------------------------------------

--- A held comment's place, as the messages name it.
---@param position table what line_comment() takes
---@return string
function M.label(position)
  if position.thread then
    return ("the reply to %s"):format(short(tostring(position.thread)))
  end
  if position.old_line then
    return ("%s:%d on the old side"):format(position.file, position.old_line)
  end
  return ("%s:%d"):format(position.file, position.line)
end

-- The one comment a place holds: a new comment at a line, or a reply to a
-- thread. Holding a second at the same place replaces the first.
local function slot(position)
  if position.thread then
    return "thread:" .. tostring(position.thread)
  end
  if position.old_line then
    return ("old:%s:%d"):format(position.file, position.old_line)
  end
  return ("new:%s:%d"):format(position.file, position.line)
end

local function held_index(review, position)
  local wanted = slot(position)
  for index, entry in ipairs(review.held) do
    if slot(entry.position) == wanted then
      return index
    end
  end
  return nil
end

--- The comment held at a place, or nil.
---@param review table
---@param position table
---@return table|nil entry
function M.held_at(review, position)
  local index = held_index(review, position)
  return index and review.held[index] or nil
end

-- The worktree's HEAD is not the merge request's: a line numbered here is not
-- the line glab would place the comment on, since `--file` places it against
-- GitLab's latest version.
local function behind(review)
  return ("%s: the worktree is at %s and the merge request's head is %s, so a line numbered here is not the line a comment would land on. Bring the worktree to the head and open the review again:\n  %s\n  %s %s"):format(
    review.id,
    short(review.head),
    short(review.refs.head_sha),
    spawn.shell_line({ "git", "-C", review.root, "pull", "--ff-only", "origin", review.source_branch or "<branch>" }),
    M.COMMAND,
    review.id
  )
end

-- The merge base here is not the merge request's, so the old side here is
-- another version of each file than GitLab's.
local function other_base(review)
  return ("%s: the diff here starts from %s and the merge request's starts from %s, so a line numbered on the old side here is not the line a comment would land on. Fetch the target branch and open the review again:\n  %s\n  %s %s"):format(
    review.id,
    short(review.base),
    short(review.refs.base_sha),
    spawn.shell_line({ "git", "-C", review.root, "fetch", "origin", review.target or "<target>" }),
    M.COMMAND,
    review.id
  )
end

--- Whether a comment can be held at a place: a line of the new side needs
--- the worktree at the merge request's head, a line of the old side the same
--- merge base as GitLab's. A reply is placed by its thread and needs neither.
---@param review table
---@param position table
---@return boolean ok
---@return string|nil reason
function M.check(review, position)
  if position.thread then
    return true, nil
  end
  if not review.refs then
    return false, ("%s: the merge request has not been read; %s %s reads it"):format(review.id, M.COMMAND, review.id)
  end
  if position.line and review.head ~= review.refs.head_sha then
    return false, behind(review)
  end
  if position.old_line and review.base ~= review.refs.base_sha then
    return false, other_base(review)
  end
  return true, nil
end

--- Holds a comment at a place, replacing one already held there. Empty text
--- drops the comment held there instead, which is how a held comment is
--- withdrawn. Nothing is sent.
---
--- Refused while a submit is in flight: the batch it is posting is a copy of
--- what was held when it started, and a comment changed under it would be
--- posted as it was and then held again as it is.
---@param review table
---@param position table what line_comment() takes
---@param text string markdown
---@return boolean ok
---@return string message
function M.hold(review, position, text)
  if submitting:pending(review.key) then
    return false, ("%s: a submit is in flight; nothing is held or dropped until it reports"):format(review.id)
  end
  local label = M.label(position)
  local index = held_index(review, position)
  if text == "" then
    if not index then
      return true, ("%s: nothing is held at %s"):format(review.id, label)
    end
    table.remove(review.held, index)
    return true, ("%s: dropped the comment held at %s; %d held"):format(review.id, label, #review.held)
  end
  local ok, reason = M.check(review, position)
  if not ok then
    return false, reason
  end
  local entry = { position = vim.deepcopy(position), text = text, head = review.head, base = review.base }
  if index then
    review.held[index] = entry
    return true, ("%s: replaced the comment held at %s; %d held"):format(review.id, label, #review.held)
  end
  review.held[#review.held + 1] = entry
  return true, ("%s: held at %s; %d held, and %s sends them"):format(review.id, label, #review.held, M.VERBS.submit)
end

--- The held comments whose place no longer matches the merge request: a
--- line of the new side held against another head, a line of the old side
--- against another merge base. Replies are placed by their thread and never
--- are.
---@param held table[]
---@param refs { base_sha: string, head_sha: string }
---@return table[] stale
function M.stale(held, refs)
  local found = {}
  for _, entry in ipairs(held) do
    local position = entry.position
    if (position.line and entry.head ~= refs.head_sha) or (position.old_line and entry.base ~= refs.base_sha) then
      found[#found + 1] = entry
    end
  end
  return found
end

-- Submitting -----------------------------------------------------------------

local function remove_entry(review, entry)
  for index, held in ipairs(review.held) do
    if held == entry then
      table.remove(review.held, index)
      return
    end
  end
end

-- Where the merge request is on the web, for a message that asks for it to
-- be checked; the adapter's url() is a lookup, and one it cannot answer
-- leaves a description in its place.
local function where(adapter, id)
  local ok, url = pcall(adapter.url, { id = id })
  if ok and type(url) == "string" then
    return url
  end
  return "the merge request on the web"
end

local function labels(entries)
  local found = {}
  for _, entry in ipairs(entries) do
    found[#found + 1] = "  " .. M.label(entry.position)
  end
  return table.concat(found, "\n")
end

--- Submits a review: the held comments, then the verdict.
---
--- A comment held on a line is placed by glab against the merge request's
--- current version, so the merge request is read again first, and when it has
--- moved since a comment was placed nothing is sent: the line would land on
--- whatever the new version holds there. `verdict.force` posts them anyway.
---
--- Then each held comment goes through line_comment() in the order it was
--- held, one at a time, and leaves `held` as its post succeeds. The first
--- failure stops the batch: the comment that failed stays held with every
--- comment after it, and no verdict is applied. That is decided rather than
--- inherited, for three reasons. Every write verb in glab's note family is
--- experimental and unexercised, so a failure is most likely the verb itself --
--- a flag it no longer takes, an output it changed -- which every later call
--- would meet as well, and going on would turn one error into one per comment.
--- A verdict applied over part of a batch tells the author the review is
--- complete when it is not, and an approval is the worst form of that. And
--- because each posted comment has already left `held`, a second submit sends
--- exactly what is still held and nothing twice -- except the comment that
--- failed, if it failed after the merge request took it, which the message
--- says.
---
--- Once every comment is posted the verdict goes through the adapter's
--- submit(), in two calls: a summary note when `verdict.summary` holds text,
--- then an approval when `verdict.approve` is set, and nothing more when
--- neither is. They are two calls so that an approval refused after the
--- summary went out is known as that: on_done is then given `summary_sent`,
--- and the summary's compose buffer closes rather than staying modified for a
--- `:w` that would post the summary a second time. The approval carries the
--- head the diff was opened at, `head`, so GitLab refuses it when the merge
--- request has moved since.
---
--- on_done runs in the context the adapter answered in.
---@param review table
---@param adapter table
---@param verdict { approve: boolean|nil, summary: string|nil, force: boolean|nil }|nil
---@param on_done fun(ok: boolean, message: string, summary_sent: boolean|nil)
function M.send(review, adapter, verdict, on_done)
  verdict = verdict or {}
  if submitting:pending(review.key) then
    return on_done(false, ("%s: a submit is already in flight; its report comes when it ends"):format(review.id))
  end
  local summary = type(verdict.summary) == "string" and verdict.summary ~= "" and verdict.summary or nil
  local approve = verdict.approve == true
  -- A copy, so that what is posted is what was held when the submit started;
  -- hold() refuses while it runs.
  local batch = {}
  for index, entry in ipairs(review.held) do
    batch[index] = entry
  end
  if #batch == 0 and not approve and not summary then
    return on_done(false, ("%s: nothing is held and no verdict was given, so nothing was sent"):format(review.id))
  end

  -- Taken once, when the submit starts, and given to every call it makes.
  local ref = M.ref(review)
  local head = review.shown or review.head
  submitting:join(review.key, function(settle)
    local function unapplied(err)
      settle(false, ("%s: %d held comment(s) posted; the verdict was not applied\n%s"):format(review.id, #batch, tostring(err)))
    end

    local function succeeded()
      local parts = {}
      if #batch > 0 then
        parts[#parts + 1] = ("posted %d comment(s)"):format(#batch)
      end
      if summary then
        parts[#parts + 1] = "posted the summary"
      end
      if approve then
        parts[#parts + 1] = "approved"
      end
      settle(true, ("%s: %s"):format(review.id, table.concat(parts, ", ")))
    end

    local function approval(summary_sent)
      if not approve then
        return succeeded()
      end
      adapter.submit(ref, { approve = true, head = head }, function(ok, err)
        if ok then
          return succeeded()
        end
        if not summary_sent then
          return unapplied(err)
        end
        settle(
          false,
          ("%s: %s posted; the approval was not. %s approve approves alone\n%s"):format(
            review.id,
            #batch > 0 and ("%d comment(s) and the summary"):format(#batch) or "the summary",
            M.VERBS.submit,
            tostring(err)
          ),
          true
        )
      end)
    end

    local function conclude()
      if not summary then
        return approval(false)
      end
      adapter.submit(ref, { summary = summary }, function(ok, err)
        if not ok then
          return unapplied(err)
        end
        approval(true)
      end)
    end

    local function post(index)
      if index > #batch then
        return conclude()
      end
      local entry = batch[index]
      adapter.line_comment(ref, entry.position, entry.text, function(ok, err)
        if not ok then
          return settle(
            false,
            ("%s: %d of %d held comment(s) posted. The one at %s failed, and it and the %d held after it are still held; no verdict was applied. %s sends what is still held. A failure that came after the merge request took the comment -- a timeout, typically -- would post it twice, so check %s first.\n%s"):format(
              review.id,
              index - 1,
              #batch,
              M.label(entry.position),
              #batch - index,
              M.VERBS.submit,
              where(adapter, review.id),
              tostring(err)
            )
          )
        end
        remove_entry(review, entry)
        post(index + 1)
      end)
    end

    local placed = false
    for _, entry in ipairs(batch) do
      if not entry.position.thread then
        placed = true
      end
    end
    if verdict.force or not placed then
      return post(1)
    end
    adapter.diff(ref, function(found, err)
      if not found then
        return settle(
          false,
          ("%s: nothing was sent, because the merge request could not be read again to check the held lines still match it\n%s"):format(
            review.id,
            tostring(err)
          )
        )
      end
      if type(found.refs) ~= "table" then
        return settle(
          false,
          ("%s: nothing was sent, because the merge request carries no diff_refs to check the held lines against; %s posts them unchecked"):format(
            review.id,
            M.VERBS.force
          )
        )
      end
      local stale = M.stale(batch, found.refs)
      if #stale > 0 then
        return settle(
          false,
          ("%s: nothing was sent. The merge request has moved since these comments were placed -- its head is now %s -- and glab places each line on its current version, where the line may hold something else. Bring the worktree to the head, open the review again and hold them at their new lines, where writing a held comment's buffer empty drops the old one; or %s posts them at the same numbers anyway.\n%s"):format(
            review.id,
            short(found.refs.head_sha),
            M.VERBS.force,
            labels(stale)
          )
        )
      end
      post(1)
    end)
  end, function(ok, message, summary_sent)
    on_done(ok == true, message, summary_sent == true or nil)
  end)
end

--- Resolves a discussion, when GitLab allows it and it is not resolved
--- already. A second resolve of the same thread while one runs joins it.
---
--- on_done runs in the context the adapter answered in.
---@param review table
---@param adapter table
---@param thread table one of `review.threads`
---@param on_done fun(ok: boolean, message: string)
function M.resolve_thread(review, adapter, thread, on_done)
  if not thread.resolvable then
    return on_done(false, ("%s: the thread %s cannot be resolved"):format(review.id, short(thread.id)))
  end
  if thread.resolved then
    return on_done(false, ("%s: the thread %s is resolved already"):format(review.id, short(thread.id)))
  end
  resolving:join(review.key .. "\n" .. thread.id, function(settle)
    adapter.thread_resolve(M.ref(review), thread.id, function(ok, err)
      settle(ok, err)
    end)
  end, function(ok, err)
    if ok then
      thread.resolved = true
      return on_done(true, ("%s: resolved the thread %s"):format(review.id, short(thread.id)))
    end
    on_done(false, ("%s: the thread %s was not resolved\n%s"):format(review.id, short(thread.id), tostring(err)))
  end)
end

-- Drawing --------------------------------------------------------------------

--- The line of a side of a file a discussion is drawn at, or nil.
---
--- `position` is the first note's, as GitLab sent it: `new_path` and
--- `new_line` for a line the change added or kept, `old_path` and `old_line`
--- for one it removed; a kept line carries both and is drawn on the new side.
--- UNVERIFIED: the run against the instance recorded that a note carries
--- `position`, not the fields inside it, which come from GitLab's REST
--- reference; a thread whose position carries none of them is drawn at no
--- line, and `:Docket <id>` still shows it with the merge request's comments.
---
--- A discussion placed on another version of the diff than the one shown is
--- drawn at no line either: its line numbers are that version's, and on this
--- one they can hold something else. GitLab moves a diff note's `position` to
--- the new version when a push leaves its line as it was, and leaves an
--- outdated one's where it was, `head_sha` included. UNVERIFIED: that rule is
--- read from GitLab's source, Discussions::UpdateDiffPositionService, and no
--- `position` payload from the instance has been seen; a thread drawn at no
--- line after a push that did not touch it is the symptom of it being wrong.
---@param thread table
---@param loc { path: string, old_path: string|nil, side: string, head: string|nil }
---@return integer|nil line
function M.thread_line(thread, loc)
  local position = thread.position
  if type(position) ~= "table" then
    return nil
  end
  if M.elsewhere(thread, loc.head) then
    return nil
  end
  local new_line, old_line = tonumber(position.new_line), tonumber(position.old_line)
  if loc.side == M.NEW then
    if new_line and position.new_path == loc.path then
      return new_line
    end
  elseif old_line and not new_line and position.old_path == (loc.old_path or loc.path) then
    return old_line
  end
  return nil
end

--- Whether a discussion is placed on another version of the diff than the one
--- at `head`: its position names a head, and not that one.
---@param thread table
---@param head string|nil
---@return boolean
function M.elsewhere(thread, head)
  local position = thread.position
  return type(position) == "table"
    and type(position.head_sha) == "string"
    and type(head) == "string"
    and position.head_sha ~= head
end

--- The discussions drawn at a line of a side of a file.
---@param review table
---@param loc table
---@param line integer
---@return table[] threads
function M.threads_at(review, loc, line)
  local found = {}
  for _, thread in ipairs(review.threads or {}) do
    if M.thread_line(thread, loc) == line then
      found[#found + 1] = thread
    end
  end
  return found
end

local function who(person)
  if type(person) ~= "table" then
    return "someone"
  end
  return person.name or person.id or "someone"
end

-- A body as the lines under its header, each behind the bar. A tab is
-- widened, since virtual text draws it as a single cell.
local function body_lines(text)
  local lines = {}
  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local shown = line:gsub("\r$", ""):gsub("\t", "    ")
    lines[#lines + 1] = { { M.BAR .. "   " .. shown, M.BODY_GROUP } }
  end
  return lines
end

local function thread_lines(thread)
  local lines = {}
  for index, note in ipairs(thread.notes or {}) do
    local header = { { M.BAR .. " ", M.BODY_GROUP }, { who(note.author), highlight.USER } }
    if index == 1 and thread.resolvable then
      if thread.resolved then
        header[#header + 1] = { "  resolved", highlight.OPEN }
      else
        header[#header + 1] = { "  unresolved", highlight.PENDING }
      end
    end
    lines[#lines + 1] = header
    vim.list_extend(lines, body_lines(note.body))
  end
  return lines
end

local function held_lines(entry, what)
  local lines = { { { M.BAR .. " ", highlight.LABEL }, { what .. ", not sent", highlight.LABEL } } }
  vim.list_extend(lines, body_lines(entry.text))
  return lines
end

--- What is drawn on one side of one file: each discussion at its line, with
--- the replies held to it under it, then each comment held at a line. Each
--- is `{ line, lines }`, `lines` being virt_lines chunks. Pure, so the
--- placement is tested without a diff.
---@param threads table[]
---@param held table[]
---@param loc { path: string, old_path: string|nil, side: string }
---@return { line: integer, lines: table[] }[]
function M.marks(threads, held, loc)
  local replies = {}
  for _, entry in ipairs(held) do
    local thread = entry.position.thread
    if thread then
      replies[thread] = replies[thread] or {}
      table.insert(replies[thread], entry)
    end
  end
  local found = {}
  for _, thread in ipairs(threads or {}) do
    local line = M.thread_line(thread, loc)
    if line then
      local lines = thread_lines(thread)
      for _, reply in ipairs(replies[thread.id] or {}) do
        vim.list_extend(lines, held_lines(reply, "reply"))
      end
      found[#found + 1] = { line = line, lines = lines }
    end
  end
  for _, entry in ipairs(held) do
    local position = entry.position
    if position.file == loc.path then
      local line = (loc.side == M.NEW and position.line) or (loc.side == M.OLD and position.old_line) or nil
      if line then
        found[#found + 1] = { line = line, lines = held_lines(entry, "comment") }
      end
    end
  end
  return found
end

-- The view diffview shows in the current tab, or nil. UNVERIFIED:
-- `diffview.lib`'s get_current_view() and the view's fields read in locate()
-- are diffview's internals, read from its source rather than from any
-- documented interface, and not exercised here. Everything that reads them is
-- under pcall, and the fallback is the worktree-file route, which covers the
-- new side alone.
local function diffview_view()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok or type(lib) ~= "table" or type(lib.get_current_view) ~= "function" then
    return nil
  end
  local got, view = pcall(lib.get_current_view)
  if got and type(view) == "table" then
    return view
  end
  return nil
end

--- Which side of which file a buffer shows, or nil for one that is no side
--- of the diff: diffview's file panel, a compose buffer, a help window.
---
--- Diffview's view is asked first: the window of its current layout whose
--- file is this buffer, `a` being the old side and `b` the new, and the
--- current entry's `path` and `oldpath`. A view that is this review's tab and
--- shows the buffer in neither window answers nil: a file of the worktree
--- opened in a split beside the diff is not the diff, and a comment held there
--- could be on a line the merge request does not touch. Only when no view
--- answers for the tab is a buffer holding a file of the worktree the new
--- side, which is what `--imply-local` makes of HEAD's end of the range.
---
--- `path` is the file's path from the worktree's top level, which is what
--- `--file` takes, and on the old side too: glab names the diff's file by it.
--- UNVERIFIED: an old-side comment on a renamed file has not been placed; its
--- old path, `old_path` here, is what a `discussions` position through `glab
--- api` would carry instead.
---
--- `local_file` is set when the buffer is the file itself, whose unsaved and
--- uncommitted changes move its lines off HEAD's. `head` is the version the
--- diff shows, which a discussion's own head is compared with; see
--- thread_line().
---@param review table
---@param buf integer
---@return { path: string, old_path: string|nil, side: string, local_file: boolean, head: string|nil }|nil loc
function M.locate(review, buf)
  local head = review.shown or review.head
  local view = diffview_view()
  if view then
    local ok, loc = pcall(function()
      if view.tabpage ~= nil and view.tabpage ~= review.tab then
        return nil
      end
      local entry = view.cur_entry
      local layout = view.cur_layout or (type(entry) == "table" and entry.layout) or nil
      if type(entry) ~= "table" or type(layout) ~= "table" or type(entry.path) ~= "string" then
        return nil
      end
      for symbol, side in pairs({ a = M.OLD, b = M.NEW }) do
        local win = layout[symbol]
        if type(win) == "table" and type(win.file) == "table" and win.file.bufnr == buf then
          return {
            path = entry.path,
            old_path = type(entry.oldpath) == "string" and entry.oldpath or entry.path,
            side = side,
            local_file = vim.bo[buf].buftype == "",
            head = head,
          }
        end
      end
      -- This tab's view, and the buffer is on neither side of it.
      if view.tabpage == review.tab then
        return false
      end
      return nil
    end)
    if ok and loc == false then
      return nil
    end
    if ok and loc then
      return loc
    end
  end
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(name) or name
  local prefix = review.root .. "/"
  if real:sub(1, #prefix) ~= prefix then
    return nil
  end
  return { path = real:sub(#prefix + 1), side = M.NEW, local_file = true, head = head }
end

local function clear_marks(review)
  if namespace == nil then
    review.marked = {}
    return
  end
  for buf in pairs(review.marked) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    end
  end
  review.marked = {}
end

--- Draws the review into every window of its tab that shows a side of the
--- diff: the discussions at their lines and the held comments at theirs, as
--- virtual lines under each. Runs only while the review's tab is current,
--- because diffview answers for the current tab alone; the autocommands draw
--- it again on entering the tab and on every buffer a window of it shows.
--- UNVERIFIED: whether diffview pads the other side of the diff for virtual
--- lines, so that the two sides stay aligned, has not been seen.
---@param review table
function M.decorate(review)
  if not (review.tab and vim.api.nvim_tabpage_is_valid(review.tab)) then
    return
  end
  if vim.api.nvim_get_current_tabpage() ~= review.tab then
    return
  end
  local space = ns()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review.tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local loc = M.locate(review, buf)
    if loc then
      vim.api.nvim_buf_clear_namespace(buf, space, 0, -1)
      review.marked[buf] = true
      local count = vim.api.nvim_buf_line_count(buf)
      for _, mark in ipairs(M.marks(review.threads, review.held, loc)) do
        -- A line past the end is a discussion placed on a version of the file
        -- longer than this one; it is drawn at the last line rather than lost.
        local row = math.min(math.max(mark.line, 1), count) - 1
        vim.api.nvim_buf_set_extmark(buf, space, row, 0, { virt_lines = mark.lines })
      end
    end
  end
end

-- The autocommands that keep the drawing current, made once, on the main
-- loop. BufWinEnter and TabEnter cover every buffer diffview puts in a window
-- and every return to the tab. The two User events are diffview's own, from
-- its help and UNVERIFIED here; the drawing does not depend on them firing.
-- The review's keys do: commands.lua puts the review's `g?` back on
-- `DiffviewDiffBufWinEnter`, after diffview has set its own again on a file
-- it reopened in the window already showing it, and its review_autocommands()
-- says why. TabClosed takes the marks out of the files a closed diff drew
-- into, since those buffers outlive it.
local function autocommands()
  if augroup ~= nil then
    return augroup
  end
  augroup = vim.api.nvim_create_augroup("docket/review", { clear = true })
  local function redraw()
    local tab = vim.api.nvim_get_current_tabpage()
    for _, review in pairs(reviews) do
      if review.tab == tab then
        vim.schedule(function()
          M.decorate(review)
        end)
      end
    end
  end
  vim.api.nvim_create_autocmd({ "BufWinEnter", "TabEnter" }, { group = augroup, callback = redraw })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewEnter" },
    callback = redraw,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      for _, review in pairs(reviews) do
        if review.tab and not vim.api.nvim_tabpage_is_valid(review.tab) then
          review.tab = nil
          clear_marks(review)
        end
      end
    end,
  })
  return augroup
end

-- Composing ------------------------------------------------------------------

local function named(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

-- Closes a compose buffer's windows and wipes it, after the write command
-- that asked for it has returned: a buffer is not deleted from inside its
-- own BufWriteCmd.
local function close_compose(review, buf)
  review.composing[buf] = nil
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end

-- The adapter for a write, after the state check every mode makes first.
-- The calls themselves carry the worktree in M.ref(), so where they go does
-- not depend on the tab. The state check does: it runs `glab auth status` in
-- the tab's directory, and glab checks the account of the GitLab instance
-- that directory's remote names, or of its default host outside a
-- repository. So the tab has to be in the review's worktree, or the check
-- answers for another host, and its `not signed in` would name a login to
-- that host rather than to the one the merge request is on.
local function ready(review)
  local cwd = vim.fn.getcwd()
  local top, err = toplevel(cwd)
  if not top then
    return nil, ("%s: %s is in no repository, so glab's state check there is not about the host %s is on; :tcd %s and run it again\n%s"):format(
      review.id,
      cwd,
      review.id,
      vim.fn.fnameescape(review.root),
      err
    )
  end
  if top ~= review.root then
    return nil, ("%s: this tab is in %s, not in %s, where the review was opened; :tcd %s and run it again"):format(
      review.id,
      top,
      review.root,
      vim.fn.fnameescape(review.root)
    )
  end
  return auth.ready(review.source)
end

-- Runs after a submit has reported, on the main loop: the held comments that
-- were posted leave the drawing, and when anything reached the merge request
-- it is read again, so that what was posted comes back as its discussions.
-- `held` is how many comments were held when the submit started, and
-- `summary_sent` is set when a submit that failed had posted its summary. A
-- review abandoned while that read runs has its answer refused, which is the
-- abandon doing what it says rather than a read that failed, so nothing is
-- reported.
local function after_send(review, adapter, ok, held, summary_sent)
  M.decorate(review)
  if not ok and #review.held == held and not summary_sent then
    return
  end
  M.load(review, adapter, function(loaded, err)
    vim.schedule(function()
      if reviews[review.key] ~= review then
        return
      end
      if not loaded then
        return notify(("%s: the discussions were not read again\n%s"):format(review.id, tostring(err)), notify_levels.WARN)
      end
      M.decorate(review)
    end)
  end)
end

-- What `:w` in a compose buffer does: holds, replaces or drops the comment
-- for a place, or submits with the summary. A write that fails leaves the
-- buffer modified with its text, and `:w` is the retry, except a submit whose
-- summary was posted before its approval failed: that buffer closes, since a
-- retry would post the summary again, and the message names the approval
-- alone.
local function written(review, target, buf)
  local text = trimmed(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  if target.kind == "comment" then
    local ok, message = M.hold(review, target.position, text)
    if not ok then
      return notify(message, notify_levels.ERROR)
    end
    vim.bo[buf].modified = false
    close_compose(review, buf)
    M.decorate(review)
    return notify(message)
  end
  if text == "" then
    -- The command that sends what this one would have, less the summary: the
    -- bang and `approve` it was asked with.
    local asked = target.verdict or {}
    local verb = (asked.force and M.VERBS.force or M.VERBS.submit) .. (asked.approve and " approve" or "")
    return notify(
      ("%s: the summary is empty, so nothing was sent; %s sends the held comments without one"):format(review.id, verb),
      notify_levels.WARN
    )
  end
  local adapter, reason = ready(review)
  if not adapter then
    return notify(reason, notify_levels.ERROR)
  end
  local verdict = vim.tbl_extend("force", target.verdict or {}, { summary = text })
  local held = #review.held
  M.send(review, adapter, verdict, function(ok, message, summary_sent)
    vim.schedule(function()
      notify(message, ok and notify_levels.INFO or notify_levels.ERROR)
      if (ok or summary_sent) and vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
        close_compose(review, buf)
      end
      after_send(review, adapter, ok, held, summary_sent)
    end)
  end)
end

-- What a compose buffer is for, as its window's title shows it: the merge
-- request and the place, or `summary`.
local function compose_place(review, target)
  if target.kind == "summary" then
    return review.id .. "/summary"
  end
  local position = target.position
  if position.thread then
    return ("%s/reply/%s"):format(review.id, short(tostring(position.thread)))
  end
  if position.old_line then
    return ("%s/%s:old:%d"):format(review.id, position.file, position.old_line)
  end
  return ("%s/%s:%d"):format(review.id, position.file, position.line)
end

-- The compose buffer's name for a target. The worktree is in it because a
-- draft is found again by its name: without it the reviews of one number in
-- two clones would share their drafts and their summary, and a summary written
-- for one would be submitted to the other.
local function compose_name(review, target)
  return M.SCHEME .. review.root .. "/" .. compose_place(review, target)
end

--- Opens the buffer a comment or a summary is written in, in a floating
--- window over the diff, where a split would change the layout diffview
--- keeps. `:w` holds the comment, or submits with the summary. `:q` closes
--- the window and keeps the draft for the next time that place is commented
--- on, since the buffer is hidden rather than wiped; `:q!` discards it, since
--- it unloads the buffer.
---@param review table
---@param target { kind: string, position: table|nil, verdict: table|nil }
---@param initial string|nil the text a held comment already has
---@return integer buf
function M.compose(review, target, initial)
  local name = compose_name(review, target)
  local buf = named(name)
  -- `:q!` unloads a modified buffer, whatever `bufhidden` says, and one
  -- unloaded keeps its name and none of its text or options; it is made
  -- afresh, so a held comment's text is put back in it.
  if buf and not vim.api.nvim_buf_is_loaded(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    review.composing[buf] = nil
    buf = nil
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "acwrite"
    -- `hide` rather than `wipe`: `wipe` refuses every switch away from a
    -- modified buffer with E37, and an unwritten comment is kept as a draft.
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    if initial and initial ~= "" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
      vim.bo[buf].modified = false
    end
  end
  review.composing[buf] = true
  local group = autocommands()
  -- The target is set again on every open, since a buffer kept as a draft may
  -- have been made for a review since discarded.
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      written(review, target, buf)
    end,
  })
  local shown = vim.fn.win_findbuf(buf)
  for _, win in ipairs(shown) do
    if vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_win(win)
      return buf
    end
  end
  local width = math.max(math.min(vim.o.columns - 4, 100), 20)
  local height = math.max(math.min(M.COMPOSE_HEIGHT, vim.o.lines - 6), 3)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(vim.o.lines - height - 4, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    width = width,
    height = height,
    border = "rounded",
    -- `:w` in the summary submits the whole review, approval included.
    title = " " .. compose_place(review, target) .. (target.kind == "summary" and "  :w submits the review " or "  :w keeps it "),
    title_pos = "left",
  })
  return buf
end

-- Opening --------------------------------------------------------------------

local function has_diffview()
  return vim.fn.exists(":DiffviewOpen") == 2
end

-- What the review holds, said once the diff is open.
local function report(review, warnings)
  local placed, elsewhere = 0, 0
  for _, thread in ipairs(review.threads or {}) do
    if M.elsewhere(thread, review.shown or review.head) then
      elsewhere = elsewhere + 1
    elseif type(thread.position) == "table" then
      placed = placed + 1
    end
  end
  local lines = {
    ("%s: %d discussion(s), %d on lines of the diff%s; %d comment(s) held. %s holds one at the cursor, and %s sends them."):format(
      review.id,
      #(review.threads or {}),
      placed,
      elsewhere > 0 and (", %d on another version of it"):format(elsewhere) or "",
      #review.held,
      M.VERBS.comment,
      M.VERBS.submit
    ),
  }
  vim.list_extend(lines, warnings)
  notify(table.concat(lines, "\n"), #warnings > 0 and notify_levels.WARN or notify_levels.INFO)
end

-- Opens the diff in a tab of its own, or returns to the one already open.
-- Runs on the main loop, after load() has answered.
local function show(review)
  if review.source_branch ~= review.branch then
    return notify(
      ("%s: %s is on %s and the merge request's source branch is %s, so origin/%s...HEAD would not be its change. R on the dashboard builds its worktree."):format(
        review.id,
        review.root,
        tostring(review.branch),
        tostring(review.source_branch),
        tostring(review.target)
      ),
      notify_levels.ERROR
    )
  end

  if review.tab and vim.api.nvim_tabpage_is_valid(review.tab) then
    vim.api.nvim_set_current_tabpage(review.tab)
    if review.shown == review.head then
      M.decorate(review)
      return report(review, {})
    end
    -- HEAD has moved since this diff opened, and diffview resolved the range
    -- when it opened, so the diff is closed and opened again on the new HEAD.
    pcall(vim.cmd, "DiffviewClose")
    if vim.api.nvim_tabpage_is_valid(review.tab) and vim.api.nvim_get_current_tabpage() == review.tab then
      pcall(vim.cmd.tabclose)
    end
    clear_marks(review)
    review.tab = nil
  end

  local target = "origin/" .. review.target
  local base, base_err = git_line(review.root, "merge-base", target, "HEAD")
  if not base then
    return notify(
      ("%s: %s has no merge base with HEAD here. Fetch it and open the review again:\n  %s\n  %s %s\n%s"):format(
        review.id,
        target,
        spawn.shell_line({ "git", "-C", review.root, "fetch", "origin", review.target }),
        M.COMMAND,
        review.id,
        base_err
      ),
      notify_levels.ERROR
    )
  end
  review.base = base

  local warnings = {}
  local status = git(review.root, "status", "--porcelain", "--untracked-files=no")
  if status.ok and vim.trim(status.stdout) ~= "" then
    warnings[#warnings + 1] = ("the worktree has uncommitted changes, which the new side shows and the merge request does not; a comment is refused on a file that differs from HEAD. %s lists them."):format(
      spawn.shell_line({ "git", "-C", review.root, "status", "--short" })
    )
  end
  if review.head ~= review.refs.head_sha then
    warnings[#warnings + 1] = behind(review)
  elseif review.base ~= review.refs.base_sha then
    warnings[#warnings + 1] = other_base(review)
  end

  local before = vim.api.nvim_get_current_tabpage()
  local ok, raised = pcall(vim.cmd, { cmd = "DiffviewOpen", args = { target .. "...HEAD", M.IMPLY_LOCAL } })
  if not ok then
    return notify(("%s: diffview did not open\n%s"):format(review.id, tostring(raised)), notify_levels.ERROR)
  end
  local after = vim.api.nvim_get_current_tabpage()
  -- UNVERIFIED: that `:DiffviewOpen` makes its tab current before it returns.
  -- Diffview reports a range it cannot read in a message of its own and opens
  -- nothing, which is what an unchanged tab means; a diffview that opened its
  -- tab later would read as the same thing.
  if after == before then
    return notify(
      ("%s: diffview opened no tab for %s...HEAD; :messages holds its reason. The held comments are kept."):format(review.id, target),
      notify_levels.ERROR
    )
  end
  review.tab = after
  review.shown = review.head
  autocommands()
  M.decorate(review)
  report(review, warnings)
end

--- Opens a review of a merge request, or returns to the one open: the state
--- check, the merge request read through the adapter, then its diff in
--- diffview in a tab of its own, with the discussions and the held comments
--- drawn at their lines.
---
--- Runs on the main loop, from a user command, in the merge request's
--- worktree -- `R` on the dashboard builds it and runs `:Docket review <id>`
--- there. The worktree has to be on the merge request's source branch, since
--- `origin/<target>...HEAD` is its change only there. Held comments survive
--- the diff being closed and the review being opened again; discard() is what
--- drops them.
---@param source string the adapter's name
---@param id string `!482`
---@param adapter table|nil the adapter auth.ready() handed the caller; asked for here when nil
---@return table|nil review
function M.open(source, id, adapter)
  if not has_diffview() then
    notify(M.NO_DIFFVIEW, notify_levels.WARN)
    return nil
  end
  if not adapter then
    local reason
    adapter, reason = auth.ready(source)
    if not adapter then
      notify(reason, notify_levels.ERROR)
      return nil
    end
  end
  for _, capability in ipairs(M.NEEDS) do
    if not adapters.can(adapter, capability) then
      notify(("%s: %s has no review mode; it does not implement %s"):format(id, source, capability), notify_levels.ERROR)
      return nil
    end
  end
  local cwd = vim.fn.getcwd()
  local root, err = toplevel(cwd)
  if not root then
    notify(
      ("%s: the review opens inside the merge request's worktree, and %s is in none; R on the dashboard builds it\n%s"):format(id, cwd, err),
      notify_levels.ERROR
    )
    return nil
  end
  local head, head_err = git_line(root, "rev-parse", "HEAD")
  if not head then
    notify(("%s: %s"):format(id, head_err), notify_levels.ERROR)
    return nil
  end
  local branch, branch_err = git_line(root, "rev-parse", "--abbrev-ref", "HEAD")
  if not branch then
    notify(("%s: %s"):format(id, branch_err), notify_levels.ERROR)
    return nil
  end

  local review = M.start(source, id, root)
  review.head, review.branch = head, branch
  M.load(review, adapter, function(ok, load_err)
    vim.schedule(function()
      if not ok then
        return notify(("%s: %s"):format(id, tostring(load_err)), notify_levels.ERROR)
      end
      if reviews[review.key] ~= review then
        return
      end
      show(review)
    end)
  end)
  return review
end

-- The verbs, on the diff -------------------------------------------------------

-- The review in this tab, the side of the file under the cursor, and the
-- cursor's line; each failure is reported and answers nil.
local function here()
  local review, err = M.current()
  if not review then
    notify(err, notify_levels.ERROR)
    return nil
  end
  local buf = vim.api.nvim_get_current_buf()
  local loc = M.locate(review, buf)
  if not loc then
    notify(("%s: the cursor is on no side of the diff"):format(review.id), notify_levels.WARN)
    return nil
  end
  return review, loc, vim.api.nvim_win_get_cursor(0)[1], buf
end

-- A file whose buffer or working copy differs from HEAD has lines that are
-- not the merge request's.
local function unchanged(review, buf, path)
  if vim.bo[buf].modified then
    return false, ("%s: %s has unsaved changes, so its lines are not the merge request's; :e! discards them"):format(review.id, path)
  end
  local result = git(review.root, "diff", "--quiet", "HEAD", "--", path)
  if result.ok then
    return true, nil
  end
  if result.code == 1 and result.stderr == "" then
    return false, ("%s: %s differs from HEAD in the worktree, so its lines are not the merge request's; %s sets the change aside"):format(
      review.id,
      path,
      spawn.shell_line({ "git", "-C", review.root, "stash" })
    )
  end
  return false, spawn.message(result)
end

-- The context git gives each hunk, which is also what GitLab's diff shows
-- around a change.
M.CONTEXT = 3

-- Whether a line of a side of a file is one the merge request's diff shows,
-- which glab requires of a line comment: it reads the merge request's diff and
-- refuses any other line with `line N not found in diff for <file>`, or `old
-- line N`, which fails the batch at submit rather than here. The diff is the
-- worktree's own from the merge base, whose hunk headers name the lines each
-- side shows: `-a,b` the old side's from `a` for `b` lines, `+c,d` the new
-- side's. Both paths are given for the old side of a renamed file, so git
-- pairs them. UNVERIFIED: that GitLab's diff carries three lines of context
-- around a change, as git's does; a comment refused at submit on a line near
-- the edge of a hunk is the symptom of a narrower one.
local function in_diff(review, loc, line)
  local paths = { loc.path }
  if loc.side == M.OLD and loc.old_path and loc.old_path ~= loc.path then
    paths = { loc.old_path, loc.path }
  end
  local result = git(review.root, "diff", "-U" .. M.CONTEXT, "--no-color", review.base, "HEAD", "--", unpack(paths))
  if not result.ok then
    return false, spawn.message(result)
  end
  -- A hunk header starts its line; a line of the diff's content starts with a
  -- space, `+` or `-`, so text in the file that reads like a header is not one.
  for text in result.stdout:gmatch("[^\n]+") do
    local a, b, c, d = text:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if a then
      local first, count = tonumber(c), tonumber(d ~= "" and d or "1")
      if loc.side == M.OLD then
        first, count = tonumber(a), tonumber(b ~= "" and b or "1")
      end
      if line >= first and line < first + count then
        return true, nil
      end
    end
  end
  return false,
    ("%s: line %d of %s is not in the merge request's diff, and glab refuses a comment on a line the diff does not show; comment on a changed line or one within %d lines of it"):format(
      review.id,
      line,
      loc.side == M.OLD and (loc.old_path or loc.path) .. " on the old side" or loc.path,
      M.CONTEXT
    )
end

-- One of several, through vim.ui.select, or the only one directly.
local function choose(threads, prompt, on_choice)
  if #threads == 1 then
    return on_choice(threads[1])
  end
  vim.ui.select(threads, {
    prompt = prompt,
    format_item = function(thread)
      local first = (thread.notes or {})[1] or {}
      return ("%s: %s"):format(who(first.author), (vim.split(first.body or "", "\n", { plain = true })[1]))
    end,
  }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

--- Opens the compose buffer for a comment at the cursor: on the line under
--- it, on whichever side of the diff it is. A comment already held there is
--- in the buffer to change; written empty, it is dropped.
function M.comment()
  local review, loc, line, buf = here()
  if not review then
    return
  end
  local position = loc.side == M.NEW and { file = loc.path, line = line } or { file = loc.path, old_line = line }
  local existing = M.held_at(review, position)
  if not existing then
    local ok, reason = M.check(review, position)
    if ok and loc.local_file then
      ok, reason = unchanged(review, buf, loc.path)
    end
    if ok then
      ok, reason = in_diff(review, loc, line)
    end
    if not ok then
      return notify(reason, notify_levels.ERROR)
    end
  end
  M.compose(review, { kind = "comment", position = position }, existing and existing.text)
end

--- Opens the compose buffer for a reply to the thread drawn at the cursor's
--- line. A standalone comment takes no reply, so only threads are offered.
function M.reply()
  local review, loc, line = here()
  if not review then
    return
  end
  local threads = vim.tbl_filter(function(thread)
    return not thread.individual
  end, M.threads_at(review, loc, line))
  if #threads == 0 then
    return notify(("%s: no thread at this line takes a reply"):format(review.id), notify_levels.WARN)
  end
  choose(threads, "Reply to", function(thread)
    local position = { thread = thread.id }
    local existing = M.held_at(review, position)
    M.compose(review, { kind = "comment", position = position }, existing and existing.text)
  end)
end

--- Resolves the thread drawn at the cursor's line, now rather than with the
--- batch: resolving is not a comment, and GitLab records it at once.
function M.resolve()
  local review, loc, line = here()
  if not review then
    return
  end
  local at = M.threads_at(review, loc, line)
  local open = vim.tbl_filter(function(thread)
    return thread.resolvable and not thread.resolved
  end, at)
  if #open == 0 then
    local why = #at == 0 and "no thread is drawn at this line"
      or "the threads at this line are resolved already, or GitLab does not let them be"
    return notify(("%s: %s"):format(review.id, why), notify_levels.WARN)
  end
  choose(open, "Resolve", function(thread)
    local adapter, reason = ready(review)
    if not adapter then
      return notify(reason, notify_levels.ERROR)
    end
    M.resolve_thread(review, adapter, thread, function(ok, message)
      vim.schedule(function()
        notify(message, ok and notify_levels.INFO or notify_levels.ERROR)
        M.decorate(review)
      end)
    end)
  end)
end

--- Submits the review in this tab: the held comments, then the verdict.
--- `verdict.summary` set to true opens the compose buffer for the summary
--- instead, and its `:w` submits.
---@param verdict { approve: boolean|nil, summary: boolean|nil, force: boolean|nil }|nil
function M.submit(verdict)
  verdict = verdict or {}
  local review, err = M.current()
  if not review then
    return notify(err, notify_levels.ERROR)
  end
  if verdict.summary then
    M.compose(review, { kind = "summary", verdict = { approve = verdict.approve, force = verdict.force } }, nil)
    return
  end
  local adapter, reason = ready(review)
  if not adapter then
    return notify(reason, notify_levels.ERROR)
  end
  local held = #review.held
  M.send(review, adapter, { approve = verdict.approve, force = verdict.force }, function(ok, message)
    vim.schedule(function()
      notify(message, ok and notify_levels.INFO or notify_levels.ERROR)
      after_send(review, adapter, ok, held)
    end)
  end)
end

--- Drops a review: its held comments, its drawing and its compose buffers.
--- Nothing is sent. A read in flight is refused when it lands; a submit in
--- flight refuses the discard, because what it has started posting lands
--- whatever happens here.
---@param review table
---@return boolean ok
---@return string message
function M.discard(review)
  if submitting:pending(review.key) then
    return false, ("%s: a submit is in flight; nothing is discarded until it reports"):format(review.id)
  end
  reading:invalidate(review.key)
  if reviews[review.key] == review then
    reviews[review.key] = nil
  end
  clear_marks(review)
  for buf in pairs(review.composing) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  review.composing = {}
  local count = #review.held
  review.held = {}
  return true, ("%s: abandoned; %d held comment(s) discarded and nothing sent"):format(review.id, count)
end

--- Abandons the review in this tab and closes its diff.
function M.abandon()
  local review, err = M.current()
  if not review then
    return notify(err, notify_levels.ERROR)
  end
  local ok, message = M.discard(review)
  if not ok then
    return notify(message, notify_levels.ERROR)
  end
  -- UNVERIFIED: that `:DiffviewClose` closes the tab it runs in, which its
  -- help says. Nothing here closes the tab when it does not: a diff left open
  -- keeps its tab until a `:tabclose` typed by hand, and the review is gone
  -- either way.
  pcall(vim.cmd, "DiffviewClose")
  review.tab = nil
  notify(message)
end

return M
