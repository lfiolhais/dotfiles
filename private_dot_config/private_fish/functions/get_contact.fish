function get_contact
    set -l data (khard email -a work --parsable --remove-first-line $argv[1] | fzf | string split \t)
    echo "$data[2] <$data[1]>"
end

