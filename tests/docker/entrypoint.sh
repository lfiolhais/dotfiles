#!/usr/bin/env bash
# In-container Linux validation invoked by tests/linux.py.
# Env: SUDO=true|false (the chezmoi data flag), FULL=true|false (run the real
# bootstrap). The repo is mounted read-only at /src; no real age key is present,
# so encrypted files are excluded from every chezmoi operation.
set -eu

SUDO="${SUDO:-false}"
FULL="${FULL:-false}"

# Tools the harness itself needs (the bootstrap installs the rest under --full).
if command -v apt-get > /dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl git shellcheck age
else
    # Fedora carries ShellCheck/age in its base repos; RHEL rebuilds need EPEL.
    grep -q '^ID=fedora' /etc/os-release || dnf install -y -q epel-release
    # --allowerasing lets curl replace RHEL's curl-minimal instead of conflicting.
    dnf install -y -q --allowerasing curl git ShellCheck age
fi

sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin

# Throwaway chezmoi config: a fresh age key (real secrets stay excluded) plus the
# sudo data flag under test. This bypasses .chezmoi.toml.tmpl's interactive prompt.
mkdir -p "$HOME/.config/chezmoi"
age-keygen -o "$HOME/.config/chezmoi/key.txt" 2> /dev/null
recipient="$(age-keygen -y "$HOME/.config/chezmoi/key.txt")"
cat > "$HOME/.config/chezmoi/chezmoi.toml" << EOF
encryption = "age"
[age]
    identity = "$HOME/.config/chezmoi/key.txt"
    recipient = "$recipient"
[data]
    sudo = $SUDO
EOF

# Render every non-encrypted target: proves templates render for this distro + sudo mode.
chezmoi archive --source /src --exclude encrypted --output /tmp/state.tar

# Lint the bootstrap scripts that apply to this target (empty renders are gated off).
for f in /src/run_*.sh /src/run_*.sh.tmpl; do
    [ -e "$f" ] || continue
    case "$f" in
        *.tmpl) chezmoi execute-template --source /src < "$f" > /tmp/script.sh ;;
        *) cp "$f" /tmp/script.sh ;;
    esac
    [ -s /tmp/script.sh ] || continue
    bash -n /tmp/script.sh
    shellcheck -S error /tmp/script.sh
done

if [ "$FULL" = "true" ]; then
    chezmoi apply --source /src --exclude encrypted --verbose
fi
