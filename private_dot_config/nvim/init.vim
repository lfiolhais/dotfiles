" Fish doesn't play all that well with others
set shell=/bin/bash
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
Plug 'ciaranm/securemodelines'
Plug 'justinmk/vim-sneak'
Plug 'chriskempson/base16-vim'
Plug 'dracula/vim', { 'as': 'dracula' }
Plug 'catppuccin/nvim', { 'as': 'catppuccin' }
Plug 'qpkorr/vim-bufkill'
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
Plug 'nvim-treesitter/nvim-treesitter-context'
Plug 'nvim-tree/nvim-web-devicons'
Plug 'sindrets/diffview.nvim'
Plug 'numToStr/Comment.nvim'
Plug 'j-hui/fidget.nvim', { 'tag': 'legacy' }
Plug 'lewis6991/gitsigns.nvim'
Plug 'tpope/vim-obsession'
Plug 'christoomey/vim-tmux-navigator'
" Asynchronous Commands
Plug 'stevearc/overseer.nvim'
" Notifications Asynchronous Commands
Plug 'rcarriga/nvim-notify'
" Neovim Sessions
Plug 'rmagatti/auto-session'

" Git
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-surround'

" GUI enhancements
Plug 'nvim-lualine/lualine.nvim'
Plug 'machakann/vim-highlightedyank'

" Fuzzy finder
Plug 'airblade/vim-rooter'
Plug 'nvim-lua/popup.nvim'
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-file-browser.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim', { 'do': 'make' }
Plug 'nvim-telescope/telescope-ui-select.nvim'
Plug 'folke/trouble.nvim'

" Semantic language support
Plug 'neovim/nvim-lspconfig'
Plug 'williamboman/mason.nvim', {'do': ':MasonUpdate'}
Plug 'williamboman/mason-lspconfig.nvim'

" Autocompletion
Plug 'hrsh7th/nvim-cmp'
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-path'
Plug 'hrsh7th/cmp-buffer'

Plug 'VonHeikemen/lsp-zero.nvim', {'branch': 'v2.x'}

" Syntactic language support
Plug 'cespare/vim-toml'
Plug 'rust-lang/rust.vim'
Plug 'fatih/vim-go'
Plug 'dag/vim-fish'
Plug 'azidar/firrtl-syntax'
Plug 'lervag/vimtex'
Plug 'godlygeek/tabular'
Plug 'derekwyatt/vim-scala'
" Plug 'lfiolhais/vim-chisel'
" Plug 'plasticboy/vim-markdown'

call plug#end()

runtime macros/matchit.vim

" Plugin settings
let g:secure_modelines_allowed_items = [
                \ "textwidth",   "tw",
                \ "softtabstop", "sts",
                \ "tabstop",     "ts",
                \ "shiftwidth",  "sw",
                \ "expandtab",   "et",   "noexpandtab", "noet",
                \ "filetype",    "ft",
                \ "foldmethod",  "fdm",
                \ "readonly",    "ro",   "noreadonly", "noro",
                \ "rightleft",   "rl",   "norightleft", "norl",
                \ "colorcolumn"
                \ ]

" Latex
let g:latex_indent_enabled = 1
let g:latex_fold_envs = 0
let g:latex_fold_sections = []

" Don't confirm .lvimrc
let g:localvimrc_ask = 0

" https://github.com/rust-lang/rust.vim/issues/192
let g:rustfmt_autosave = 1
let g:rustfmt_fail_silently = 0
let $RUST_SRC_PATH = systemlist("rustc --print sysroot")[0] . "/lib/rustlib/src/rust/src"

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
local open_with_trouble = require("trouble.sources.telescope").open

require('telescope').setup{
    defaults = {
        mappings = {
          i = {
                  ["<c-t>"] = open_with_trouble
              },
          n = {
                  ["<c-t>"] = open_with_trouble
              },
        },
    },

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
}

require("telescope").load_extension "file_browser"
require('telescope').load_extension('fzf')
require("telescope").load_extension("ui-select")
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
set colorcolumn=80 " and give me a colored column
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

" Start session
nnoremap <leader>o :Obsession ~/.config/nvim/sessions/

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

" <leader>, shows/hides hidden characters
nnoremap <leader>, :set invlist<CR>

" =============================================================================
" # Autocommands
" =============================================================================

" Prevent accidental writes to buffers that shouldn't be edited
autocmd BufRead *.orig set readonly
autocmd BufRead *.pacnew set readonly

" Leave paste mode when leaving insert mode
autocmd InsertLeave * set nopaste

" Jump to last edit position on opening file
if has("autocmd")
  " https://stackoverflow.com/questions/31449496/vim-ignore-specifc-file-in-autocommand
  au BufReadPost * if expand('%:p') !~# '\m/\.git/' && line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
endif

" Follow Rust code style rules
au Filetype rust set colorcolumn=100

" Help filetype detection
autocmd BufRead *.md set filetype=markdown
autocmd BufRead *.lds set filetype=ld
autocmd BufRead *.tex set filetype=tex

" Remove trailing whitespace
fun! <SID>StripTrailingWhitespaces()
    let l = line(".")
    let c = col(".")
    %s/\s\+$//e
    call cursor(l, c)
endfun

autocmd BufWritePre * :call <SID>StripTrailingWhitespaces()

lua << EOF
vim.opt.termguicolors = true
vim.cmd.colorscheme "catppuccin-mocha"

vim.notify = require('notify')

vim.api.nvim_create_user_command("OverseerSleep", function()
  local overseer = require("overseer")
  local task = overseer.new_task({
      cmd = {'sleep'},
      args = {'3'},
  })
  task:start()
end, {})

require('overseer').setup()

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

require("fidget").setup {
  -- options
}

require("auto-session").setup {
  log_level = "error",
  auto_session_suppress_dirs = { "~/", "~/Projects", "~/Downloads", "/", "~/Documents"},
}

local lsp = require('lsp-zero').preset({
  manage_nvim_cmp = {
    set_sources = 'recommended'
  }
})

lsp.on_attach(function(client, bufnr)
  lsp.default_keymaps({buffer = bufnr})

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
end)

lsp.setup()

local cmp = require('cmp')
local cmp_action = require('lsp-zero').cmp_action()

cmp.setup({
  mapping = {
    ['<Tab>'] = cmp_action.tab_complete(),
    ['<S-Tab>'] = cmp_action.select_prev_or_fallback(),
  }
})
EOF

" =============================================================================
" # Footer
" =============================================================================

" nvim
if has('nvim')
    runtime! plugin/python_setup.vim
endif
