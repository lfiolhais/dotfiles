function khard --wraps khard --description "khard, recording every change it makes in the chezmoi source"
    # Each contact is a separate file in the chezmoi source, and a card khard
    # has just written has no source entry at all -- so it exists on this
    # machine only, and a reinstall or a second machine never sees it. Nothing
    # reports that, because an untracked file is not a difference chezmoi knows
    # about; the contact is simply gone later.
    #
    # So the tracking happens here rather than being remembered: the
    # subcommands that write a card re-add the address book afterwards.
    # DOTFILES_KHARD_UNTRACKED skips it, for a change that should stay on this
    # machine.
    set -l writes new edit add-email merge copy move modify

    command khard $argv
    set -l code $status

    if set -q DOTFILES_KHARD_UNTRACKED
        return $code
    end
    if test $code -ne 0; or not contains -- "$argv[1]" $writes
        return $code
    end
    if not command -q chezmoi
        return $code
    end

    # 'remove' is deliberately not in the list above: chezmoi add cannot express
    # a deletion, so dropping a contact needs `khard-rm`, which forgets the
    # source entry as well.
    set -l books ~/.config/khard/*/default
    if test (count $books) -eq 0
        return $code
    end

    chezmoi add $books
    or begin
        echo "khard: the contact was written but not recorded in chezmoi." >&2
        echo "       Run 'khard-track', or 'khard-status' to see what is loose." >&2
        return 1
    end

    return $code
end
