# Easier navigation: ..., .... and .....
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# Shortcuts
alias d="cd ~/Downloads"
alias p="cd ~/Projects"
alias icloud="cd /Users/lipe/Library/Mobile\ Documents/com\~apple\~CloudDocs/"

# Rust replacements
alias grep="rg"
alias find="fd"
# alias cat="bat"
alias ls="eza"

# List all files colorized in long format
alias l="eza -l"
alias ll=l

# List all files colorized in long format, including dot files
alias la="eza -la"

# List only directories
#alias lsd="exa -l | grep --color=never '^d'"

# Nvim everywhere
alias vi="nvim"
alias vim="nvim"

# Rust helpers
alias c="cargo"
alias clippy="cargo clippy"

# Zip. Always exclude .git folders when zipping
alias zip="zip -x '*.git*'"

# Git aliases/abbreviations
if not set -q git_abbr_initialized
    set -U git_abbr_initialized
    abbr -a gco git checkout
    abbr -a gst git status
    abbr -a ga git add
    abbr -a gca git commit -a
    abbr -a gf git fetch
    abbr -a gpl git pull
    abbr -a gp git push
end

alias gl="git log --pretty=format:\"%C(yellow)%h%Cred%d %Creset%s%Cblue [%cn]\" --decorate"
alias gll="git log --pretty=format:\"%C(yellow)%h%Cred%d %Creset%s%Cblue [%cn]\" --decorate --numstat"

# Quartus
#alias quartus="quartus --64bits"

