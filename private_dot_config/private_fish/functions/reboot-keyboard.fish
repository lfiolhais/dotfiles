function reboot-keyboard
    xmodmap $HOME/.Xmodmap
    xset r rate 300 60
    ibus restart
end

