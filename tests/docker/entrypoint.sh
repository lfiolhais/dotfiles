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
    # Fedora carries ShellCheck/age in its base repos; RHEL rebuilds need EPEL --
    # and CRB, which several EPEL packages depend on. The bootstrap script enables
    # both itself, but the package-name check below runs without it.
    if ! grep -q '^ID=fedora' /etc/os-release; then
        dnf install -y -q dnf-plugins-core epel-release
        dnf config-manager --set-enabled crb 2> /dev/null \
            || dnf config-manager --set-enabled powertools 2> /dev/null \
            || true
    fi
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

# Confirm every package name the manifest targets at this distro actually exists
# in its repositories. The 01 script installs them in one strict transaction, so a
# single bad name would abort the whole bootstrap; this asks first and installs
# nothing. The names do not depend on the sudo flag, so checking one mode per
# distro covers the manifest -- the no-sudo profile's mise names are exercised by
# `mise install` under --full instead.
if [ "$SUDO" = "true" ]; then
    target="$(chezmoi execute-template --source /src '{{ includeTemplate "linux-target" . }}')"
    read -r -a names <<< "$(chezmoi execute-template --source /src \
        '{{ includeTemplate "linux-packages" . }}' | tr '\n' ' ')"

    if command -v apt-cache > /dev/null 2>&1; then
        resolves() { apt-cache show "$1" > /dev/null 2>&1; }
    else
        resolves() { dnf info --quiet "$1" > /dev/null 2>&1; }
    fi

    echo "checking ${#names[@]} package names against the $target repositories"
    unresolved=()
    for name in "${names[@]}"; do
        resolves "$name" || unresolved+=("$name")
    done

    if [ "${#unresolved[@]}" -ne 0 ]; then
        echo "not found in the $target repositories: ${unresolved[*]}" >&2
        echo "fix the names in .chezmoidata/packages.toml, or drop the $target" >&2
        echo "field so the tool is skipped on this distro." >&2
        exit 1
    fi
fi

if [ "$FULL" = "true" ]; then
    chezmoi apply --source /src --exclude encrypted --verbose
fi
