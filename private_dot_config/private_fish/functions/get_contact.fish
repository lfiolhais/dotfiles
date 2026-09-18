function get_contact --description "Pick a khard contact with fzf and print it as Name <address>"
    for cmd in khard fzf
        if not command -q $cmd
            echo "get_contact: $cmd is not installed" >&2
            return 1
        end
    end

    # Only the first argument is used as a search term; the rest are ignored.
    set -l data (khard email -a work --parsable --remove-first-line $argv[1] | fzf | string split \t)

    # ESC in fzf leaves $data empty, and printing ' <>' would hand a malformed
    # address to whatever consumes this -- a mail compose picker, usually.
    if test -z "$data[1]"
        return 1
    end

    echo "$data[2] <$data[1]>"
end
