function mas --wraps mas --description "mas, with the subcommands that desync the Brewfile blocked"
    # ~/.config/Brewfile records App Store apps as `mas "Name", id: …` alongside
    # the formulae and casks, and `chezmoi-packages` is the only thing that
    # writes it. An app installed or removed outside that command leaves the
    # machine holding something the source state does not record; the next
    # `chezmoi-packages dump` on another machine then writes a Brewfile without
    # it, and the app disappears from every machine at the following apply.
    #
    # Only the subcommands that change *which* apps exist are blocked. `get`,
    # `purchase` and `lucky` are all installs -- `lucky` installs the first
    # search result -- so they are blocked with `install`. update, upgrade,
    # outdated and every read-only query go straight through, which is what
    # keeps the `update` function, whose App Store step is `mas upgrade`,
    # working.
    set -l blocked install get purchase lucky uninstall

    if set -q DOTFILES_MAS_UNGUARDED; or not contains -- "$argv[1]" $blocked
        command mas $argv
        return $status
    end

    set_color --bold red
    echo "mas $argv[1] is blocked here." >&2
    set_color normal
    echo "It changes which App Store apps this machine has without recording" >&2
    echo "it, and the Brewfile then describes a machine this one is no longer." >&2
    echo >&2
    echo "There is no chezmoi-packages verb for the App Store: it reads the" >&2
    echo "machine rather than installing from a name. So the route is two steps," >&2
    echo "the command and then the record:" >&2
    echo >&2
    echo "    command mas $argv" >&2
    echo "    chezmoi-packages dump          re-read this machine into the Brewfile" >&2
    echo >&2
    echo "or turn the guard off for the rest of this shell:" >&2
    echo >&2
    echo "    set -x DOTFILES_MAS_UNGUARDED 1" >&2
    echo "    set -e DOTFILES_MAS_UNGUARDED     # when finished" >&2
    echo >&2
    echo "Either way, 'chezmoi-packages dump' afterwards puts the Brewfile back" >&2
    echo "in step with the machine. The App Store app itself installs without" >&2
    echo "passing through here, so the same dump is what records those." >&2
    return 1
end
