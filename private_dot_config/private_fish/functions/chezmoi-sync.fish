function __print_help_chezmoi_sync
    echo "chezmoi-sync [-h|--help] [-n|--dry-run] [-a|--all]"
    echo -e "\t-h | --help     => Print this message"
    echo -e "\t-n | --dry-run  => Report what would change, re-add nothing"
    echo -e "\t-a | --all      => List every untracked file, not the first few per directory"
    echo
    echo -e "\tPulls this machine's configuration back into the chezmoi source"
    echo -e "\tstate and then says what it could not pull, which is the half that"
    echo -e "\tgets forgotten:"
    echo
    echo -e "\t  * a managed file that has been edited in place is re-added;"
    echo -e "\t  * a managed file rendered from a template is left alone --"
    echo -e "\t    chezmoi never overwrites a template -- and named, because"
    echo -e "\t    the edit has to be made in the source by hand;"
    echo -e "\t  * a file sitting beside a tracked one, untracked, is listed --"
    echo -e "\t    that is the one that disappears at the next reinstall, and"
    echo -e "\t    nothing reports it because chezmoi does not know it exists."
    echo
    echo -e "\tNothing is committed. The source directory's git status is printed"
    echo -e "\tlast so the change can be reviewed and committed by hand."
end

function chezmoi-sync --description "Pull this machine's configuration back into the chezmoi source state"
    set -l options (fish_opt --short=h --long=help)
    set options $options (fish_opt --short=n --long=dry-run)
    set options $options (fish_opt --short=a --long=all)
    argparse $options -- $argv
    or return 1

    if set -q _flag_help
        __print_help_chezmoi_sync
        return 0
    end

    if not command -q chezmoi
        echo "chezmoi-sync: chezmoi is not installed" >&2
        return 1
    end

    set -l source (chezmoi source-path)
    or return 1

    # --- 1. managed files edited in place ------------------------------------
    set_color --bold blue
    echo "==> re-adding managed files"
    set_color normal
    if set -q _flag_dry_run
        echo "(dry run: nothing re-added)"
    else
        chezmoi re-add
        or return 1
    end

    # --- 2. what re-add could not take ---------------------------------------
    # chezmoi status prints two status columns, a space, then the target path.
    # A file still marked modified after a re-add is one chezmoi refused to
    # overwrite, which means its source is a template.
    set -l pending (chezmoi status)
    if test (count $pending) -gt 0
        echo
        set_color --bold blue
        echo "==> still different after re-adding"
        set_color normal
        for line in $pending
            set -l target (string sub --start 4 -- $line)
            set -l src (chezmoi source-path "$HOME/$target" 2>/dev/null)
            if string match -q '*.tmpl' -- "$src"
                echo "  $line"
                echo "      template: edit "(string replace "$source/" '' -- $src)
            else
                echo "  $line"
            end
        end
    end

    # --- 3. files sitting beside tracked ones, untracked ---------------------
    # The directories asked about are the ones the source actually keeps files
    # in, not the ones chezmoi reports as managed: ~/.config is managed because
    # things below it are, and everything unmanaged under it is every
    # application's configuration on the machine. Each directory is read one
    # level deep for the same reason.
    set -l managed (chezmoi managed --include=files --path-style=absolute)
    set -l dirs (path dirname -- $managed | path sort -u)

    set -l untracked
    for dir in $dirs
        for file in $dir/* $dir/.*
            test -f $file; or continue
            contains -- $file $managed; or set -a untracked $file
        end
    end
    set untracked (path sort -u $untracked)

    if test (count $untracked) -gt 0
        echo
        set_color --bold blue
        echo "==> inside a managed directory, but not tracked"
        set_color normal
        if set -q _flag_all
            printf '  %s\n' $untracked
        else
            # Grouped by the directory that holds them, because one generated
            # cache can be thousands of files and hide the single config that
            # matters.
            set -l seen
            for entry in $untracked
                set -l dir (path dirname -- $entry)
                if contains -- $dir $seen
                    continue
                end
                set -a seen $dir
                set -l here (string match -r "^"(string escape --style=regex -- $dir)"/[^/]+\$" $untracked)
                echo "  $dir/  ("(count $here)" untracked)"
                printf '    %s\n' $here[1..(math "min 3, "(count $here))]
                if test (count $here) -gt 3
                    echo "    …"
                end
            end
            echo
            echo "  chezmoi-sync --all           list every one"
        end
        echo "  chezmoi add PATH             track one"
        echo "  chezmoi add --encrypt PATH   track one that holds a secret"
    end

    # --- 4. what to review ---------------------------------------------------
    echo
    set_color --bold blue
    echo "==> $source"
    set_color normal
    git -C $source status --short
    echo
    echo "Review with 'chezmoi diff', then commit in $source."
end
