function tmux-continuum --on-event fish_postexec
    if test -n "$TMUX"
        if test (uname -o) = "Darwin"
            $HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh
        end
    end
end

