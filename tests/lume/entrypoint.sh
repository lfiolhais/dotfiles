#!/usr/bin/env bash
# In-guest macOS validation invoked by tests/macos.py over `lume ssh`.
# Env: FULL=true|false (run the real bootstrap), SRC=path of the read-only repo
# mount. No real age key is present, so encrypted files are excluded from every
# chezmoi operation.
set -eu

FULL="${FULL:-false}"
# Where Lume mounts --shared-dir inside the guest, in a folder named after the
# host directory. This is the first place to look when a run cannot find the repo.
SRC="${SRC:-/Volumes/My Shared Files/chezmoi}"
BIN="$HOME/.local/bin"
# Pinned so a run is reproducible; bump when the upstream releases move on.
SHELLCHECK_VERSION="v0.11.0"
AGE_VERSION="v1.3.1"

mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# The Lume base images ship no package manager to rely on (and installing one
# would pollute what --full is meant to test), so fetch the three tools needed as
# static arm64 binaries into ~/.local/bin. No sudo, nothing installed system-wide.
if ! command -v chezmoi > /dev/null 2>&1; then
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$BIN"
fi
if ! command -v shellcheck > /dev/null 2>&1; then
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.darwin.aarch64.tar.gz" |
        tar -xz -C "$BIN" --strip-components=1 "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
fi
if ! command -v age-keygen > /dev/null 2>&1; then
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-darwin-arm64.tar.gz" |
        tar -xz -C "$BIN" --strip-components=1 age/age age/age-keygen
fi

# Throwaway chezmoi config: a fresh age key (real secrets stay excluded) plus the
# darwin default of sudo=false. This bypasses .chezmoi.toml.tmpl's prompt logic.
mkdir -p "$HOME/.config/chezmoi"
# age-keygen reports the public key on stderr as normal output, not an error.
age-keygen -o "$HOME/.config/chezmoi/key.txt" 2> /dev/null
recipient="$(age-keygen -y "$HOME/.config/chezmoi/key.txt")"
cat > "$HOME/.config/chezmoi/chezmoi.toml" << EOF
encryption = "age"
[age]
    identity = "$HOME/.config/chezmoi/key.txt"
    recipient = "$recipient"
[data]
    sudo = false
EOF

# Render every non-encrypted target: proves templates render on this macOS version.
chezmoi archive --source "$SRC" --exclude encrypted --output /tmp/state.tar

# Lint the bootstrap scripts that apply to macOS (empty renders are gated off).
for f in "$SRC"/run_*.sh "$SRC"/run_*.sh.tmpl; do
    [ -e "$f" ] || continue
    case "$f" in
        *.tmpl) chezmoi execute-template --source "$SRC" < "$f" > /tmp/script.sh ;;
        *) cp "$f" /tmp/script.sh ;;
    esac
    [ -s /tmp/script.sh ] || continue
    bash -n /tmp/script.sh
    shellcheck -S error /tmp/script.sh
done

if [ "$FULL" = "true" ]; then
    chezmoi apply --source "$SRC" --exclude encrypted --verbose
fi
