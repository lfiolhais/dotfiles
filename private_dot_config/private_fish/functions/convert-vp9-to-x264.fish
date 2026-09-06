function convert-vp9-to-x264 --description "Re-encode VP9 .mkv files to H.264, skipping anything else"
    for file in $argv
        if test (string match -r '\.mkv' "$file") -a (mediainfo "$file" | rg --quiet "VP9")
            set out_file (basename "$file" .mkv)".mp4"
            ffmpeg -i $file -c:v h264_nvenc -preset:v p7 -tune:v hq -rc:v vbr -cq:v 32 -b:v 0 -profile:v high "$out_file"
        else
            echo "Skipping $file..."
            echo "Skipped: not detected as VP9. Check the container with: ffprobe $file"
            echo "Recheck"
        end
    end
end

