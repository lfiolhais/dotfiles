function __print_help_khard_rm
    echo "khard-rm [-h|--help] [-a|--addressbook NAME] [-n|--dry-run] [-N|--no-forget] [search terms...]"
    echo -e "\t-h | --help        => Prints this message"
    echo -e "\t-a | --addressbook => Address book to delete from. Defaults to 'work'"
    echo -e "\t-n | --dry-run     => List the selected contacts and stop, deleting nothing"
    echo -e "\t-N | --no-forget   => Delete the contacts but leave the chezmoi source state alone."
    echo -e "\t                      chezmoi recreates a managed file that is missing from"
    echo -e "\t                      the target, so the next 'chezmoi apply' brings every"
    echo -e "\t                      contact deleted this way straight back."
    echo
    echo -e "\tDeletes the vcf under ~/.config/khard/<addressbook>/default and drops"
    echo -e "\tits entry from the chezmoi source. Recovering one afterwards means git"
    echo -e "\thistory in "(chezmoi source-path 2>/dev/null; or echo "the chezmoi source directory")"."
    echo
    echo -e "\tThe picker lists each contact by name and email address, because two"
    echo -e "\tpeople can share a name and the card is chosen by what is on screen."
    echo
    echo -e "\tSelect with TAB in fzf, confirm with ENTER. Any trailing arguments are"
    echo -e "\tpassed to 'khard list' as search terms to narrow the picker."
end

function __khard_rm_emails --argument-names field --description "The addresses in khard's emails field, comma separated"
    # 'khard list -F emails' prints the field as a Python dict repr --
    # {'work': ['a@b.c'], 'home': ['d@e.f']} -- so the addresses come out of it
    # by matching what sits in quotes and contains an @.
    set -l addrs (string match --all --regex --groups-only "'([^']+@[^']+)'" -- $field)
    if test (count $addrs) -eq 0
        echo "(no email)"
    else
        string join ", " $addrs
    end
end

function khard-rm --description "Delete several khard contacts at once, dropping them from chezmoi unless -N"
    set -l options (fish_opt --short=h --long=help)
    set options $options (fish_opt --short=a --long=addressbook --required-val)
    set options $options (fish_opt --short=n --long=dry-run)
    set options $options (fish_opt --short=N --long=no-forget)
    argparse $options -- $argv
    or return 1

    if set -q _flag_help
        __print_help_khard_rm
        return 0
    end

    for cmd in khard fzf
        if not command -q $cmd
            set_color red
            echo "khard-rm: $cmd is not installed" >&2
            set_color normal
            return 1
        end
    end

    # chezmoi is only used at the end, to drop the deleted cards from the
    # source state -- checked here, before anything is deleted, because
    # discovering it missing after 'khard remove' strands source entries whose
    # next 'chezmoi apply' recreates every deleted contact. --no-forget never
    # touches the source state, so it works without chezmoi.
    if not set -q _flag_no_forget; and not command -q chezmoi
        set_color red
        echo "khard-rm: chezmoi is not installed, and deleting without it would let" >&2
        echo "the next 'chezmoi apply' recreate every deleted contact. --no-forget" >&2
        echo "deletes from this machine alone." >&2
        set_color normal
        return 1
    end

    set -l abook work
    if set -q _flag_addressbook
        set abook $_flag_addressbook
    end

    # Checked before asking khard, because khard's own answer for a
    # misspelled book is the same "no contacts" an empty one produces.
    if not test -d "$HOME/.config/khard/$abook/default"
        set_color red
        echo "khard-rm: no address book '$abook' under ~/.config/khard" >&2
        set_color normal
        return 1
    end

    # --parsable prints one contact per line, tab separated, in the order -F
    # names the fields.
    set -l rows (khard list -a $abook --parsable -F uid,formatted_name,emails $argv 2>/dev/null)
    if test (count $rows) -eq 0
        echo "khard-rm: no contacts found in address book '$abook'" >&2
        return 1
    end

    # Each line is "uid<TAB>label", where the label carries the name and the
    # addresses padded into a column. --with-nth=2.. keeps the uid out of the
    # display and out of what fzf searches, while leaving it on the line fzf
    # hands back.
    set -l lines
    for row in $rows
        set -l parts (string split \t -- $row)
        set -a lines (printf '%s\t%-34s %s' $parts[1] $parts[2] (__khard_rm_emails "$parts[3]"))
    end

    set -l picked (printf '%s\n' $lines | fzf --multi --delimiter='\t' --with-nth=2.. \
        --prompt="delete > " \
        --header="TAB to mark, ENTER to confirm, ESC to abort")

    if test (count $picked) -eq 0
        echo "khard-rm: nothing selected"
        return 0
    end

    echo "The following "(count $picked)" contact(s) will be deleted from '$abook':"
    for line in $picked
        set -l parts (string split \t -- $line)
        echo "  $parts[2]"
    end

    if set -q _flag_dry_run
        echo "khard-rm: dry run, nothing removed"
        return 0
    end

    read -l -P "Delete these "(count $picked)" contact(s)? [y/N] " reply
    if not string match -qir '^y(es)?$' -- $reply
        echo "khard-rm: aborted"
        return 1
    end

    # files and labels are parallel: labels[i] names files[i], so a card can
    # still be reported by name after its vcf is gone.
    set -l files
    set -l labels
    set -l failed 0

    for line in $picked
        set -l parts (string split \t -- $line)
        set -l uid $parts[1]
        set -l label (string trim -- $parts[2])

        # Resolve the uid to its vcf before deleting anything. This doubles as a
        # safety check: khard's remove takes free-text search terms, so if a
        # "uid:" query means something other than one card, khard would happily match
        # -- and delete -- the wrong card. Anything but exactly one hit is a skip.
        set -l file (khard filename -a $abook "uid:$uid" 2>/dev/null)
        if test (count $file) -ne 1
            set_color yellow
            echo "khard-rm: skipping '$label': uid:$uid matched "(count $file)" contacts" >&2
            set_color normal
            set failed 1
            continue
        end

        if khard remove -a $abook --force "uid:$uid" >/dev/null
            echo "removed: $label"
            set -a files $file[1]
            set -a labels $label
        else
            set_color red
            echo "khard-rm: failed to remove '$label'" >&2
            set_color normal
            set failed 1
        end
    end

    if test (count $files) -eq 0
        echo "khard-rm: no contacts were removed"
        return 1
    end

    if set -q _flag_no_forget
        echo "khard-rm: leaving the chezmoi source state untouched (--no-forget)"
        return $failed
    end

    # 'chezmoi forget' takes every path or none: hand it one path it does not
    # manage and it drops nothing, so a single card that has no source entry
    # would leave every other card deleted here still in the source, and the
    # next 'chezmoi apply' would bring all of them back. A card has no source
    # entry when another machine deleted it and that commit has reached this
    # source directory, and when it was written here with
    # DOTFILES_KHARD_UNTRACKED set. So ask chezmoi which of them it manages and
    # forget only those.
    set -l dirs
    for file in $files
        set -l dir (path dirname $file)
        contains -- $dir $dirs; or set -a dirs $dir
    end

    # --include=files asks only which cards have a source entry. Without it an
    # `exact_` source directory also reports the cards it is about to delete
    # from the target, and `chezmoi forget` would then be handed a path it does
    # not manage -- which it refuses for the whole list.
    set -l managed (chezmoi managed --include=files --path-style=absolute $dirs)
    or begin
        set_color red
        echo "khard-rm: 'chezmoi managed' failed, source state left untouched" >&2
        set_color normal
        return 1
    end

    set -l tracked
    set -l loose
    for i in (seq (count $files))
        if contains -- $files[$i] $managed
            set -a tracked $files[$i]
        else
            set -a loose $labels[$i]
        end
    end

    if test (count $loose) -gt 0
        set_color yellow
        echo (count $loose)" contact(s) had no entry in the chezmoi source, so there is"
        echo "nothing to forget for them:"
        set_color normal
        for label in $loose
            echo "  $label"
        end
    end

    if test (count $tracked) -eq 0
        echo "khard-rm: the chezmoi source already had no entry for any of them"
        return $failed
    end

    # 're-add' only updates files that still exist, so it cannot express a
    # deletion. 'forget' is what drops the entry from the source state.
    set_color green
    echo "Dropping "(count $tracked)" contact(s) from the chezmoi source state"
    set_color normal
    if not chezmoi forget --force $tracked
        set_color red
        echo "khard-rm: chezmoi forget failed" >&2
        set_color normal
        return 1
    end

    echo
    echo "Next steps:"
    echo "  chezmoi diff"
    echo "  cd "(chezmoi source-path)
    echo "  git status, then commit the removals by hand"
    echo
    echo "On another machine: 'chezmoi apply' after pulling. 'chezmoi update'"
    echo "pulls and applies in one step, and re-runs any bootstrap script whose"
    echo "content changed with it."

    return $failed
end
