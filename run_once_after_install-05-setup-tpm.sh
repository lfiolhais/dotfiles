#!/usr/bin/env bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# Source config
tmux -c 'tmux source .tmux.conf'

~/.tmux/plugins/tpm/bin/install_plugins
~/.tmux/plugins/tpm/bin/update_plugins all

# Apply Git patch to fix tmux-resurrect
cd ~/.tmux/plugins/tmux-resurrect/ && git apply ~/.config/tmux-resurrect-patch.diff && cd -
