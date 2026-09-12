function khard-track --description "Record khard contacts in the chezmoi source so they reach other machines"
    if not command -q chezmoi
        set_color red
        echo "khard-track: chezmoi is not installed" >&2
        set_color normal
        return 1
    end

    # A card written by 'khard new' has no entry in the chezmoi source, so it
    # exists on this machine and nowhere else: a reinstall, or a second machine,
    # never sees it, and nothing reports that because an untracked file is not a
    # difference chezmoi knows about. The khard wrapper does this after every
    # write, for every address book under ~/.config/khard; this adds the work
    # book alone, and is safe to run at any time.
    #
    # --encrypt keeps every card an age blob in the source, and --exact keeps
    # the exact_ prefix on the directory, which is what carries a deletion from
    # one machine to the rest. The khard wrapper passes both for the same
    # reasons.
    chezmoi add --encrypt --exact ~/.config/khard/work/default
    or return 1

    echo "Tracked. 'khard-status' lists any contact still loose, by name."
    echo "Review with 'chezmoi diff', then commit in "(chezmoi source-path)
end
