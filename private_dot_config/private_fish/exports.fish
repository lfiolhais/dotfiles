# Instead of setting the PATH every time, set only once using
# set -U fish_user_paths $HOME/usr/local/sbin
# $HOME/.cargo/bin $HOME/usr/bin/ /usr/local/bin/ /bin
# /usr/lib/jvm/default/bin /usr/bin/site_perl /usr/bin/vendor_perl
# /usr/bin/core_perl
#
# set -gx PATH /home/lfiolhais/.local/bin /usr/local/sbin $HOME/.cargo/bin $PATH
set -gx LD_LIBRARY_PATH (rustc --print sysroot)"/lib" $LD_LIBRARY_PATH

# Make vim the default editor.
set -gx EDITOR nvim

# Make Python use UTF-8 encoding for output to stdin, stdout, and stderr.
set -gx PYTHONIOENCODING UTF-8

# Highlight section titles in manual pages.
set -gx LESS_TERMCAP_md $yellow

# Don’t clear the screen after quitting a manual page.
set -gx MANPAGER 'less -X'

# Rust
set -gx RUST_SRC_PATH (rustc --print sysroot)/lib/rustlib/src/rust/src/

# XDG Spec
set -gx XDG_DATA_HOME $HOME/.local/share
set -gx XDG_CONFIG_HOME $HOME/.config
set -gx XDG_CACHE_HOME $HOME/.cache

# GTK Dark Theme
set -gx GTK2_RC_FILES "/usr/share/themes/Materia-dark/gtk-2.0/gtkrc"

# Disbale Homebrew Auto Update
set -gx HOMEBREW_NO_AUTO_UPDATE 1

# Enable iterm tmux integration
set -x ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX YES
