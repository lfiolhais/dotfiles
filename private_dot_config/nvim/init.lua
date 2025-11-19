local vim = vim
local Plug = vim.fn['plug#']

vim.g.mapleader = " "

---------------------------------------------------------------------------------------------------
-- Plugins
---------------------------------------------------------------------------------------------------
vim.call('plug#begin')
-- VIM enhancements
Plug('catppuccin/nvim', { ['as'] = 'catppuccin' })
Plug('qpkorr/vim-bufkill')
Plug('nvim-treesitter/nvim-treesitter', { ['do'] = ':TSUpdate' })
Plug('nvim-treesitter/nvim-treesitter-context')
Plug('nvim-mini/mini.nvim')
-- Neovim Sessions
Plug('rmagatti/auto-session')

-- Git
Plug('tpope/vim-fugitive')

-- GUI enhancements
Plug('nvim-lualine/lualine.nvim')
Plug('machakann/vim-highlightedyank')

-- Semantic language support
Plug('neovim/nvim-lspconfig')
Plug('stevearc/conform.nvim')

vim.call('plug#end')

---------------------------------------------------------------------------------------------------
-- Editor settings
---------------------------------------------------------------------------------------------------
-- Completion
-- Better display for messages
vim.o.cmdheight = 2
-- You will have bad experience for diagnostic messages when it's default 4000.
vim.o.updatetime = 300

vim.o.sessionoptions = vim.o.sessionoptions .. ",winpos,localoptions"

vim.o.timeoutlen = 300 -- http://stackoverflow.com/questions/2158516/delay-before-o-opens-a-new-line
vim.o.scrolloff = 2
vim.o.showmode = false
vim.o.wrap = false
-- Always draw sign column. Prevent buffer moving when adding/deleting sign.
vim.o.signcolumn = "yes"

-- Sane splits
vim.o.splitright = true
vim.o.splitbelow = true

-- Permanent undo
vim.o.undofile = true

-- Decent wildmenu
vim.o.wildmode = 'list:longest'
vim.o.wildignore =
'.hg,.svn,*~,*.png,*.jpg,*.gif,*.settings,Thumbs.db,*.min.js,*.swp,publish/*,intermediate/*,*.o,*.hi,Zend,vendor'

-- Use wide tabs
vim.o.shiftwidth = 4
vim.o.softtabstop = 4
vim.o.tabstop = 4
vim.o.expandtab = true

-- Wrapping options
vim.o.formatoptions = vim.o.formatoptions .. 'r' -- continue comments when pressing ENTER in I mode
vim.o.formatoptions = vim.o.formatoptions .. 'n' -- detect lists for formatting
vim.o.formatoptions = vim.o.formatoptions .. 'b' -- auto-wrap in insert mode, and do not wrap old long lines

-- Proper search
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.gdefault = true

---------------------------------------------------------------------------------------------------
-- GUI settings
---------------------------------------------------------------------------------------------------
vim.o.foldmethod = 'marker' -- Only fold on marks
vim.o.lazyredraw = true
vim.o.synmaxcol = 500
vim.o.relativenumber = true -- Relative line numbers
vim.o.diffopt = vim.o.diffopt .. ',iwhite'
vim.o.diffopt = vim.o.diffopt .. ',algorithm:patience'
vim.o.colorcolumn = "100"                -- and give me a colored column
vim.o.showcmd = true                     -- Show (partial) command in status line.
vim.o.mouse = 'a'                        -- Enable mouse usage (all modes) in terminals
vim.o.shortmess = vim.o.shortmess .. 'c' -- don't give |ins-completion-menu| messages.

-- Show those damn hidden characters
-- Verbose: set listchars=nbsp:¬,eol:¶,extends:»,precedes:«,trail:•
vim.o.listchars = 'nbsp:¬,extends:»,precedes:«,trail:•'

-- Use system clipboard
vim.o.clipboard = vim.o.clipboard .. 'unnamedplus'

---------------------------------------------------------------------------------------------------
-- Keyboard shortcuts
---------------------------------------------------------------------------------------------------
local key_opts = { noremap = true }

-- Search results centered please
vim.keymap.set('n', '<silent> n', 'nzz', key_opts)
vim.keymap.set('n', '<silent> N', 'Nzz', key_opts)
vim.keymap.set('n', '<silent> *', '*zz', key_opts)
vim.keymap.set('n', '<silent> #', '#zz', key_opts)
vim.keymap.set('n', '<silent> g*', 'g*zz', key_opts)

-- ; as :
vim.keymap.set('n', ';', ':', key_opts)

-- Very magic by default
vim.keymap.set('n', '?', '?\\v', key_opts)
vim.keymap.set('n', '/', '/\\v', key_opts)
vim.keymap.set('c', '%s/', '%sm/', key_opts)

-- toggles between buffers
vim.keymap.set('n', '<leader><leader>', '<c-^>', key_opts)

vim.keymap.set('n', '<leader>s', function() MiniPick.builtin.grep_live() end, key_opts)
vim.keymap.set('n', '<leader>e', function() MiniFiles.open() end, key_opts)
vim.keymap.set('n', '<leader>f', function() MiniPick.builtin.files() end, key_opts)
vim.keymap.set('n', '<leader>b', function() MiniPick.builtin.buffers() end, key_opts)

-- Git hotkeys
vim.keymap.set('n', '<leader>g', '<cmd>Git<cr>', key_opts)
vim.keymap.set('n', '<leader>gp', '<cmd>Git push<cr>', key_opts)
vim.keymap.set('n', '<leader>gmm', '<cmd>Git merge origin/master<cr>', key_opts)
vim.keymap.set('n', '<leader>gmi', '<cmd>Git merge <space>', key_opts)
vim.keymap.set('n', '<leader>gco', '<cmd>Git checkout <space>', key_opts)

-- Move between tabs
vim.keymap.set('n', '<leader>tn', '<cmd>tabnew<cr>', key_opts)
vim.keymap.set('n', '<leader>td', '<cmd>tabclose<cr>', key_opts)
vim.keymap.set('n', '<leader>tl', '<cmd>tabn<cr>', key_opts)
vim.keymap.set('n', '<leader>tp', '<cmd>tabp<cr>', key_opts)

-- Kill buffer
vim.keymap.set('n', '<leader>bd', '<cmd>BD<cr>', key_opts)

-- Split window and open a file in the new one
vim.keymap.set('n', '<leader>wv', '<cmd>vsplit<cr>')
vim.keymap.set('n', '<leader>ws', '<cmd>split<cr>')
vim.keymap.set('n', '<leader>wd', '<C-w>q')

-- Move around in a split window
vim.keymap.set('n', '<leader>wl', '<C-w>l')
vim.keymap.set('n', '<leader>wk', '<C-w>k')
vim.keymap.set('n', '<leader>wj', '<C-w>j')
vim.keymap.set('n', '<leader>wh', '<C-w>h')

-- Quick Save
vim.keymap.set('n', '<leader>w', '<cmd>w<cr>')

-- Move by line
vim.keymap.set('n', 'j', 'gj', key_opts)
vim.keymap.set('n', 'k', 'gk', key_opts)

-- No arrow keys --- force yourself to use the home row
vim.keymap.set({ 'n', 'i' }, '<up>', '<nop>', key_opts)
vim.keymap.set({ 'n', 'i' }, '<down>', '<nop>', key_opts)
vim.keymap.set({ 'n', 'i' }, '<left>', '<nop>', key_opts)
vim.keymap.set({ 'n', 'i' }, '<right>', '<nop>', key_opts)

---------------------------------------------------------------------------------------------------
-- Plugins
---------------------------------------------------------------------------------------------------
vim.diagnostic.config({ virtual_text = true })

vim.opt.termguicolors = true
vim.cmd.colorscheme "catppuccin-mocha"

-- Mini
require('mini.trailspace').setup()
require('mini.surround').setup()
require('mini.align').setup()
require('mini.notify').setup()
require('mini.diff').setup()
require('mini.files').setup()
require('mini.icons').setup()
require('mini.pick').setup()
require('mini.completion').setup()

require('nvim-treesitter.configs').setup {
    -- Automatically install missing parsers when entering buffer
    -- Recommendation: set to false if you don't have `tree-sitter` CLI installed locally
    auto_install = true,

    highlight = {
        enable = true,
    },
}

require('lualine').setup()

require("auto-session").setup {
    log_level = "error",
    suppressed_dirs = { "~/", "~/Projects", "~/Downloads", "/", "~/Documents" },
}

require("conform").setup({
    formatters_by_ft = {
        python = {
            -- To fix auto-fixable lint errors.
            "ruff_fix",
            -- To run the Ruff formatter.
            "ruff_format",
            -- To organize the imports.
            "ruff_organize_imports",
        },
    },
})

require("conform").formatters.verible = {
    append_args = {
        "--assignment_statement_alignment", "flush-left",
        "--case_items_alignment", "flush-left",
        "--distribution_items_alignment", "flush-left",
        "--enum_assignment_statement_alignment", "flush-left",
        "--module_net_variable_alignment", "lush-left",
        "--named_parameter_alignment", "flush-left",
        "--named_port_alignment", "flush-left",
        "--port_declarations_alignment", "flush-left",
        "--struct_union_members_alignment", "flush-left",
        "--indentation_spaces", "4",
    }
}

---------------------------------------------------------------------------------------------------
-- LSPs
---------------------------------------------------------------------------------------------------
vim.lsp.config('rust_analyzer', {
    settings = {
        ['rust-analyzer'] = {
            diagnostics = {
                enable = true,
            }
        }
    }
})
vim.lsp.config('ruff', {
    init_options = {
        settings = {
            enableProfileLoading = false,
        }
    }
})
vim.lsp.config('verible', {
    cmd = { 'verible-verilog-ls', '--indentation_spaces', '4', '--rules_config_search' },
})
vim.lsp.config['lua_ls'] = {
    -- Command and arguments to start the server.
    cmd = { 'lua-language-server' },
    -- Filetypes to automatically attach to.
    filetypes = { 'lua' },
    -- Sets the "workspace" to the directory where any of these files is found.
    -- Files that share a root directory will reuse the LSP server connection.
    -- Nested lists indicate equal priority, see |vim.lsp.Config|.
    root_markers = { { '.luarc.json', '.luarc.jsonc' }, '.git' },
    -- Specific settings to send to the server. The schema is server-defined.
    -- Example: https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json
    settings = {
        Lua = {
            runtime = {
                version = 'LuaJIT',
            }
        }
    }
}

vim.lsp.enable('bashls')
vim.lsp.enable('ruff')
vim.lsp.enable('rust_analyzer')
vim.lsp.enable('jedi_language_server')
vim.lsp.enable('marksman')
vim.lsp.enable('lua_ls')
vim.lsp.enable('verible')

---------------------------------------------------------------------------------------------------
-- AutoCommands
---------------------------------------------------------------------------------------------------

vim.api.nvim_create_autocmd("BufWritePre", {
    pattern = "*",
    callback = function() MiniTrailspace.trim() end,
})

-- Jump to last edit position on opening file
vim.api.nvim_create_autocmd("BufReadPost", {
    callback = function()
        local mark = vim.api.nvim_buf_get_mark(0, '"')
        local lcount = vim.api.nvim_buf_line_count(0)
        if mark[1] > 0 and mark[1] <= lcount then
            pcall(vim.api.nvim_win_set_cursor, 0, mark)
        end
    end,
})

vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(event)
        local opts = { noremap = true, silent = true }
        vim.keymap.set('n', '<space>l', vim.diagnostic.open_float, opts)
        vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
        vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
        vim.keymap.set('n', '<space>a', vim.diagnostic.setloclist, opts)

        local bufopts = { noremap = true, silent = true, buffer = true }
        vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, bufopts)
        vim.keymap.set('n', 'gd', vim.lsp.buf.definition, bufopts)
        vim.keymap.set('n', '<space>K', vim.lsp.buf.hover, bufopts)
        vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, bufopts)
        vim.keymap.set('n', '<space>k', vim.lsp.buf.signature_help, bufopts)
        vim.keymap.set('n', 'gy', vim.lsp.buf.type_definition, bufopts)
        vim.keymap.set('n', 'grn', vim.lsp.buf.rename, bufopts)
        vim.keymap.set('n', 'ga', vim.lsp.buf.code_action, bufopts)
        vim.keymap.set('n', '<space>=', function()
            vim.lsp.buf.format({ async = false, timeout_ms = 10000 })
        end, bufopts)
    end,
})
