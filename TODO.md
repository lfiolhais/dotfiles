# TODO

Defects awaiting approval. Each item below carries its own remedy, or says why none is
settled yet.

## Name the deployed Python that no check reads

`check_coverage` fails on `dot_claude/skills/sandboxed-ssh/executable_socks-proxy.py`:
"deployed python3 that no check reads". It has been tracked since `3d4cb47`, the
baseline commit, and `tests/check.py` has never named it, so the harness has reported
this on every host that runs it. It is unrelated to `docket`.

Either it is a deployed command, or it is not and it moves out of a directory that
deploys.

If it is, the list to name it in is `DEPLOYED_ENTRY_POINTS`, which `DEPLOYED_PYTHON` is
built from along with the `dot_local/lib/python` glob — `DEPLOYED_PYTHON` itself is
derived and cannot be added to. Naming it there puts it under ruff and runs it under
every `python3` on the host, which means it also has to pass the 3.9 floor and the ruff
configuration in `tests/pyproject.toml`. Note that `DEPLOYED_ENTRY_POINTS` holds only
`dot_local/bin` commands today, so this would be the first entry from anywhere else.
