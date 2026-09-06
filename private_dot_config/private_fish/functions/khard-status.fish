function __khard_name --argument-names file --description "The FN line of a vCard, or the filename when it has none"
    # FN is the vCard's formatted name: the one line in the card that a person
    # can recognise. Everything else in the file is a uid or an encoding.
    set -l name (cat $file 2>/dev/null | string match --regex --groups-only '^FN[^:]*:(.*)')
    if test -z "$name"
        echo "(no FN)"
    else
        string trim -- $name[1]
    end
end

function __khard_source_name --argument-names target --description "The FN of a card that exists only in the chezmoi source"
    set -l name (chezmoi cat $target 2>/dev/null | string match --regex --groups-only '^FN[^:]*:(.*)')
    if test -z "$name"
        echo "(could not decrypt)"
    else
        string trim -- $name[1]
    end
end

function khard-status --description "Say which contacts differ between this machine and the chezmoi source"
    set -l options (fish_opt --short=h --long=help)
    set options $options (fish_opt --short=a --long=addressbook --required-val)
    argparse $options -- $argv
    or return 1

    if set -q _flag_help
        echo "khard-status [-h|--help] [-a|--addressbook NAME]"
        echo -e "\t-a | --addressbook => Address book to inspect. Defaults to 'work'"
        echo
        echo -e "\tEach contact is one age-encrypted file named after its uid, so"
        echo -e "\ta plain 'chezmoi status' or 'git status' names them by uid and"
        echo -e "\tnothing else -- there is no way to tell a contact worth keeping"
        echo -e "\tfrom one that was deleted on purpose. This decrypts each card"
        echo -e "\tand reports it by name."
        return 0
    end

    for cmd in chezmoi khard
        if not command -q $cmd
            echo "khard-status: $cmd is not installed" >&2
            return 1
        end
    end

    set -l abook work
    if set -q _flag_addressbook
        set abook $_flag_addressbook
    end

    set -l dir "$HOME/.config/khard/$abook/default"
    if not test -d $dir
        echo "khard-status: no address book at $dir" >&2
        return 1
    end

    set -l tracked (chezmoi managed --path-style=absolute $dir | string match --regex '.*\.vcf$')
    set -l present $dir/*.vcf

    set -l untracked
    for file in $present
        contains -- $file $tracked; or set -a untracked $file
    end

    set -l missing
    for target in $tracked
        test -e $target; or set -a missing $target
    end

    # chezmoi status prints two status columns, a space, then the path. M in
    # either column means the card on this machine and the card in the source
    # are not the same file. --groups-only is what returns the path: a regex
    # match without it yields the matched part alone, which here is the status
    # columns and nothing else.
    set -l edited (chezmoi status --path-style=absolute $dir \
        | string match --regex --groups-only '^(?:.M|M.) (.*)$')

    set -l clean 1

    if test (count $untracked) -gt 0
        set clean 0
        echo
        set_color --bold yellow
        echo "==> on this machine, not in the source ("(count $untracked)")"
        set_color normal
        echo "    A reinstall creates the machine from the source, so these are the"
        echo "    ones that disappear. 'khard-track' records them."
        for file in $untracked
            printf '      %-40s %s\n' (__khard_name $file) (path basename $file)
        end
    end

    if test (count $missing) -gt 0
        set clean 0
        echo
        set_color --bold yellow
        echo "==> in the source, not on this machine ("(count $missing)")"
        set_color normal
        echo "    Either another machine added them and 'chezmoi apply' will bring"
        echo "    them here, or they were deleted here without 'khard-rm', which"
        echo "    leaves the source entry behind."
        for target in $missing
            printf '      %-40s %s\n' (__khard_source_name $target) (path basename $target)
        end
    end

    if test (count $edited) -gt 0
        set clean 0
        echo
        set_color --bold yellow
        echo "==> edited here since it was recorded ("(count $edited)")"
        set_color normal
        echo "    'khard-track' records the edit."
        for file in $edited
            printf '      %-40s %s\n' (__khard_name $file) (path basename $file)
        end
    end

    if test $clean -eq 1
        set_color green
        echo (count $tracked)" contacts, and this machine and the source agree about all of them."
        set_color normal
    end
end
