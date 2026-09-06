# Easier navigation: ..., .... and .....
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# Shortcuts
alias d="cd ~/Downloads"
alias p="cd ~/Projects"

# iCloud Drive, which only exists on macOS.
set -l icloud_dir "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
if test -d "$icloud_dir"
    alias icloud="cd '$icloud_dir'"
end

# Rust replacements. These shadow the POSIX tools everywhere, scripts included,
# and none of the three is argument-compatible with what it replaces: `find .
# -name '*.tmp' -delete` fails under fd. `command grep` reaches the real one.
#
# Each is defined only where its replacement is installed: eza has no EPEL 9
# build, and a machine part-way through its bootstrap has none of them, so an
# unguarded alias answers a request to list a directory with "command not
# found".
command --query rg; and alias grep="rg"
command --query fd; and alias find="fd"
if command --query eza
    alias ls="eza"
    # List all files colorized in long format
    alias l="eza -l"
    alias ll=l
    # List all files colorized in long format, including dot files
    alias la="eza -la"
else
    alias l="ls -l"
    alias ll="ls -l"
    alias la="ls -la"
end

# Nvim everywhere
alias vi="nvim"
alias vim="nvim"

# Rust helpers, guarded for the same reason as the replacements above: rustup is
# not in EPEL 9 and is not in mise's registry either, so the RHEL rebuilds and
# the no-sudo profile have no cargo and an unguarded `c` answers with "Unknown
# command: cargo".
if command --query cargo
    alias c="cargo"
    alias clippy="cargo clippy"
end

# Git abbreviations. fish scopes an abbreviation to the session, so these are
# defined on every shell start and a new one here appears at the next shell.
abbr -a gco git checkout
abbr -a gst git status
abbr -a ga git add
abbr -a gca git commit -a
abbr -a gf git fetch
abbr -a gpl git pull
abbr -a gp git push

alias gl="git log --pretty=format:\"%C(yellow)%h%Cred%d %Creset%s%Cblue [%cn]\" --decorate"
alias gll="git log --pretty=format:\"%C(yellow)%h%Cred%d %Creset%s%Cblue [%cn]\" --decorate --numstat"
