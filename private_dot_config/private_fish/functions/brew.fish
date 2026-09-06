function brew --wraps brew --description "brew, with the subcommands that desync the Brewfile blocked"
    # ~/.config/Brewfile is a dump of what this machine has installed, and
    # `chezmoi-packages` is the only thing that writes it. A `brew install` run
    # outside that command leaves the machine holding a package the source state
    # does not record; the next `chezmoi-packages dump` on another machine then
    # writes a Brewfile without it, and the package disappears from every
    # machine at the following apply.
    #
    # Only the subcommands that change *which* packages exist are blocked.
    # update, upgrade, cleanup, bundle, services and every read-only query go
    # straight through -- which is also what keeps the `update` function, whose
    # Homebrew step is `brew upgrade`, working.
    set -l blocked install reinstall uninstall remove rm tap untap

    if set -q DOTFILES_BREW_UNGUARDED; or not contains -- "$argv[1]" $blocked
        command brew $argv
        return $status
    end

    set_color --bold red
    echo "brew $argv[1] is blocked here." >&2
    set_color normal
    echo "It changes which packages this machine has without recording it, and" >&2
    echo "the Brewfile then describes a machine this one is no longer." >&2
    echo >&2
    echo "chezmoi-packages does both halves in one step:" >&2
    echo >&2
    echo "    chezmoi-packages search NAME   what each platform calls it" >&2
    echo "    chezmoi-packages add NAME …    install it and record it" >&2
    echo "    chezmoi-packages remove NAME   uninstall it and drop the record" >&2
    echo "    chezmoi-packages dump          re-read this machine into the Brewfile" >&2
    echo >&2
    echo "To reach brew itself anyway -- debugging brew, or a package you do not" >&2
    echo "want recorded -- either bypass this function for one command:" >&2
    echo >&2
    echo "    command brew $argv" >&2
    echo >&2
    echo "or turn the guard off for the rest of this shell:" >&2
    echo >&2
    echo "    set -x DOTFILES_BREW_UNGUARDED 1" >&2
    echo "    set -e DOTFILES_BREW_UNGUARDED     # when finished" >&2
    echo >&2
    echo "Either way, 'chezmoi-packages dump' afterwards puts the Brewfile back" >&2
    echo "in step with the machine." >&2
    return 1
end
