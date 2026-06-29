# Setup fzf
fzf --fish | source

source $HOME/.config/fish/exports.fish
source $HOME/.config/fish/aliases.fish
source $HOME/.config/fish/greet.fish

set -g fish_key_bindings fish_vi_key_bindings

starship init fish | source

