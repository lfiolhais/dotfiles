-- What the docket package declares at startup: the `:Docket` command, the
-- `<leader>dd` map to the dashboard, and the autocommands that route the read
-- and write of an item buffer and of a new ticket's draft, and attach an item
-- buffer's keymaps. Every other `<leader>d` key belongs to one kind of buffer
-- and is set on it, by commands.attach(), commands.attach_dash() and, on the
-- buffers of a review's diff, commands.attach_review(); the autocommands that
-- key a review are made when `:Docket review` first opens one, since until
-- then there is no review to key. Every body here requires its module on the
-- first use, so this file loads nothing. The configuration's init.lua carries
-- `require('docket').setup{}` alone, which loads init, config and highlight
-- at startup: the options and the highlight groups. The read path, the
-- adapters and every client load at the first command that needs them.

if vim.g.loaded_docket then
  return
end
vim.g.loaded_docket = true

vim.api.nvim_create_user_command("Docket", function(command)
  require("docket.commands").run(command)
end, {
  nargs = "*",
  bang = true,
  desc = "Docket: the dashboard, an item, login [<backend>], review <id> or <verb>, create [<project>]; ! forces a re-login, or a review submit",
  complete = function(lead, line)
    return require("docket.commands").complete(lead, line)
  end,
})

vim.keymap.set("n", "<leader>dd", "<cmd>Docket<cr>", { noremap = true, silent = true, desc = "Docket: the dashboard" })

local group = vim.api.nvim_create_augroup("docket", { clear = true })

-- An item buffer's name, `docket://<source>/<id>`, or
-- `docket://<source>/<project>/<id>` for a merge request, names no file: the
-- read command populates the buffer from its adapter, and the write command
-- is where `:w` goes because the buffer is `acwrite`.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "docket://*",
  callback = function(event)
    -- `:e` has emptied the buffer before this runs, so the state the last
    -- read stored goes with the text. A read that then fails leaves `:w` and
    -- `<leader>dw` reporting that nothing is loaded. The read is handed that
    -- state as it stood, because its reference names the clone the text came
    -- from, which is where `:e` reads the item again.
    local held = vim.b[event.buf].docket
    vim.b[event.buf].docket = nil
    require("docket.buffer").read(event.buf, nil, nil, held)
  end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "docket://*",
  callback = function(event)
    require("docket.buffer").write(event.buf)
  end,
})

-- `docket-new://<source>` is a new ticket's draft: the read fills it with an
-- empty header, and `:w` creates the item and puts its buffer in the draft's
-- place.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "docket-new://*",
  callback = function(event)
    require("docket.commands").draft(event.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = group,
  pattern = "docket-new://*",
  callback = function(event)
    require("docket.commands").save_draft(event.buf)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "docket",
  callback = function(event)
    require("docket.commands").attach(event.buf)
  end,
})
