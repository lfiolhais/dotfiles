# Backlog

Each item changes behaviour, so it is a decision rather than a correction.
Nothing here has been applied. Nothing here has been tested on a live machine.

## The NAS

### The share stops mounting whenever a negative DNS answer is cached

`dot_local/lib/python/mountnas.py`

Both Pi-holes answer `nas.botasal.xyz` authoritatively with `192.168.1.78` and a
TTL of 0. `botasal.xyz` is delegated publicly to Porkbun, and that zone has no
`nas` in it, so any query made while the Pi-holes are not the resolvers is
answered NXDOMAIN and macOS caches it.

The cached answer outlives the network change that brings the laptop home.
`Share.reachable()` calls `getaddrinfo`, which reads that cache rather than the
LAN resolvers, so it raises `socket.gaierror`; `sync()` records `AWAY` and
mounts nothing, silently, which is what the command is built to do when the NAS
is genuinely absent. `dig` answers correctly the whole time, because it queries
192.168.1.78 directly and never reads the cache, so every check short of
`getaddrinfo` says DNS is healthy.

How long macOS holds the entry is set by the negative-caching TTL in Porkbun's
SOA and has not been measured. What is established is that it survived the
return to the LAN, and that flushing the cache resolved the name at once:

```sh
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

The local record is not hand-maintained: an Ansible playbook renders
`/etc/dnsmasq.d/99-ansible-services.conf` on both resolvers from a service
registry, and the `nas` entry there carries `proxy: false`, which points the
name at delta7's own address. Editing Pi-hole directly is overwritten by the
next play, so any change to this record is made in that registry.

Closing it means the name resolving from both views, which is an A record for
`nas.botasal.xyz` pointing at `192.168.1.78` in the public zone at Porkbun. Away
from home the name then resolves to an address nothing answers on, the
connection to port 445 fails, and `sync()` records `AWAY` for the reason it is
meant to, with no negative answer ever cached. The cost is that the NAS's
address on the home network is published in public DNS.

The alternative is to keep the record local and flush the cache on the days it
happens, now that `mount-nas status` names the cause.

## Packages

### anylinuxfs is uninstalled, and the tap may be sound

`private_dot_config/Brewfile`, `.chezmoidata/packages.toml`

`anylinuxfs` came from the `nohajc/anylinuxfs` tap and `anylinuxfs-gui` from
`fenio/tap`. Both entries and both taps are already dropped, so the bundle
completes. Whether they come back is the open part.

`brew` on this machine fails intermittently, and the failure is in writing its
own API cache, not in reading a remote:

```
curl: (56) Failure writing output to destination, passed 2370 returned 4294967295
HTTP status: 200
```

The HTTP status is 200, so the request itself succeeded, and the destination it
could not write to is a path under `$(brew --cache)`, not a URL. That is a local
cache fault, and a tap fetch failing the same way looks like the tap being
unavailable. If that is what happened, the tap is fine and the cache is not:

```sh
rm -rf "$(brew --cache)/api"
brew update --force
brew doctor
```

Then `chezmoi-packages add anylinuxfs` puts it back if it installs. If it fails
the same way with a clean cache, the tap really is gone and the entries stay
out. Nothing in this repository names anylinuxfs, so leaving it out costs no
documentation — only the ability to mount a Linux filesystem on this Mac.

### MakeMKV is installed by hand or not at all

`private_dot_config/Brewfile`

Homebrew disabled the `makemkv` cask on 2026-09-01 — it no longer passes the
macOS Gatekeeper check — and a disabled cask installs nowhere, so `brew bundle`
exits non-zero on it and `run_once_after_install-01-install-packages-darwin.sh.tmpl`
fails with it. The entry is out of the Brewfile, which is what lets the bundle
finish; the app it installed is still on this Mac and is now declared nowhere.

`brew bundle dump` writes back whatever is installed, so `chezmoi-packages dump`
puts `cask "makemkv"` back and `check.py` fails on it again. Uninstalling the
cask here is what stops that, and it takes MakeMKV.app with it:

```sh
brew uninstall --cask makemkv
```

To have the repository install MakeMKV again, three routes, each hand-maintained
because the disable is permanent:

- A `run_onchange_` script that fetches the current DMG from
  `https://www.makemkv.com/download/` (`MakeMKV_v<version>_macos.dmg`), mounts
  it, copies `MakeMKV.app` to `/Applications`, and detaches it. The version is in
  the URL, so the script carries it and is bumped by hand. First launch needs
  approval under System Settings → Privacy & Security — the Gatekeeper failure
  that got the cask disabled is the one a user meets here.
- `brew install --cask` against the cask file from the commit before the disable,
  e.g. `brew install --cask
  https://raw.githubusercontent.com/Homebrew/homebrew-cask/<sha>/Casks/m/makemkv.rb`.
  Re-pin the sha whenever the vendor moves the download and the old URL 404s.
- Install it by hand when a disc needs ripping and leave the repository out of
  it, the same call already made for anylinuxfs.

The beta key MakeMKV needs while it is in beta rotates about monthly and is
posted on their forum; none of these routes tracks it.
