function reboot-keyboard --description "Reapply the X11 keymap and repeat rate, and restart ibus"
    xmodmap $HOME/.Xmodmap
    xset r rate 300 60
    ibus restart
end

