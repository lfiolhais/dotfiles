function fish_greeting
    echo "Where the hell is science?!"
    echo
    echo -e (uname -ro | awk '{print " \\\\e[1mOS: \\\\e[0;32m"$0"\\\\e[0m"}')
    echo -e (uptime | sed -E 's/^[^,]*up *//; s/mins/minutes/; s/hrs?/hours/;
  s/([[:digit:]]+):0?([[:digit:]]+)/\1 hours, \2 minutes/;
  s/^1 hours/1 hour/; s/ 1 hours/ 1 hour/;
  s/min,/minutes,/; s/ 0 minutes,/ less than a minute,/; s/ 1 minutes/ 1 minute/;
  s/  / /; s/, *[[:digit:]]* users?.*//' | awk '{print " \\\\e[1mUptime: \\\\e[0;32m"$0"\\\\e[0m"}')
    echo -e " \\e[1mDisk usage:\\e[0m"
    echo
    echo -ne (\
    	df -l -h | grep -e 'dev/(xvda|sd|mapper|disk)' | \
    	awk '{printf "\\\\t%s\\\\t%4s / %4s  %s\\\\n\n", $6, $3, $2, $5}' | \
    	sed -e 's/^\(.*\([8][5-9]\|[9][0-9]\)%.*\)$/\\\\e[0;31m\1\\\\e[0m/' -e 's/^\(.*\([7][5-9]\|[8][0-4]\)%.*\)$/\\\\e[0;33m\1\\\\e[0m/' | \
    	paste -sd ''\
    )
    echo

    set_color normal
end
