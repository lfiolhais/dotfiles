function mount-disk --description "Mount a block device with udisks (Linux): mount-disk /dev/sdb1"
    udisksctl mount -b $argv
end

