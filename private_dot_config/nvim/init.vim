" Fish doesn't play all that well with others
" set shell=/bin/bash
let mapleader = "\<Space>"

" =============================================================================
" # PLUGINS
" =============================================================================
" Load vundle
set nocompatible
filetype off
call plug#begin('~/.local/share/nvim/plugged')

" Load plugins
" VIM enhancements
Plug 'catppuccin/nvim', { 'as': 'catppuccin' }
Plug 'qpkorr/vim-bufkill'
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
Plug 'nvim-treesitter/nvim-treesitter-context'
Plug 'nvim-tree/nvim-web-devicons'
Plug 'sindrets/diffview.nvim'
Plug 'numToStr/Comment.nvim'
Plug 'j-hui/fidget.nvim', { 'tag': 'legacy' }
" Notifications Asynchronous Commands
Plug 'rcarriga/nvim-notify'
" Neovim Sessions
Plug 'rmagatti/auto-session'

" Git
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-surround'
Plug 'lewis6991/gitsigns.nvim'

" GUI enhancements
Plug 'nvim-lualine/lualine.nvim'
Plug 'machakann/vim-highlightedyank'

" Fuzzy finder
Plug 'nvim-lua/popup.nvim'
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-file-browser.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim', { 'do': 'make' }
Plug 'nvim-telescope/telescope-ui-select.nvim'

" Semantic language support
Plug 'neovim/nvim-lspconfig'
Plug 'stevearc/conform.nvim'

" Autocompletion
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-path'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/cmp-cmdline'
Plug 'hrsh7th/nvim-cmp'

" Syntactic language support
Plug 'lervag/vimtex'
Plug 'godlygeek/tabular'

call plug#end()

runtime macros/matchit.vim

" Latex
let g:latex_indent_enabled = 1
let g:latex_fold_envs = 0
let g:latex_fold_sections = []

" Don't confirm .lvimrc
let g:localvimrc_ask = 0

" Completion
" Better display for messages
set cmdheight=2
" You will have bad experience for diagnostic messages when it's default 4000.
set updatetime=300

" =============================================================================
" # Telescope
" =============================================================================
lua <<EOF
local actions = require('telescope.actions')

local telescope = require("telescope")

telescope.load_extension("file_browser")
telescope.load_extension('fzf')
telescope.load_extension("ui-select")

telescope.setup({
    pickers = {
        file_browser = {
            hidden=true,
            no_ignore=true
        },
        find_files = {
            hidden=true,
            no_ignore=true
        },
    },

    extensions = {
        file_browser = {
          -- disables netrw and use telescope-file-browser in its place
          hijack_netrw = true,
        },
  },
})

EOF

" =============================================================================
" # Tree Sitter
" =============================================================================
lua <<EOF
require'nvim-treesitter.configs'.setup {
  ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
  highlight = {
    enable = true,              -- false will disable the whole extension
  },
}
EOF

" =============================================================================
" # Editor settings
" =============================================================================
filetype plugin indent on
set autoindent
set timeoutlen=300 " http://stackoverflow.com/questions/2158516/delay-before-o-opens-a-new-line
set encoding=utf-8
set scrolloff=2
set noshowmode
set hidden
set nowrap
set nojoinspaces
let g:sneak#s_next = 1
let g:vim_markdown_new_list_item_indent = 0
let g:vim_markdown_auto_insert_bullets = 0
let g:vim_markdown_frontmatter = 1
" set printfont=:h10
" set printencoding=utf-8
" set printoptions=paper:letter
" Always draw sign column. Prevent buffer moving when adding/deleting sign.
set signcolumn=yes

" Settings needed for .lvimrc
set exrc
set secure

set tags=.git/tags

" Sane splits
set splitright
set splitbelow

" Permanent undo
set undodir=~/.vimdid
set undofile

" Decent wildmenu
set wildmenu
set wildmode=list:longest
set wildignore=.hg,.svn,*~,*.png,*.jpg,*.gif,*.settings,Thumbs.db,*.min.js,*.swp,publish/*,intermediate/*,*.o,*.hi,Zend,vendor

" Use wide tabs
set shiftwidth=4
set softtabstop=4
set tabstop=4
set expandtab

" Get syntax
syntax on

" Wrapping options
set formatoptions=tc " wrap text and comments using textwidth
set formatoptions+=r " continue comments when pressing ENTER in I mode
set formatoptions+=q " enable formatting of comments with gq
set formatoptions+=n " detect lists for formatting
set formatoptions+=b " auto-wrap in insert mode, and do not wrap old long lines

" Proper search
set incsearch
set ignorecase
set smartcase
set gdefault

" Search results centered please
nnoremap <silent> n nzz
nnoremap <silent> N Nzz
nnoremap <silent> * *zz
nnoremap <silent> # #zz
nnoremap <silent> g* g*zz

" Very magic by default
nnoremap ? ?\v
nnoremap / /\v
cnoremap %s/ %sm/

" =============================================================================
" # GUI settings
" =============================================================================
set guioptions-=T " Remove toolbar
set vb t_vb= " No more beeps
set backspace=2 " Backspace over newlines
set foldmethod=marker " Only fold on marks
set ruler " Where am I?
set ttyfast
" https://github.com/vim/vim/issues/1735#issuecomment-383353563
set lazyredraw
set synmaxcol=500
set laststatus=2
set relativenumber " Relative line numbers
set diffopt+=iwhite " No whitespace in vimdiff
" Make diffing better: https://vimways.org/2018/the-power-of-diff/
set diffopt+=algorithm:patience
set diffopt+=indent-heuristic
set colorcolumn=100 " and give me a colored column
set showcmd " Show (partial) command in status line.
set mouse=a " Enable mouse usage (all modes) in terminals
set shortmess+=c " don't give |ins-completion-menu| messages.

" Show those damn hidden characters
" Verbose: set listchars=nbsp:¬,eol:¶,extends:»,precedes:«,trail:•
set nolist
set listchars=nbsp:¬,extends:»,precedes:«,trail:•

" =============================================================================
" # Keyboard shortcuts
" =============================================================================
" ; as :
nnoremap ; :

" Open hotkeys
nnoremap <leader>f <cmd>Telescope find_files<cr>
nnoremap <leader>b <cmd>Telescope buffers<cr>

" Git hotkeys
nnoremap <leader>g <cmd>Git<cr>
nnoremap <leader>gp <cmd>Git push<cr>
nnoremap <leader>gmm <cmd>Git merge origin/master<cr>
nnoremap <leader>gmi :Git merge<space>
nnoremap <leader>gsp <cmd>!gitsubpull<cr>
nnoremap <leader>gco :Git checkout<space>

" Move between tabs
nnoremap <leader>tn <cmd>tabnew<cr>
nnoremap <leader>td <cmd>tabclose<cr>
nnoremap <leader>tl <cmd>tabn<cr>
nnoremap <leader>th <cmd>tabp<cr>
nnoremap <leader>t1 <cmd>1tabn<cr>
nnoremap <leader>t2 <cmd>2tabn<cr>
nnoremap <leader>t3 <cmd>3tabn<cr>

" Diff
nnoremap <leader>gdo <cmd>DiffviewOpen<cr>
nnoremap <leader>gdc <cmd>DiffviewClose<cr>
nnoremap <leader>gdf <cmd>DiffviewFileHistory<cr>

" Kill buffer
nnoremap <leader>bd :BD<CR>

" Split window and open a file in the new one
nmap <leader>wv :vsplit<CR>
nmap <leader>ws :split<CR>
nmap <leader>wd <C-w>q

" Move around in a split window
nmap <leader>wl <C-w>l
nmap <leader>wk <C-w>k
nmap <leader>wj <C-w>j
nmap <leader>wh <C-w>h

" Quick-save
nmap <leader>w :w<CR>

" Use system clipboard
set clipboard+=unnamedplus

" <leader>s for Rg search
" nnoremap <leader>s <cmd>Telescope live_grep<cr>
noremap <leader>s :Telescope live_grep<CR>

" Open new file adjacent to current file
nnoremap <leader>e :Telescope file_browser<cr>

" No arrow keys --- force yourself to use the home row
nnoremap <up> <nop>
nnoremap <down> <nop>
inoremap <up> <nop>
inoremap <down> <nop>
inoremap <left> <nop>
inoremap <right> <nop>

" Move by line
nnoremap j gj
nnoremap k gk

" <leader><leader> toggles between buffers
nnoremap <leader><leader> <c-^>

" =============================================================================
" # Autocommands
" =============================================================================

" Leave paste mode when leaving insert mode
autocmd InsertLeave * set nopaste

" Jump to last edit position on opening file
if has("autocmd")
  " https://stackoverflow.com/questions/31449496/vim-ignore-specifc-file-in-autocommand
  au BufReadPost * if expand('%:p') !~# '\m/\.git/' && line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

" Follow Rust code style rules
au Filetype rust set colorcolumn=100

" Remove trailing whitespace
fun! <SID>StripTrailingWhitespaces()
    let l = line(".")
    let c = col(".")
    %s/\s\+$//e
    call cursor(l, c)
endfun

autocmd BufWritePre * :call <SID>StripTrailingWhitespaces()

lua << EOF
vim.diagnostic.config({ virtual_text = true })
vim.o.sessionoptions="blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"

vim.opt.termguicolors = true
vim.cmd.colorscheme "catppuccin-mocha"

vim.notify = require('notify')

require('gitsigns').setup {
  -- See `:help gitsigns.txt`
  signs = {
    add = { text = '+' },
    change = { text = '~' },
    delete = { text = '_' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
  },
}

require('lualine').setup()

require('Comment').setup()

require("fidget").setup {}

require("auto-session").setup {
  log_level = "error",
  suppressed_dirs = { "~/", "~/Projects", "~/Downloads", "/", "~/Documents"},
}

vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(event)
        local opts = { noremap=true, silent=true }
        vim.keymap.set('n', '<space>l', vim.diagnostic.open_float, opts)
        vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
        vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
        vim.keymap.set('n', '<space>a', vim.diagnostic.setloclist, opts)

        local bufopts = { noremap=true, silent=true, buffer=true }
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
            vim.lsp.buf.format({async = false, timeout_ms = 10000})
        end, bufopts)
    end,
})

vim.lsp.config('rust_analyzer', {
  settings = {
    ['rust-analyzer'] = {
      diagnostics = {
        enable = true;
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

vim.lsp.enable('bashls')
vim.lsp.enable('ruff')
vim.lsp.enable('rust_analyzer')
vim.lsp.enable('jedi_language_server')
vim.lsp.enable('marksman')

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
        end, {"i","s","c",}),
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
EOF


" =============================================================================
" # Footer
" =============================================================================

" nvim
if has('nvim')
    runtime! plugin/python_setup.vim
endif
