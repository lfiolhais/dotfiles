function unmount-disk --description "Unmount a block device with udisks and power it down: unmount-disk /dev/sdb1"
    # power-off as well as unmount, so the drive is safe to physically remove.
    udisksctl unmount -b $argv && udisksctl power-off -b $argv
end

