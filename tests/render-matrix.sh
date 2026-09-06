#!/usr/bin/env bash
# Render every template in this repository for each deployment target and lint
# what comes out: shell with bash -n and shellcheck, fish with fish -n.
#
#   tests/render-matrix.sh              every template
#   tests/render-matrix.sh <path> …     one or more source-relative paths
#
# chezmoi fills .chezmoi.os from the machine it is running on, so the target OS
# cannot be chosen through data. Each template is copied with `.chezmoi.os`
# rewritten to `.fakeos`, which is then supplied as data alongside `.sudo`.
# Everything else about the render is the real one.
#
# That substitution is why this is a pre-check rather than a proof. It says
# whether the other OS's branch renders and parses; it does not run a Linux
# chezmoi, and it knows nothing about that machine's package names or its
# osRelease. `tests/linux.py` answers those, in containers, and is the authority.
# This runs in seconds and needs no Docker, so it is what to run while editing.
#
# Everything here is read-only: nothing is written outside $TMPDIR, no script is
# executed, and $HOME is never touched.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${TMPDIR:-/tmp}/render-matrix"
mkdir -p "$work"
rc=0

# Every profile .chezmoi.toml.tmpl can produce. macOS never prompts for sudo, so
# darwin has one profile and Linux has two.
TARGETS=("darwin true" "linux true" "linux false")

render() {
    local os="$1" sudo_flag="$2" rel="$3" out="$4"

    cat > "$work/chezmoi.toml" << CFG
[data]
    sudo = ${sudo_flag}
    fakeos = "${os}"
CFG

    sed -e 's/\.chezmoi\.os/.fakeos/g' "$repo/$rel" > "$work/in.tmpl"

    # --no-tty: chezmoi prompts on /dev/tty rather than stdin, so a prompt raised
    # behind captured output would hang with nothing on screen.
    chezmoi execute-template --no-tty --no-pager --source "$repo" \
        --config "$work/chezmoi.toml" \
        --cache "$work/cache" \
        --persistent-state "$work/state.boltdb" \
        < "$work/in.tmpl" > "$out" 2> "$out.err"
}

lint_one() {
    local rel="$1" os="$2" sudo_flag="$3" kind="$4"
    local out
    out="$work/$(echo "$rel" | tr / _).$os.$sudo_flag"

    if ! render "$os" "$sudo_flag" "$rel" "$out"; then
        echo "FAIL render   $rel [$os sudo=$sudo_flag]"
        sed 's/^/          /' "$out.err"
        rc=1
        return
    fi

    # A template gated off for this target renders empty, and chezmoi skips an
    # empty run_ script. Empty is a pass.
    if [ ! -s "$out" ]; then
        printf 'skip empty   %s [%s sudo=%s]\n' "$rel" "$os" "$sudo_flag"
        return
    fi

    case "$kind" in
        sh)
            if ! bash -n "$out" 2> "$out.err"; then
                echo "FAIL bash -n  $rel [$os sudo=$sudo_flag]"
                sed 's/^/          /' "$out.err"
                rc=1
                return
            fi
            if ! shellcheck -S error "$out" > "$out.err" 2>&1; then
                echo "FAIL shell    $rel [$os sudo=$sudo_flag]"
                sed 's/^/          /' "$out.err"
                rc=1
                return
            fi
            if ! shellcheck -S warning "$out" > "$out.err" 2>&1; then
                echo "warn shell    $rel [$os sudo=$sudo_flag]"
                sed 's/^/          /' "$out.err"
            fi
            ;;
        fish)
            if ! fish -n "$out" 2> "$out.err"; then
                echo "FAIL fish -n  $rel [$os sudo=$sudo_flag]"
                sed 's/^/          /' "$out.err"
                rc=1
                return
            fi
            ;;
    esac

    printf 'ok   %-6s   %s [%s sudo=%s]\n' "$kind" "$rel" "$os" "$sudo_flag"
}

collect() {
    if [ "$#" -gt 0 ]; then
        printf '%s\n' "$@"
        return
    fi
    (
        cd "$repo" || exit 1
        find . -type f \
            \( -name '*.fish' -o -name '*.fish.tmpl' \
               -o -name 'run_*.sh' -o -name 'run_*.sh.tmpl' \
               -o -name 'dot_bashrc*' \) \
            -not -path './.git/*' -not -path './.claude/*' -not -path './tests/*' \
            | sed 's|^\./||' | sort
    )
}

for tool in chezmoi shellcheck fish; do
    command -v "$tool" > /dev/null 2>&1 || echo "note: $tool is not installed; its checks are skipped" >&2
done

while read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
        *.fish | *.fish.tmpl) kind="fish" ;;
        *) kind="sh" ;;
    esac
    for target in "${TARGETS[@]}"; do
        # shellcheck disable=SC2086  # two words, deliberately split
        set -- $target
        lint_one "$rel" "$1" "$2" "$kind"
    done
done < <(collect "$@")

echo
if [ "$rc" -ne 0 ]; then
    echo "FAILED. tests/linux.py renders the Linux targets for real, in containers."
else
    echo "Every template renders and parses for every target."
fi
exit "$rc"
