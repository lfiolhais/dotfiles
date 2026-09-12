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
