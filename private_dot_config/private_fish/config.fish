source $HOME/.config/fish/exports.fish
source $HOME/.config/fish/aliases.fish
# source $HOME/.config/fish/prompt.fish
source $HOME/.config/fish/greet.fish
source $HOME/.config/fish/colors.fish

if status --is-interactive
    tmux 2> /dev/null; and exec true
end

if test -z "$SSH_ENV"
    set -xg SSH_ENV $HOME/.ssh/environment
end

if not __ssh_agent_is_started
    __ssh_agent_start
end

starship init fish | source

