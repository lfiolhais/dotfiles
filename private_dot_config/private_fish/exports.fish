# Instead of setting the PATH every time, set only once using
set -U fish_user_paths \
    /Users/lipe/.local/share/../bin \
    /opt/homebrew/opt/ruby/bin \
    /opt/homebrew/opt/gnu-tar/libexec/gnubin \
    /opt/homebrew/opt/openjdk@11/bin \
    /opt/homebrew/sbin \
    /opt/homebrew/bin \
    /opt/homebrew/opt/coreutils/libexec/gnubin \
    /Users/lipe/.cargo/bin \
    /Users/lipe/.rustup/toolchains/stable-aarch64-apple-darwin/bin/ \
    /usr/local/bin \
    /System/Cryptexes/App/usr/bin \
    /usr/bin \
    /bin \
    /usr/sbin \
    /sbin \
    /var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin \
    /var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin \
    /var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin \
    /Applications/Little Snitch.app/Contents/Components

test -r '/Users/lipe/.opam/opam-init/init.fish' && source '/Users/lipe/.opam/opam-init/init.fish' > /dev/null 2> /dev/null; or true

set -gx LD_LIBRARY_PATH (rustc --print sysroot)"/lib" $LD_LIBRARY_PATH

# Make vim the default editor.
set -gx EDITOR nvim

# Make Python use UTF-8 encoding for output to stdin, stdout, and stderr.
set -gx PYTHONIOENCODING UTF-8

# Highlight section titles in manual pages.
# $yellow is not set anywhere, so this exports an empty string and man pages
# are not highlighted. A real value is an escape sequence, e.g.
# (set_color -o yellow | string collect).
set -gx LESS_TERMCAP_md $yellow

# Use bat
batman --export-env | source

# bat pipe
eval (batpipe)

# Rust
set -gx RUST_SRC_PATH (rustc --print sysroot)/lib/rustlib/src/rust/src/

# XDG Spec
set -gx XDG_DATA_HOME $HOME/.local/share
set -gx XDG_CONFIG_HOME $HOME/.config
set -gx XDG_CACHE_HOME $HOME/.cache
set -gx XDG_STATE_HOME $HOME/.local/state

# Homebrew updates itself implicitly on every install, which makes an install
# unpredictably slow. The `update` function runs `brew update` explicitly.
set -gx HOMEBREW_NO_AUTO_UPDATE 1
