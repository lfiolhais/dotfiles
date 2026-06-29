function unmount-disk
    udisksctl unmount -b $argv && udisksctl power-off -b $argv
end

