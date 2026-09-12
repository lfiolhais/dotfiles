---
name: pihole-dns-ops
description: Operational rules for changing DNS on a Pi-hole v5 or v6 host — records, DHCP, upstreams, reservations. Use before editing pihole.toml, setupVars.conf, /etc/dnsmasq.d, or anything that changes what a resolver answers. Covers the failure modes that silently break name resolution for a whole network.
---

# Pi-hole DNS operations

A Pi-hole usually serves DNS **and** DHCP for every device on its network, so a
mistake here is not a service outage, it is a house outage — and it takes out
the tooling used to diagnose it, because the box typically resolves
through itself.

Assume every change is high-blast-radius. Verify from a client, not the Pi.

## Never template `pihole.toml` (v6)

FTL **rewrites `/etc/pihole/pihole.toml` when it starts.** Edits made while it
is running are silently lost, and a syntax error there stops FTL from starting
at all — leaving the network with no DNS and no DHCP.

Always go through the CLI, which is transactional and validated:

```bash
sudo pihole-FTL --config <key>              # read
sudo pihole-FTL --config <key> <value>      # write
sudo pihole-FTL --config                    # dump everything
```

This includes DHCP ranges and static reservations (`dhcp.hosts`), not just DNS.

On **v5** the equivalent file is `/etc/pihole/setupVars.conf`, read at install
and by `pihole -r`. Custom records live in `/etc/pihole/custom.list`.

## `misc.etc_dnsmasq_d` must be true (v6)

```bash
sudo pihole-FTL --config misc.etc_dnsmasq_d true
```

If it is false, Pi-hole ignores `/etc/dnsmasq.d/` **entirely** and every local
name stops resolving at once, with no error anywhere. This is the single most
likely cause of "all my service names broke simultaneously".

## Never use a wildcard record

```
address=/example.com/192.168.1.10      # WRONG — also captures the apex
```

dnsmasq ignores leading dots and there is no "subdomains only" syntax, so this
also answers for `example.com` itself and breaks the real public domain from
inside the LAN. Write one explicit record per name.

The same trap applies to `dns.domain` / `PIHOLE_DOMAIN`: setting it to the
real domain makes the whole zone local-only and never forwarded upstream.

## An empty apex answer is often correct

If the domain has no A record at the registrar, `dig example.com` correctly
returns `NOERROR` with an empty answer. Do **not** write a health check that
asserts a non-empty result — it will fail forever for the wrong reason.

Assert the useful invariant instead: the apex must not resolve to a *private*
address, which is the signature of a wildcard having swallowed it.

## Changing records safely

1. Render the whole file, never append. Removal is the hard case, and
   whole-file rendering makes deleting a record work the same as adding one.
2. Make sure only one file defines a given name. A leftover hand-written file
   beside a generated one means every name is defined twice.
3. FTL only reads `/etc/dnsmasq.d/` at startup, so a restart is unavoidable —
   which is precisely why the verification below is mandatory.
4. v6 has a real offline syntax check: `pihole-FTL dnsmasq-test-file <file>`
   returns rc=0 and `syntax check OK` on a good file, rc=1 and
   `dnsmasq: bad option at line N` on a bad one, without touching the running
   config. Use it as a pre-write validator. v5 has no per-file equivalent — its
   `dnsmasq-test` checks the whole installed config and cannot be pointed at a
   temporary file — so on v5 the only check is a live query after the restart.

## Querying FTL's telnet API without hanging

v5 exposes counters on `127.0.0.1:4711`. `domains_being_blocked` is the single
most useful number on a sick resolver: a negative value means FTL cannot read
its gravity database and is **dropping every query** while its sockets stay
bound, a state no port check reveals.

FTL keeps the session open after a command, and `nc.openbsd` does not exit when
its stdin reaches EOF — it waits for the server to hang up. So the obvious form
never returns:

```bash
(echo ">stats"; sleep 2) | nc 127.0.0.1 4711     # blocks forever
(echo ">stats"; echo ">quit") | timeout 10 nc 127.0.0.1 4711    # 0.05s
```

Send `>quit`, and wrap it in `timeout` anyway so a genuinely wedged FTL fails
the command instead of stalling whatever is running it.

When testing the value, treat an **empty** answer as a failure. `'' | int` is
`0` in both shell and Jinja, which is not negative — so a check written only as
"is the number below zero" reports "FTL never replied" as healthy, which is
precisely the fault it exists to catch.

## Never leave backups in `/etc/dnsmasq.d`

dnsmasq reads *every* file in that directory. It skips names ending in `~`, so
an editor or an Ansible `backup: true` appears to do no harm — but that is
dnsmasq's filter doing the work rather than a decision anyone made, and the
next tool that writes `.conf.bak` or `.orig` double-defines every record in it.

Render the file whole from source control and keep backups outside the
directory. Where a rollback genuinely needs the previous copy — v5 has no
per-file validator, so the only way to test a file is to install it — delete
the backup again as soon as the syntax check passes.

## v6 can validate a file offline; v5 cannot

```bash
pihole-FTL dnsmasq-test-file <file>   # v6: rc=1 + "bad option at line N", rc=0 + "syntax check OK"
pihole-FTL dnsmasq-test               # v5: whole installed config, takes no filename
```

On v6 this is a genuine pre-write check — use it as a `validate:` so a broken
render never lands. On v5 there is no equivalent: install, then test, then roll
back on failure. Note `dnsmasq-test` writes its result to **stderr**, so a
check that greps stdout alone fails a perfectly valid config.

## The query database does not shrink on its own

`MAXDBDAYS` (v5) and `database.maxDBdays` (v6) bound how much history FTL
*keeps*, not the file size — SQLite leaves freed pages in place. On an SD card
that matters:

```bash
sudo systemctl stop pihole-FTL
sudo sqlite3 /etc/pihole/pihole-FTL.db 'VACUUM;'
sudo chown pihole:pihole /etc/pihole/pihole-FTL.db   # sqlite3 ran as root
sudo systemctl start pihole-FTL
```

The `chown` is not optional; without it FTL cannot write to its own database.
This stops the resolver for the duration — seconds to a minute — so do it
deliberately, and check the other resolver is healthy first.

## Verify from a client, not the Pi

The Pi resolves through `127.0.0.1`, so testing there skips the DHCP path,
the network path and the rebind-protection path that clients actually use.

```bash
dig +short service.example.com          # expected IP, from a laptop
dig +short @<pihole-ip> service.example.com
dig +short example.com                  # must NOT be a private address
```

Symptoms worth recognising:

| Symptom | Cause |
|---|---|
| every local name fails at once | `misc.etc_dnsmasq_d` false, or FTL down |
| names fail on the Pi only | its own resolver config reverted |
| `dig @pihole` works, clients fail | router DNS rebind protection |
| a name resolves to the wrong host | duplicate record in another file, or a stale `dns.hosts` entry shadowing it |
| intermittent failures across the LAN | a **secondary** resolver advertised via DHCP that is not answering |

That last one is easy to miss: DHCP hands out an ordered resolver list, and a
dead secondary produces failures that look random and unreproducible. Verify
every advertised resolver individually, not just the primary.

## Host self-resolution

A Pi-hole host that resolves through itself loses its own name resolution when
FTL dies — including `apt`. Emergency override, which does not survive a
reboot:

```bash
echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf
```

Do not "fix" this permanently by editing `/etc/resolv.conf`: it is generated by
resolvconf/dhcpcd/NetworkManager and is rewritten on the next lease. Change the
generator (`/etc/dhcpcd.conf`, or the NetworkManager connection).

**A monitoring host should not resolve through the resolver it monitors** — it
goes blind exactly when it is needed.

## Restart discipline

`systemctl restart pihole-FTL` drops DNS and DHCP for every device for a few
seconds. `systemctl restart dhcpcd` drops the interface entirely. Neither
should ever fire automatically from a config-management run without an explicit
opt-in.
