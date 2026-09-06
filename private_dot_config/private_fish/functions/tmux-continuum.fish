function tmux-continuum --on-event fish_postexec --description "On macOS, refresh tmux-continuum's save timer after every command inside tmux"
    # This runs after every command, so each guard has to be cheap and each has
    # to be there: outside tmux there is nothing to save, and the plugin is
    # installed by tmux rather than by this repository, so without the -x test a
    # machine that does not have it reports a missing file after every command.
    set -l save "$HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh"
    if test -n "$TMUX" -a (uname -s) = Darwin -a -x "$save"
        $save
    end
end
