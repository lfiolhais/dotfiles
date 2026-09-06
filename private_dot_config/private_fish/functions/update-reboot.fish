function update-reboot --description "Run update, then reboot immediately if it succeeded"
    # Reboots with no further confirmation, and only when update returned 0.
    update && reboot
end

