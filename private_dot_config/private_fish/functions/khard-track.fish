function khard-track --description "Track new khard contacts in chezmoi so exact_ does not delete them"
    if not command -q chezmoi
        set_color red
        echo "khard-track: chezmoi is not installed" >&2
        set_color normal
        return 1
    end

    # The contacts directory is exact_ in the chezmoi source, so a card created
    # by 'khard new' that has never been added is deleted by the next apply.
    # Run this after adding or editing a contact. Safe to run at any time.
    chezmoi add ~/.config/khard/work/default
    or return 1

    echo "Tracked. Review with 'chezmoi diff', then commit in "(chezmoi source-path)
end
