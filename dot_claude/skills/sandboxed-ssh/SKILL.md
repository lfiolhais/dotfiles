---
name: sandboxed-ssh
description: Reach SSH hosts (LAN servers, Raspberry Pis, remote boxes) from inside the Claude Code sandbox when plain ssh fails with "Operation not permitted", hostnames will not resolve, or ssh has no identity. Use whenever ssh, scp, rsync, dig, or curl to a private host is blocked by the sandbox.
---

# SSH from inside the sandbox

The sandbox denies raw sockets, so `ssh` fails before doing anything useful.
There are three independent gates producing different errors. Work out which
one you are hitting before changing any settings.

## Symptom → gate

| Symptom | Gate |
|---|---|
| `ssh: connect ... Operation not permitted` | no raw sockets; must go via the proxy |
| `Could not resolve hostname` / `dig: isc_socket_bind` | DNS blocked too; the proxy must resolve the name |
| `Received disconnect ... proxy requires authentication` | SOCKS5 needs RFC 1929 auth; `nc` cannot do it |
| `Permission denied (publickey)` | no identity: `~/.ssh` unreadable, agent socket blocked |

## 1. Route through the sandbox SOCKS5 proxy

Credentials live in `$ALL_PROXY`:

```
ALL_PROXY=http://srt.<user>:<pass>@localhost:52416
```

**The port is re-allocated on every tool call.** Never hardcode it and never
reuse one from an earlier command — read it from the environment each time.

macOS `nc -X 5 -x host:port` has **no flag for SOCKS5 username/password**, so
it is refused with `policy_refusal`. Use the bundled `socks-proxy.py` as a
`ProxyCommand`; it reads `$ALL_PROXY` itself:

```bash
ssh -o "ProxyCommand=python3 ~/.claude/skills/sandboxed-ssh/socks-proxy.py %h %p" \
    -o BatchMode=yes user@host.example.com
```

Connect by **hostname, not IP**: the proxy resolves the name remotely, the
sandbox cannot resolve it locally, and `no_proxy` usually covers RFC1918
ranges — so an IP may bypass the proxy and fail.

## 2. Get an identity without reading key files

`~/.ssh` is normally read-denied so ssh loads no key, and the ssh-agent socket
is blocked. Allow **only the agent socket** — the agent does the signing and no
private key is ever read:

```jsonc
// .claude/settings.local.json
{ "sandbox": { "network": {
    "allowUnixSockets": ["/var/run/com.apple.launchd.XXXXXXXX/Listeners"] } } }
```

The value is the current `$SSH_AUTH_SOCK`, which **rotates on every reboot**.
Confirm the agent actually holds a key with `ssh-add -l` before blaming it.

`known_hosts` is unreadable too, so add
`-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no` or every
connection warns.

## 3. Allow the destination host

```jsonc
{ "sandbox": { "network": { "allowedDomains": ["host.example.com"] } } }
```

The settings key is `allowedDomains`; it appears as `allowedHosts` in the
sandbox description shown in the system prompt.

## Working invocation

```bash
SSHOPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o LogLevel=ERROR
         -o ProxyCommand=python3 ~/.claude/skills/sandboxed-ssh/socks-proxy.py %h %p"
ssh $SSHOPTS user@host 'uname -a'
scp $SSHOPTS ./file user@host:/tmp/
rsync -e "ssh $SSHOPTS" -a ./dir user@host:/tmp/
```

## Gotchas

- **The remote login shell may not be bash.** With fish, `for` loops and
  heredocs break. Pipe a script instead:
  `ssh ... 'bash -s' <<'EOF' … EOF`
- **Filter SSH banner noise** when parsing output:
  `| grep -v 'post-quantum\|openssh.com/pq'`
- **Ansible** needs the same ProxyCommand plus writable temp dirs:
  ```bash
  export ANSIBLE_LOCAL_TEMP="$TMPDIR/ans/tmp" ANSIBLE_HOME="$TMPDIR/ans/home"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_ARGS="-o ControlMaster=no -o ControlPath=none \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ProxyCommand='python3 ~/.claude/skills/sandboxed-ssh/socks-proxy.py %h %p'"
  ```
  `ansible-core` 2.21+ also starts a local RPC server over a unix socket, which
  the sandbox may block outright (`TimeoutError: Local RPC server did not
  start`). If that happens you cannot run playbooks from inside the sandbox at
  all: validate templates offline (render them with Jinja2 directly) and have
  the user run the playbook themselves.
- **Use `$TMPDIR`, not `/tmp`.** `~/.ansible`, `~/.cache` and friends are
  usually write-denied.
- Prefer read-only commands, and when something must model a change use the
  tool's own dry run: `apt-get -s`, `rsync --dry-run`, `--check`.
