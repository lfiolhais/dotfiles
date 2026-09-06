function kcachegrind --description "kcachegrind with a GTK theme, so the Qt app matches the desktop"
    # `env` runs the real binary rather than this function, which would recurse.
    env QT_QPA_PLATFORMTHEME=gtk2 kcachegrind $argv
end

