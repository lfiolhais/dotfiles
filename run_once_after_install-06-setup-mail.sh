#!/usr/bin/env bash
echo "Follow these instructions to setup email."
echo
echo
echo "Update Keychain with IMAP and SMTP passwords:"
echo
echo "mbsync:"
echo "* security add-internet-password -r imap -s Host -a User -w password -T /opt/homebrew/bin/mbsync"
echo "msmtp:"
echo "* security add-internet-password -r smtp -s Host -a User -w password -T /opt/homebrew/bin/msmtp"
echo
echo
echo "Export Proton Mail Bridge SSL Certificates"
echo "Open ProtonMail Bridge"
echo "Settings->Advanced->Export TLS Certificates"
echo "Store them in ~/.config"
echo
echo
echo "After setting up all passwords. Run: mbsync -a && notmuch new"
