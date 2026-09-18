function fish_user_key_bindings --description "Key bindings fish loads at startup: fzf's Ctrl-T/Ctrl-R/Alt-C"
  # config.fish defines fzf_key_bindings only where fzf is installed and new
  # enough for `fzf --fish`; without it there are no bindings to add.
  functions --query fzf_key_bindings; and fzf_key_bindings
end
