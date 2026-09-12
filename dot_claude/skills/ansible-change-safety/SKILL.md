---
name: ansible-change-safety
description: Ansible failure modes that pass silently — tasks that report ok while doing nothing, check-mode results that mean the opposite of what they appear to, config keys ignored without warning, and edits to sudoers, sshd or accounts that remove access. Use when writing or reviewing roles that touch privileged config, when a play reports success but the host did not change, or when --check disagrees with a real run.
---

# Ansible changes that fail quietly

Ansible is loud about syntax and silent about semantics. Each item below
reports success, or reports a change, while doing nothing or doing the wrong
thing. All were observed in practice.

## `failed_when` replaces the return-code check

It does not add to it. A task carrying `failed_when` no longer fails on a
non-zero exit status unless the expression says so.

```yaml
# Wrong: an unreachable host, a refused key or a DNS failure all write to
# stderr and leave stdout empty, so this reports success.
failed_when: result.stdout | trim | length > 0

# Right
failed_when: result.rc != 0 or (result.stdout | trim | length > 0)
```

The consequence is worst on verification tasks, because whatever "passed" is
then used to authorise something destructive. A backup verification written the
first way will licence deleting the only copy of data it never checked.

## In check mode, `command` and `shell` are skipped rather than simulated

They return `rc: 0`, `stdout: ""` and `skipped: true`, and `failed_when` is
never evaluated on a skipped task. A dry run of a role whose checks are
`command` tasks therefore proves nothing while appearing clean.

Read-only commands should carry `check_mode: false` so the dry run still
reports something:

```yaml
- name: Read the current value
  ansible.builtin.command: some-tool --get thing
  register: current
  changed_when: false
  check_mode: false        # safe: it only reads
```

Tasks that write must not carry it, so a role mixing both shows gaps in
`--check` output. That is correct behaviour and worth a comment, or someone
will later "fix" it.

## Check mode makes some tasks fail that would succeed for real

Any task acting on a resource an earlier task only pretended to create:

```
systemd_service: Could not find the requested service foo.timer
```

because the unit file was never written. The guard should test the pretence
rather than check mode alone, so the task is still exercised once the file
exists:

```yaml
when: not (ansible_check_mode and (unit_file.changed or timer_file.changed))
```

Left unguarded this fails the host, which drops it from every later play, so a
single cosmetic check-mode failure can make `--check` useless for an entire
run.

Handlers are the easy place to miss this, because the guard belongs on a task
that did not notify them. `community.docker.docker_compose_v2` reads
`project_src`, and a dry run has not created that directory, so the handler
fails with

```
"/opt/portainer" is not a directory
```

on a host where the role has never been applied — and takes every later play
with it. The fix is the same shape, with the directory task registered so the
handler can tell a real directory from a pretended one:

```yaml
- name: recreate the stack
  community.docker.docker_compose_v2:
    project_src: "{{ stack_dir }}"
    state: present
  when: not (ansible_check_mode and stack_dir_created.changed)
```

## Unrecognised keys in `ansible.cfg` are ignored without warning

A misspelled or misplaced key is not an error. Two variants:

- Wrong name. `result_format` does nothing; the ini key is
  `callback_result_format`. Callback options do not appear in
  `ansible-config dump --only-changed`, so verification needs
  `ansible-config dump --type callback | grep <key>`.
- Wrong section. `vault_password_file` is a `[defaults]` key. Appending it to
  the end of the file — what `>> ansible.cfg` does — usually lands it under
  `[privilege_escalation]`, where it is silently dropped. The symptom is
  `Attempting to decrypt but no vault secrets found`, which points at the vault
  rather than at the configuration.

Any setting being relied on is worth confirming with
`ansible-config dump --only-changed`, which prints the file each value came
from.

## Role-level tags propagate to every task in the role

A tag applied to a role in the playbook applies to all of its tasks. If one
task in a role is client-visible or destructive, tagging cannot isolate it; it
needs its own role and its own play, tagged `never`:

```yaml
- name: Thing that changes every client
  hosts: some_group
  roles:
    - role: dangerous_thing
      tags: [dangerous-thing, never]
```

The isolation is worth verifying rather than assuming, for each supported tag
and for no tags at all:

```bash
ansible-playbook site.yml --list-tasks
ansible-playbook site.yml --list-tasks --tags some-tag
```

`--list-tasks` does not print tasks inside `rescue:` or `always:`. Their
absence from that output is not evidence they were dropped; parsing the YAML is
the way to be certain.

## Verification belongs in `always:`, not at the end of the task list

A flat role runs its safety checks only if everything before them succeeded, so
an interrupted or failing run skips precisely the step that would reveal the
host is now broken.

```yaml
- name: Do the destructive work, then prove the host still works
  block:
    - ...            # stop services, purge packages, delete files
  always:
    - ...            # port checks, service checks, a summary
```

`meta: flush_handlers` works inside `always:`, and handlers notified within the
block still fire.

## `validate:` only applies to a whole file

`lineinfile` and `template` run `validate` against a complete temporary copy,
so `validate: /usr/sbin/sshd -t -f %s` is a real guarantee for `sshd_config`.
It is unavailable for a fragment — a drop-in under `sshd_config.d`, or a file
in any `conf-dir` — because the validator cannot parse one in isolation. Those
require writing the file and then validating the assembled configuration in a
separate task, with a path to remove what was just written if it fails.

## `backup: true` writes beside the file

Harmless for a standalone config, dangerous in a directory a daemon scans:
`/etc/dnsmasq.d`, `/etc/sudoers.d`, `sshd_config.d`, any `conf.d`. The backup
becomes a second, stale definition of everything in it. Some daemons skip names
ending in `~`, which conceals the problem until a tool writes `.bak` or `.orig`
instead.

Where a rollback genuinely needs the previous copy, the backup should be
deleted as soon as the new file is known good.

## Edits that remove access

- Filenames in `/etc/sudoers.d` must not contain a dot. sudo ignores
  `nopasswd.conf`, `x.bak`, and anything with an extension: it grants nothing
  and reports nothing. Files must be mode `0440`. `visudo -f <file>` enforces
  both and refuses to save a file that does not parse. `visudo` lives in
  `/usr/sbin`, which is absent from a normal user's `PATH`, so it appears
  uninstalled; it is reachable as `sudo visudo`.
- No variable-driven file list should be able to delete from `/etc/sudoers.d`,
  `/etc/ssh` or a `.ssh` directory. Assert against those paths. Filenames lie
  about what they grant — a file named after a decommissioned service can be
  the only thing giving the login account passwordless sudo.
- `user:` with `append: false` removes every group not listed. Applied to the
  account Ansible connects as, it strips `sudo` mid-run.
- Disabling password authentication needs a precondition: assert that the
  connecting user has a non-empty `authorized_keys` before writing
  `PasswordAuthentication no`, or a host reached by password becomes
  unreachable.
- Deleting a user leaves their files behind, owned by a bare uid. `userdel -r`
  removes the home directory and nothing else. Ownership of anything outside it
  must be reassigned first, or the next account created inherits the uid and
  everything the old one owned.

## sshd specifics

- `Include /etc/ssh/sshd_config.d/*.conf` arrived in OpenSSH 8.2. On older
  releases there is no drop-in directory, and creating one has no effect at
  all — the setting must go in `sshd_config` itself. Detection rather than
  assumption:
  `grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config`
- sshd uses the first value it finds for a keyword. A directive added below an
  existing one is silently ignored, and appending to the end of the file is the
  most common way to do that accidentally. The effective configuration comes
  from `sshd -T`, not from reading the file.
- Reload rather than restart. `reload` re-reads the configuration without
  dropping established connections, so a mistake cannot cut off the session
  applying it.

## apt: rewriting sources does not invalidate the cache

After a mirror change the old repository's lists remain in
`/var/lib/apt/lists`. apt ignores them, since they belong to a repository no
longer configured, but their timestamps make the cache look fresh, so
`cache_valid_time` skips the refresh and the install fails with:

```
No package matching 'foo' is available
```

which reads as a missing package rather than a stale index. A sources change
should force `update_cache`, keyed on the configured mirror having no list
files present rather than only on the rewrite task reporting `changed` —
otherwise recovery depends on catching the single run where that was true.

## Version bounds

- Collections declare their supported `ansible-core` in `meta/runtime.yml`, and
  galaxy installs the newest match by default rather than the newest compatible
  one. An unbounded requirement eventually installs a collection that has
  dropped the pinned core, and the resulting error names a removed plugin
  rather than the version conflict. Upper bounds are mandatory.
- `ansible-core` sets the minimum Python for managed nodes in
  `ansible/module_utils/basic.py` as `_PY_MIN`. It should be read from the
  installed release rather than inferred:
  `python -c "import ansible.module_utils.basic as b; print(b._PY_MIN)"`

## The check that catches most of this

A converged fleet reports `changed=0`:

```bash
ansible-playbook site.yml --check --diff
```

Any task reporting `changed` on a host already in the desired state is a bug,
usually a `command` without `changed_when`, or a task cleaning up scratch files
it created moments earlier. Those are worth fixing, because they train the
reader to ignore the one line that matters.
