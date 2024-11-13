# Setup fzf
fzf --fish | source

source $HOME/.config/fish/exports.fish
source $HOME/.config/fish/aliases.fish
source $HOME/.config/fish/greet.fish
source $HOME/.config/fish/colors.fish

# Spawn tmux
if status --is-interactive
    tmux 2> /dev/null; and exec true
end

# Ensure ssh agent is running
if test -z "$SSH_ENV"
    set -xg SSH_ENV $HOME/.ssh/environment
end

if not __ssh_agent_is_started
    __ssh_agent_start
end

# Ensure tmux continuum is running
tmux-continuum

starship init fish | source

