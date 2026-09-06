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
    # difference chezmoi knows about. The khard wrapper runs this after every
    # write; this is the same step by hand, and safe to run at any time.
    chezmoi add ~/.config/khard/work/default
    or return 1

    echo "Tracked. 'khard-status' lists any contact still loose, by name."
    echo "Review with 'chezmoi diff', then commit in "(chezmoi source-path)
end
