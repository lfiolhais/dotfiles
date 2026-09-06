function restart-wifi --description "Reload the brcmfmac Wi-Fi driver (Linux) and list the devices after"
    sudo modprobe -r brcmfmac; sudo modprobe brcmfmac
    sleep 2  # the interface takes a moment to reappear after the reload
    sudo nmcli device
end

