#!/usr/bin/env bash
# In-guest macOS validation invoked by tests/macos.py over `lume ssh`.
# FULL=true|false and SRC=<read-only repo mount> are set by tests/macos.py.
# LUME_PASSWORD overrides the guest account password that FULL uses to grant
# sudo (default `lume`); it is read here in the guest, so pass it inside the
# `lume ssh` command rather than exporting it on the host. No real age key is
# present, so encrypted files are excluded from every chezmoi operation.
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
# age-keygen -o refuses to overwrite, and a reused --keep guest still has the key
# from the last run, so clear it first and regenerate from a known state.
rm -f "$HOME/.config/chezmoi/key.txt"
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

printf '=== %s %s (%s) ===\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)" "$(uname -m)"
chezmoi --version | head -1

# Render every non-encrypted target: proves templates render on this macOS version.
echo "rendering every non-encrypted target (chezmoi archive):"
chezmoi archive --source "$SRC" --exclude encrypted --output /tmp/state.tar
printf '  %s files rendered\n' "$(tar -tf /tmp/state.tar | wc -l | tr -d ' ')"

# Lint the bootstrap scripts that apply to macOS (empty renders are gated off).
echo "linting darwin bootstrap scripts (bash -n, shellcheck -S error):"
linted=0
for f in "$SRC"/run_*.sh "$SRC"/run_*.sh.tmpl; do
    [ -e "$f" ] || continue
    case "$f" in
        *.tmpl) chezmoi execute-template --source "$SRC" < "$f" > /tmp/script.sh ;;
        *) cp "$f" /tmp/script.sh ;;
    esac
    [ -s /tmp/script.sh ] || { printf '  skip (empty on darwin)  %s\n' "$(basename "$f")"; continue; }
    bash -n /tmp/script.sh
    shellcheck -S error /tmp/script.sh
    printf '  ok  %s\n' "$(basename "$f")"
    linted=$((linted + 1))
done
printf '  %d scripts linted\n' "$linted"

if [ "$FULL" = "true" ]; then
    # The darwin bootstrap needs administrator sudo: Homebrew's installer creates
    # and chowns /opt/homebrew, and 02-setup-darwin opens with `sudo -v`. The Lume
    # image's `lume` user is an admin, but %admin sudo wants the account password
    # and `lume ssh` has no terminal to type it at, so authenticate once and drop
    # a NOPASSWD rule. Throwaway VM; `lume` is the trycua images' published
    # password and LUME_PASSWORD overrides it.
    if ! sudo -n true 2> /dev/null; then
        if ! printf '%s\n' "${LUME_PASSWORD:-lume}" | sudo -S -p '' -v 2> /dev/null; then
            echo "sudo rejected the guest account password; set LUME_PASSWORD to the image's own" >&2
            exit 1
        fi
        # Validate the rule in a temp file before installing it: a syntax error in
        # anything under /etc/sudoers.d makes sudo refuse every call, and the run
        # would then have no way to sudo the bad file back out. The name carries no
        # `.` because sudo's includedir skips those.
        rule_file="$(mktemp)"
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$(id -un)" > "$rule_file"
        sudo -n visudo -cf "$rule_file" > /dev/null
        sudo -n install -m 0440 -o root -g wheel "$rule_file" /etc/sudoers.d/chezmoi-test
        rm -f "$rule_file"
    fi

    # 04-setup-fish makes fish the login shell with `chsh`, which asks for the
    # account password on a terminal `lume ssh` does not provide. There is no way
    # to answer it: `chsh` authenticates against Open Directory, which is the
    # framework /usr/bin/chsh links, so there is no PAM service to relax and no
    # flag that takes a password. What 04 compares is what Open Directory
    # records, so recording the answer here is what keeps it from asking -- the
    # same root privilege granted above, used on the same database `chsh` writes.
    #
    # This is the one step of the bootstrap a --full run does not exercise.
    # fish is not installed yet; 04 resolves the same path once Homebrew has put
    # it there, and the Apple Silicon prefix is what every darwin script assumes.
    sudo -n dscl . -create "/Users/$(id -un)" UserShell /opt/homebrew/bin/fish
    printf 'login shell recorded as %s, so 04 has nothing to prompt for\n' \
        /opt/homebrew/bin/fish

    # The guest has never signed in to the App Store, so the App Store half of
    # 01-install-packages can install nothing here. `mas install` does not say so
    # and return: it waits on a sign-in that cannot happen on a machine with no
    # one at the keyboard. brew bundle skips an entry whose name or id is in this
    # variable, and the ids are what go in it -- the names have spaces and the
    # variable is split on whitespace.
    HOMEBREW_BUNDLE_MAS_SKIP="$(awk -F'id: ' '/^mas /{print $2}' \
        "$SRC/private_dot_config/Brewfile" | tr -d ' ' | tr '\n' ' ')"
    export HOMEBREW_BUNDLE_MAS_SKIP
    printf 'skipping %s App Store apps: no account in this guest\n' \
        "$(printf '%s' "$HOMEBREW_BUNDLE_MAS_SKIP" | wc -w | tr -d ' ')"

    # A guest behind Lume's NAT drops a long download more often than the host
    # does, and one cask that cannot be fetched fails `brew bundle`, which fails
    # 01 and stops the apply before anything after it runs. brew hands this to
    # curl's --retry, where its own default is 3.
    export HOMEBREW_CURL_RETRIES=5

    # What the bootstrap needs from the guest, asked before it runs so that a
    # failure later has its cause already on screen. setup-xcode-cli exits 1
    # without Rosetta and waits on a GUI installer without the command-line
    # tools; 03-setup-dock drives the Dock and 07-setup-nas bootstraps a launchd
    # job into `gui/<uid>`, and both of those need the account logged in to the
    # window server.
    echo "guest preconditions:"
    if pkgutil --pkg-info=com.apple.pkg.CLTools_Executables > /dev/null 2>&1; then
        echo "  ok    the Xcode command-line tools are installed"
    else
        echo "  MISSING  the Xcode command-line tools: setup-xcode-cli waits on a GUI installer" >&2
    fi
    if /usr/bin/pgrep oahd > /dev/null 2>&1; then
        echo "  ok    Rosetta 2 is installed"
    else
        echo "  absent   Rosetta 2: setup-xcode-cli installs it, and exits 1 if that fails"
    fi
    if launchctl print "gui/$(id -u)" > /dev/null 2>&1; then
        echo "  ok    the account is logged in to a GUI session (gui/$(id -u))"
    else
        echo "  MISSING  a GUI session: 07-setup-nas cannot bootstrap into gui/$(id -u)" >&2
    fi

    echo "the bootstrap runs these non-empty darwin scripts (chezmoi picks the order):"
    for f in "$SRC"/run_*.sh "$SRC"/run_*.sh.tmpl; do
        [ -e "$f" ] || continue
        case "$f" in
            *.tmpl) chezmoi execute-template --source "$SRC" < "$f" > /tmp/probe.sh 2> /dev/null || continue ;;
            *) cp "$f" /tmp/probe.sh ;;
        esac
        if [ -s /tmp/probe.sh ]; then printf '  %s\n' "$(basename "$f")"; fi
    done

    echo "running the real bootstrap (chezmoi apply --verbose):"
    apply_rc=0
    chezmoi apply --source "$SRC" --exclude encrypted --verbose || apply_rc=$?

    # Homebrew is on PATH for a shell the bootstrap started, not for this one.
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    # What the bootstrap was supposed to leave behind, asked of the machine
    # rather than of the exit code: 03-setup-dock ends in an echo and 01's App
    # Store half reports without stopping, so a script exiting 0 is not evidence
    # that its work happened.
    failures=0

    # A check that never returns holds the whole run open the way a bootstrap step
    # can: `dockutil --list` addresses the Dock, and a login fish sources every
    # file this repository deploys. macOS ships no `timeout`, so each one is given
    # a ceiling here, and reaching it is reported rather than waited out.
    CHECK_LIMIT=300

    with_limit() {
        # Run a command with a ceiling in seconds. Returns 124 when it is reached.
        local limit="$1"
        shift
        "$@" &
        local pid=$!
        local waited=0
        while kill -0 "$pid" 2> /dev/null; do
            if [ "$waited" -ge "$limit" ]; then
                kill -9 "$pid" 2> /dev/null || true
                wait "$pid" 2> /dev/null || true
                return 124
            fi
            sleep 1
            waited=$((waited + 1))
        done
        wait "$pid"
    }

    check() {
        # Report one expectation. $1 names it, the rest is the command that answers.
        local what="$1"
        shift
        local rc=0
        with_limit "$CHECK_LIMIT" "$@" > /tmp/check.out 2>&1 || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '  ok    %s\n' "$what"
            return
        fi
        failures=$((failures + 1))
        if [ "$rc" -eq 124 ]; then
            printf '  FAIL  %s (no answer in %ss)\n' "$what" "$CHECK_LIMIT"
        else
            printf '  FAIL  %s\n' "$what"
        fi
        tail -5 /tmp/check.out | sed 's/^/          /'
    }

    brewfile_installed() {
        grep -v '^mas ' "$HOME/.config/Brewfile" | brew bundle check --file=- --no-upgrade
    }

    login_shell_is_fish() {
        local recorded
        recorded="$(dscl . -read "/Users/$(id -un)" UserShell | awk '{print $2}')"
        [ "$recorded" = "$(command -v fish)" ]
    }

    login_fish_is_quiet() {
        # A login fish prints nothing when every file it sources parses and every
        # command it calls is there; anything it does print is what a new terminal
        # would open with.
        local noise
        noise="$(fish --login --command true 2>&1)"
        [ -z "$noise" ]
    }

    agent_is_loaded() {
        launchctl print "gui/$(id -u)/xyz.botasal.mount-nas"
    }

    filters_are_built() {
        [ -x "$HOME/.config/aerc/filters/colorize" ] && [ -x "$HOME/.config/aerc/filters/wrap" ]
    }

    dock_carries_ghostty() {
        dockutil --list | grep -q Ghostty
    }

    bat_cache_has_the_repo_theme() {
        # 05 runs `bat cache --build`, which compiles the themes this repository
        # deploys into ~/.cache/bat. `bat --list-themes` names a deployed theme
        # whether or not that has happened, so the built file is what is asked
        # for, and the listing then says the build took the repository's themes
        # in rather than only bat's own.
        [ -f "$HOME/.cache/bat/themes.bin" ] || return 1
        bat --list-themes | grep -q "Catppuccin Mocha"
    }

    nothing_is_left_to_apply() {
        local pending
        pending="$(chezmoi status --source "$SRC" --exclude encrypted)"
        [ -z "$pending" ] || { printf '%s\n' "$pending"; return 1; }
    }

    echo
    echo "=== what the bootstrap produced ==="
    check "every Brewfile formula and cask is installed (01)" brewfile_installed
    check "fish is the login shell (04)" login_shell_is_fish
    check "a login fish starts with nothing to say (04)" login_fish_is_quiet
    check "bat's cache carries the deployed theme (05)" bat_cache_has_the_repo_theme
    check "the mount-nas agent is loaded (07)" agent_is_loaded
    check "aerc's colorize and wrap filters are built (09)" filters_are_built
    check "the Dock carries the apps 03 adds" dock_carries_ghostty
    check "nothing is left to apply (chezmoi status)" nothing_is_left_to_apply

    echo
    echo "=== --full summary ==="
    if command -v brew > /dev/null 2>&1; then
        printf '  brew: %s formulae, %s casks\n' \
            "$(brew list --formula 2> /dev/null | wc -l | tr -d ' ')" \
            "$(brew list --cask 2> /dev/null | wc -l | tr -d ' ')"
    else
        echo "  brew: not installed"
    fi
    if [ "$apply_rc" -eq 0 ]; then
        echo "  chezmoi apply: ok"
    else
        echo "  chezmoi apply: exit $apply_rc -- the last 'chezmoi:' line above names the script that stopped it"
    fi
    printf '  checks: %d failed\n' "$failures"

    if [ "$apply_rc" -ne 0 ]; then
        exit "$apply_rc"
    fi
    [ "$failures" -eq 0 ] || exit 1
fi
