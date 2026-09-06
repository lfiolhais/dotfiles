function __greet_field --description "One bold label with a green value after it"
    set_color --bold
    echo -n " $argv[1]: "
    set_color green
    echo $argv[2..]
    set_color normal
end

function __greet_uptime --description "How long the machine has been up, in words"
    # `uptime` prints the time of day, how long the machine has been up, how
    # many users are logged in and the load averages, in that order on both
    # macOS and Linux. " up " starts the part that is wanted and the user count
    # ends it.
    set -l line (uptime | string replace -r '^.*? up +' '')
    set line (string replace -r ',?\s+\d+\s+users?.*$' '' -- $line)
    # What is left reads as words except for "4:12", which is hours:minutes.
    set line (string replace -r '(\d+):0?(\d+)' '$1 hours, $2 minutes' -- $line)
    set line (string replace -ra '\bmins?\b' minutes -- $line)
    set line (string replace -ra '\b1 (hour|minute|day)s\b' '1 $1' -- $line)
    string trim (string replace -ra '\s+' ' ' -- $line)
end

function __greet_disks --description "Where each local disk is mounted and how full it is"
    # -P forces df's POSIX six-column layout, which macOS and Linux print
    # identically. Without it macOS inserts four inode columns before the
    # mountpoint, and reading a fixed field number gives the inode count
    # instead. -l leaves out network mounts, which are the NAS.
    df -P -l -h | while read -l device size used avail capacity mount
        # A device under /dev is a real disk: /dev/disk on macOS, /dev/sd,
        # /dev/nvme, /dev/mapper and /dev/xvd on Linux. Everything else is
        # devfs, tmpfs, an overlay or the automounter's map entries, and the
        # header line goes the same way.
        string match -q '/dev/*' -- $device; or continue

        # macOS mounts several volumes of one APFS container. The user's data
        # is on / and /System/Volumes/Data; the rest are housekeeping volumes
        # of a few hundred megabytes that say nothing about a full disk.
        switch $mount
            case '/System/Volumes/Preboot' '/System/Volumes/VM' \
                '/System/Volumes/Update*' '/System/Volumes/xarts' \
                '/System/Volumes/iSCPreboot' '/System/Volumes/Hardware' \
                '/Volumes/Recovery'
                continue
        end

        # df reports capacity as a percentage; a volume that reports something
        # else is printed uncoloured rather than skipped.
        set -l percent (string replace % '' -- $capacity)
        set -l colour normal
        if string match -qr '^\d+$' -- $percent
            if test $percent -ge 85
                set colour red
            else if test $percent -ge 75
                set colour yellow
            end
        end

        set_color $colour
        printf '\t%-22s %5s / %-5s  %4s\n' $mount $used $size $capacity
        set_color normal
    end
end

function fish_greeting
    echo "Where the hell is science?!"
    echo
    __greet_field OS (uname -sr)
    __greet_field Uptime (__greet_uptime)
    echo
    set_color --bold
    echo " Disk usage:"
    set_color normal
    __greet_disks
    echo
end
