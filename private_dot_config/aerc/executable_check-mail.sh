#!/usr/bin/env bash
exec >>~/.local/state/aerc/sync.log 2>&1
echo "=== $(date -Is)"
for ch in pm ist icloud; do
	mbsync "$ch" || echo "!! channel $ch failed (rc=$?)"
done
notmuch new
