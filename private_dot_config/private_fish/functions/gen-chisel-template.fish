function __print_help_gen_chisel_template
    echo "gen-chisel-template [-h|--help] [-n|--name]"
    echo -e "\t-h | --help => Prints this message"
    echo -e "\t-n | --name => Name of the folder which holds the repo. Must be provided"
end

function gen-chisel-template
    if test (count $argv) -eq 0
        __print_help_gen_chisel_template
        return
    end

    set -l options (fish_opt --short=h --long=help)
    set options $options (fish_opt --short=n --long=name --required-val)
    argparse $options -- $argv
    or return

    if test -n "$_flag_help"
        __print_help_gen_chisel_template
        return
    end

    set -l proper_name (string replace -a ' ' '-' $_flag_name)

    git clone https://github.com/freechipsproject/chisel-template "$proper_name"
    cd "$proper_name"
    or return

    set_color green
    echo "Removing previous git repo"
    set_color normal
    rm -rf .git
    rm -rf .github/

    set_color green
    echo "Update build.sbt (Scala version, Project Version, Name, Chisel Version)"
    set_color normal
    sed -r -i "s/%NAME%/$proper_name/" build.sbt
    sed -r -i "s/%ORGANIZATION%/$proper_name" build.sbt

    set_color green
    echo "Remove template specific files"
    set_color normal
    rm -r src/main/scala/gcd src/test/scala/gcd build.sc
    rm -rf LICENSE README.md

    set_color green
    echo "Creating new git directory"
    set_color normal
    git init
    echo -e ".bloop/\n.metals/\nproject/metals.sbt\n" >> .gitignore
end

