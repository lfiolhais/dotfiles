function yt-dlp --description "yt-dlp with parallel fragments, SponsorBlock marks, and mkv output"
    # Absolute path rather than `env`: naming the binary is what stops this
    # function calling itself. Apple Silicon Homebrew prefix.
    /opt/homebrew/bin/yt-dlp -N6 --sponsorblock-mark all,-preview,-sponsor -t mkv $argv
end

