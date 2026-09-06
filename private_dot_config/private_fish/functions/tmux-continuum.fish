function tmux-continuum --on-event fish_postexec --description "Refresh tmux-continuum's save timer after every command inside tmux"
    if test -n "$TMUX"
        if test (uname -o) = "Darwin"
            $HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh
        end
    end
end

