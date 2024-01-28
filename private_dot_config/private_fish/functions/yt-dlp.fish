function yt-dlp
    # /usr/bin/yt-dlp -N6 -f 'bestvideo*+bestaudio/best' --merge-output-format mp4 --recode-video mp4 --postprocessor-args "VideoConvertor: -c:v h264_nvenc -preset:v p7 -tune:v hq -rc:v vbr -cq:v 32 -b:v 0 -profile:v" $argv
    /opt/homebrew/bin/yt-dlp -N6 -f 'bestvideo*+bestaudio/best' --merge-output-format mkv $argv
end

