function yt-dlp --description "yt-dlp with parallel fragments, SponsorBlock marks, and mkv output"
    # `command` runs the binary rather than this function, which would recurse.
    command yt-dlp -N6 --sponsorblock-mark all,-preview,-sponsor -t mkv $argv
end
