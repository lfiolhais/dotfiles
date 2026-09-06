function get_contact --description "Pick a khard contact with fzf and print it as Name <address>"
    # Only the first argument is used as a search term; the rest are ignored.
    set -l data (khard email -a work --parsable --remove-first-line $argv[1] | fzf | string split \t)
    echo "$data[2] <$data[1]>"
end

