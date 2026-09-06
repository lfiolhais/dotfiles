function convert-vp9-to-x264 --description "Re-encode VP9 .mkv files to H.264, skipping anything else"
    for file in $argv
        if not string match -q '*.mkv' -- $file
            echo "Skipping $file: not a .mkv"
            continue
        end

        # rg --quiet prints nothing and answers in its exit status, so it is the
        # condition itself. Capturing its output instead gives the empty string,
        # which is not a test any file can pass.
        if not mediainfo "$file" | rg --quiet VP9
            echo "Skipping $file: no VP9 track. 'ffprobe $file' shows what is in it."
            continue
        end

        set -l out_file (string replace -r '\.mkv$' .mp4 -- $file)
        ffmpeg -i "$file" -c:v h264_nvenc -preset:v p7 -tune:v hq \
            -rc:v vbr -cq:v 32 -b:v 0 -profile:v high "$out_file"
    end
end
