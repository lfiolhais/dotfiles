# Easier navigation: ..., .... and .....
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# Shortcuts
alias d="cd ~/Downloads"
alias p="cd ~/Projects"
# macOS path; this file also deploys to Linux, where the alias simply fails.
alias icloud="cd /Users/lipe/Library/Mobile\ Documents/com\~apple\~CloudDocs/"

# Rust replacements. These shadow the POSIX tools everywhere, scripts included,
# and none of the three is argument-compatible with what it replaces: `find .
# -name '*.tmp' -delete` fails under fd. `command grep` reaches the real one.
alias grep="rg"
alias find="fd"
alias ls="eza"

# List all files colorized in long format
alias l="eza -l"
alias ll=l

# List all files colorized in long format, including dot files
alias la="eza -la"

# Nvim everywhere
alias vi="nvim"
alias vim="nvim"

# Rust helpers
alias c="cargo"
alias clippy="cargo clippy"

# Exclude .git when zipping. `-x` takes every following non-option argument as
# a pattern, so `zip out.zip dir` becomes `zip -x '*.git*' out.zip dir` and zip
# finds nothing to do. It works only when the next argument is another flag.
alias zip="zip -x '*.git*'"

# Git abbreviations. The guard is a universal variable, so this block runs once
# per machine ever: an abbreviation added below will not appear on a machine that
# has already run it. `set -e git_abbr_initialized` in a shell, then restart it,
# is what picks up a change here.
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
