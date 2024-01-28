function convert-vp9-to-x264
    for file in $argv
        if test (string match -r '\.mkv' "$file") -a (mediainfo "$file" | rg --quiet "VP9")
            set out_file (basename "$file" .mkv)".mp4"
            ffmpeg -i $file -c:v h264_nvenc -preset:v p7 -tune:v hq -rc:v vbr -cq:v 32 -b:v 0 -profile:v high "$out_file"
        else
            echo "Skipping $file..."
            echo "This may be a VP9 container that we are ignoring but with a different extension"
            echo "Recheck"
        end
    end
end

