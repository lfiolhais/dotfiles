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
Plug('nvim-tree/nvim-web-devicons')
Plug('nvim-mini/mini.nvim')
-- Neovim Sessions
Plug('rmagatti/auto-session')

-- Git
Plug('tpope/vim-fugitive')

-- GUI enhancements
Plug('nvim-lualine/lualine.nvim')
Plug('machakann/vim-highlightedyank')

-- Fuzzy finder
Plug('nvim-lua/popup.nvim')
Plug('nvim-lua/plenary.nvim')
Plug('nvim-telescope/telescope.nvim')
Plug('nvim-telescope/telescope-file-browser.nvim')
Plug('nvim-telescope/telescope-fzf-native.nvim', { ['do'] = 'make' })
Plug('nvim-telescope/telescope-ui-select.nvim')

-- Semantic language support
Plug('neovim/nvim-lspconfig')
Plug('stevearc/conform.nvim')

-- Autocompletion
Plug('hrsh7th/cmp-nvim-lsp')
Plug('hrsh7th/cmp-path')
Plug('hrsh7th/cmp-buffer')
Plug('hrsh7th/cmp-cmdline')
Plug('hrsh7th/nvim-cmp')

vim.call('plug#end')

---------------------------------------------------------------------------------------------------
-- Editor settings
---------------------------------------------------------------------------------------------------
-- Completion
-- Better display for messages
vim.o.cmdheight = 2
-- You will have bad experience for diagnostic messages when it's default 4000.
vim.o.updatetime = 300

vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"

vim.o.autoindent = true
vim.o.timeoutlen = 300 -- http://stackoverflow.com/questions/2158516/delay-before-o-opens-a-new-line
vim.o.encoding = 'utf-8'
vim.o.scrolloff = 2
vim.o.showmode = false
vim.o.hidden = true
vim.o.wrap = false
vim.o.joinspaces = false
-- Always draw sign column. Prevent buffer moving when adding/deleting sign.
vim.o.signcolumn = "yes"

-- Sane splits
vim.o.splitright = true
vim.o.splitbelow = true

-- Permanent undo
vim.o.undodir = '~/.vimdid'
vim.o.undofile = true

-- Decent wildmenu
vim.o.wildmenu = true
vim.o.wildmode = 'list:longest'
vim.o.wildignore =
'.hg,.svn,*~,*.png,*.jpg,*.gif,*.settings,Thumbs.db,*.min.js,*.swp,publish/*,intermediate/*,*.o,*.hi,Zend,vendor'

-- Use wide tabs
vim.o.shiftwidth = 4
vim.o.softtabstop = 4
vim.o.tabstop = 4
vim.o.expandtab = true

-- Wrapping options
vim.o.formatoptions = 'tc'                     -- wrap text and comments using textwidth
vim.o.formatoptions = vim.o.formatoptions .. 'r' -- continue comments when pressing ENTER in I mode
vim.o.formatoptions = vim.o.formatoptions .. 'q' -- enable formatting of comments with gq
vim.o.formatoptions = vim.o.formatoptions .. 'n' -- detect lists for formatting
vim.o.formatoptions = vim.o.formatoptions .. 'b' -- auto-wrap in insert mode, and do not wrap old long lines

-- Proper search
vim.o.incsearch = true
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
vim.o.list = false
vim.o.listchars = 'nbsp:¬,extends:»,precedes:«,trail:•'

-- Use system clipboard
vim.o.clipboard = vim.o.clipboard .. 'unnamedplus'

---------------------------------------------------------------------------------------------------
-- Keyboard shortcuts
---------------------------------------------------------------------------------------------------
key_opts = { noremap = true }

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

vim.keymap.set('n', '<leader>s', '<cmd>Telescope live_grep<cr>', key_opts)
vim.keymap.set('n', '<leader>e', '<cmd>Telescope file_browser<cr>', key_opts)
vim.keymap.set('n', '<leader>f', '<cmd>Telescope find_files<cr>', key_opts)
vim.keymap.set('n', '<leader>b', '<cmd>Telescope buffers<cr>', key_opts)

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
require('mini.pairs').setup()
require('mini.align').setup()
require('mini.notify').setup()
require('mini.diff').setup()

local telescope = require("telescope")

telescope.load_extension("file_browser")
telescope.load_extension('fzf')
telescope.load_extension("ui-select")

telescope.setup({
    pickers = {
        file_browser = {
            hidden = true,
            no_ignore = true
        },
        find_files = {
            hidden = true,
            no_ignore = true
        },
    },

    extensions = {
        file_browser = {
            -- disables netrw and use telescope-file-browser in its place
            hijack_netrw = true,
        },
    },
})

require 'nvim-treesitter.configs'.setup {
    ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
    highlight = {
        enable = true,      -- false will disable the whole extension
    },
}

require('lualine').setup()

require("auto-session").setup {
    log_level = "error",
    suppressed_dirs = { "~/", "~/Projects", "~/Downloads", "/", "~/Documents" },
}

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
        vim.keymap.set('n', 'gr', '<cmd>Telescope lsp_references<cr>', bufopts)
        vim.keymap.set('n', '<space>=', function()
            vim.lsp.buf.format({ async = false, timeout_ms = 10000 })
        end, bufopts)
    end,
})

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

local cmp = require('cmp')

cmp.setup({
    window = {
        -- completion = cmp.config.window.bordered(),
        -- documentation = cmp.config.window.bordered(),
    },
    mapping = cmp.mapping.preset.insert({
        ["<Tab>"] = cmp.mapping(function(fallback)
            -- This little snippet will confirm with tab, and if no entry is selected, will confirm the first item
            if cmp.visible() then
                local entry = cmp.get_selected_entry()
                if not entry then
                    cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
                end
                cmp.confirm()
            else
                fallback()
            end
        end, { "i", "s", "c", }),
    }),
    sources = cmp.config.sources({
        { name = 'nvim_lsp' },
    }, {
        { name = 'buffer' },
    })
})

-- Use buffer source for `/` and `?` (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline({ '/', '?' }, {
    mapping = cmp.mapping.preset.cmdline(),
    sources = {
        { name = 'buffer' }
    }
})

-- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
cmp.setup.cmdline(':', {
    mapping = cmp.mapping.preset.cmdline(),
    sources = cmp.config.sources({
        { name = 'path' }
    }, {
        { name = 'cmdline' }
    }),
    matching = { disallow_symbol_nonprefix_matching = false }
})

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
