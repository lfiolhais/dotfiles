function __print_help_khard_rm
    echo "khard-rm [-h|--help] [-a|--addressbook NAME] [-n|--dry-run] [-N|--no-forget] [search terms...]"
    echo -e "\t-h | --help        => Prints this message"
    echo -e "\t-a | --addressbook => Address book to delete from. Defaults to 'work'"
    echo -e "\t-n | --dry-run     => List the selected contacts and stop, deleting nothing"
    echo -e "\t-N | --no-forget   => Delete the contacts but leave the chezmoi source state alone"
    echo
    echo -e "\tSelect with TAB in fzf, confirm with ENTER. Any trailing arguments are"
    echo -e "\tpassed to 'khard list' as search terms to narrow the picker."
end

function khard-rm --description "Delete several khard contacts at once and drop them from chezmoi"
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

    set -l abook work
    if set -q _flag_addressbook
        set abook $_flag_addressbook
    end

    # --parsable gives "uid<TAB>name<TAB>addressbook", one contact per line.
    set -l rows (khard list -a $abook --parsable $argv 2>/dev/null)
    if test (count $rows) -eq 0
        echo "khard-rm: no contacts found in address book '$abook'" >&2
        return 1
    end

    # --with-nth hides the uid column from the display without dropping it from
    # the line fzf hands back.
    set -l picked (printf '%s\n' $rows | fzf --multi --delimiter='\t' --with-nth=2.. \
        --prompt="delete > " \
        --header="TAB to mark, ENTER to confirm, ESC to abort")

    if test (count $picked) -eq 0
        echo "khard-rm: nothing selected"
        return 0
    end

    echo "The following "(count $picked)" contact(s) will be deleted from '$abook':"
    for row in $picked
        set -l parts (string split \t -- $row)
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

    set -l files
    set -l failed 0

    for row in $picked
        set -l parts (string split \t -- $row)
        set -l uid $parts[1]
        set -l name $parts[2]

        # Resolve the uid to its vcf before deleting anything. This doubles as a
        # safety check: khard's remove takes free-text search terms, so if a
        # "uid:" query ever stops meaning what we expect it would happily match
        # -- and delete -- the wrong card. Anything but exactly one hit is a skip.
        set -l file (khard filename -a $abook "uid:$uid" 2>/dev/null)
        if test (count $file) -ne 1
            set_color yellow
            echo "khard-rm: skipping '$name': uid:$uid matched "(count $file)" contacts" >&2
            set_color normal
            set failed 1
            continue
        end

        if khard remove -a $abook --force "uid:$uid" >/dev/null
            echo "removed: $name"
            set files $files $file[1]
        else
            set_color red
            echo "khard-rm: failed to remove '$name'" >&2
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

    if not command -q chezmoi
        echo "khard-rm: chezmoi is not installed, source state left untouched" >&2
        return 1
    end

    # 're-add' only updates files that still exist, so it cannot express a
    # deletion. 'forget' is what drops the entry from the source state.
    set_color green
    echo "Dropping "(count $files)" contact(s) from the chezmoi source state"
    set_color normal
    if not chezmoi forget --force $files
        set_color red
        echo "khard-rm: chezmoi forget failed" >&2
        set_color normal
        return 1
    end

    echo
    echo "Next steps:"
    echo "  chezmoi diff                      # review"
    echo "  cd "(chezmoi source-path)"        # commit the deletions"
    echo "  chezmoi update                    # on your other machines"

    return $failed
end
