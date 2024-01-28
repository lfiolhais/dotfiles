function restart-wifi
    sudo modprobe -r brcmfmac; sudo modprobe brcmfmac
    sleep 2
    sudo nmcli device
end

