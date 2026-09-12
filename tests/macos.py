#!/usr/bin/env python3
"""Lume-based macOS validation for the chezmoi dotfiles, run by a human.

The macOS analogue of tests/linux.py. Docker can't run macOS, so this uses Lume
(https://cua.ai/docs/lume) to boot a throwaway macOS VM on Apple Silicon. For
each image it renders the source and lints the darwin bootstrap scripts inside
the VM, with the real age key absent so encrypted files are excluded. The run VM
is deleted afterwards; Lume's layer cache and the ``lume config cache enable``
that fills it stay on the host (below).

``--full`` runs the real bootstrap in the VM as well -- the Homebrew bundle, the
``defaults write`` scripts, dockutil, the launchd agent -- and then asks the
guest what the bootstrap left behind, so the run reports a bootstrapped machine
rather than an exit code. It takes the better part of an hour and several
gigabytes of guest disk. What an unattended apply needs that a person at a
keyboard supplies -- an administrator sudo, a password for ``chsh`` -- the
entrypoint grants in the throwaway guest before the apply; ``tests/README.md``
has the list.

``lume ssh`` hands over the guest's output when the remote command exits, so the
guest tees it into ``~/Library/Logs/chezmoi-macos-tests`` through a second,
read-write share, and a run prints that file as it is written. ``tail -f`` on it
follows a run from another terminal. A guest that goes quiet is asked what it is
running, every two minutes; one still at it after two hours is given up on, with
that answer printed.

Lume is the only dependency and ships its own ``lume ssh``, so no password
plumbing is needed::

    /bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"

    python3 tests/macos.py
    python3 tests/macos.py --only tahoe
    python3 tests/macos.py --keep
    python3 tests/macos.py --full
    python3 tests/macos.py --build-base

The harness enables Lume's image layer cache (``lume config cache enable``; Lume
ships with it off), so ``lume pull`` writes the image layers to ``~/.lume/cache``
and the next run reuses them: only the first run downloads the image. The cache
and the setting persist; ``lume prune`` clears the cache and ``lume config cache
disable`` turns the setting back off.

A run clones a pristine ``chezmoi-test-base-<image>`` VM instead of pulling, when
one exists: a local copy that needs no network and skips re-materialising the
disk. ``--build-base`` pulls each image into that VM, and refreshes it to a newer
image the same way; without a base, a run falls back to ``lume pull``.

``--keep`` reuses the VM between runs instead of recreating and cold-booting it,
which is faster still to iterate with and means the guest carries state from the
last run -- with ``--full`` that is no longer a clean-machine test.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# Lume mounts each --shared-dir under this path, in a folder named after the host
# directory. The share is attached ":ro" so that even a --full bootstrap, which
# runs the real chezmoi apply, cannot write back into the source tree.
GUEST_SHARE = "/Volumes/My Shared Files"
ENTRYPOINT = "tests/lume/entrypoint.sh"
# Prebuilt images from Lume's default registry and organization (ghcr.io/trycua).
# Tahoe only: every macos-sequoia-* tag ships generic OCI tar layers that Lume
# skips wholesale, so the pull produces no VM at all (see tests/README.md).
IMAGES = {
    "tahoe": "macos-tahoe-cua:latest",
}
INSTALL_HINT = '/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"'
# A detached VM is not reachable the moment it starts; poll `lume ssh` until it answers.
# A cold first boot of a freshly pulled image is slow, so be generous.
SSH_TIMEOUT = 900
SSH_POLL_SECONDS = 5
# How often the boot wait prints a "still booting" line, so it is not silent.
SSH_HEARTBEAT_SECONDS = 15
SSH_PROBE_TIMEOUT = "15"
# The in-guest run downloads tools and may apply the whole bootstrap: no timeout.
SSH_NO_TIMEOUT = "0"
# `lume ssh` hands over the remote command's output when that command exits, and
# a --full run takes the better part of an hour, so the guest writes its own log
# to a directory shared read-write and the host prints that as it is written.
LOG_DIR = Path.home() / "Library" / "Logs" / "chezmoi-macos-tests"
LOG_POLL_SECONDS = 1.0
# How long the guest log may stay unchanged before the run says it is still alive.
# `lsregister` and a large `brew` download are each several quiet minutes.
LOG_HEARTBEAT_SECONDS = 120
# How long the in-guest run may take before the harness gives up on it. `lume ssh`
# is given no timeout of its own, so without this a guest waiting on something
# that will never arrive holds the run open for as long as the terminal is there.
# A --full bootstrap on a host with memory to spare takes well under an hour.
GUEST_TIMEOUT_SECONDS = 7200
# How long `lume ssh` gets to end on its own after being asked to, before it is killed.
TERMINATE_GRACE_SECONDS = 30


@dataclass(frozen=True)
class Target:
    """A macOS image to validate."""

    name: str
    image: str


def _lume(*argv: str) -> int:
    """Run a lume command, streaming its output.

    Args:
        argv: Arguments passed after ``lume``.

    Returns:
        The command's exit code.

    """
    return subprocess.run(["lume", *argv], check=False).returncode


def _base_vm(name: str) -> str:
    """The pristine, never-booted VM that a run clones instead of pulling.

    Args:
        name: An image name (a key of ``IMAGES``).

    Returns:
        The Lume VM name.

    """
    return f"chezmoi-test-base-{name}"


def _ensure_layer_cache() -> None:
    """Turn on Lume's OCI layer cache so repeated pulls reuse downloaded layers.

    Lume ships with caching off. With it on, ``lume pull`` writes image layers to
    ``~/.lume/cache`` and reuses them on the next pull, so only the first run of
    the default (no ``--keep``) mode downloads the image. The setting persists in
    Lume's config, so a later run finds it already on and returns early.
    """
    probe = subprocess.run(
        ["lume", "config", "get"],
        capture_output=True,
        text=True,
        check=False,
    )
    if "Caching enabled: true" in probe.stdout:
        return
    print("enabling Lume's image layer cache (lume config cache enable)", flush=True)
    if _lume("config", "cache", "enable") != 0:
        print(
            "warning: could not enable Lume's cache; every run will re-download the image",
            file=sys.stderr,
            flush=True,
        )


def _storage_root() -> Path:
    """Where Lume keeps its VMs, as Lume itself reports it.

    Returns:
        The default storage directory, falling back to ``~/.lume`` when the
        configuration cannot be read.

    """
    probe = subprocess.run(["lume", "config", "get"], capture_output=True, text=True, check=False)
    for line in probe.stdout.splitlines():
        # "Default VM storage: home (~/.lume)"
        if line.startswith("Default VM storage:") and "(" in line:
            named = line.split("(", 1)[1].rsplit(")", 1)[0].strip()
            if named:
                return Path(named).expanduser()
    return Path.home() / ".lume"


def _clear(vm: str) -> None:
    """Remove a VM an earlier run left behind, directory included.

    ``lume delete --force`` unregisters a VM that is still running but leaves its
    directory where it was, and the next ``lume clone`` then refuses the name with
    ``Directory already exists``. Removing it is safe once ``lume ls`` no longer
    lists the VM: nothing owns the directory at that point.

    Args:
        vm: The Lume VM name.

    """
    subprocess.run(["lume", "stop", vm], capture_output=True, check=False)
    subprocess.run(["lume", "delete", vm, "--force"], capture_output=True, check=False)
    if _vm_exists(vm):
        return
    orphan = _storage_root() / vm
    if orphan.is_dir():
        print(f"removing the directory lume left behind: {orphan}", flush=True)
        shutil.rmtree(orphan, ignore_errors=True)


def _vm_exists(vm: str) -> bool:
    """Report whether a VM of this name is already registered with Lume.

    Args:
        vm: The Lume VM name.

    Returns:
        True if ``lume ls`` lists the VM.

    """
    listing = ["lume", "ls", "-f", "json"]
    probe = subprocess.run(listing, capture_output=True, text=True, check=False)
    if probe.returncode != 0:
        return False
    try:
        machines = json.loads(probe.stdout)
    except json.JSONDecodeError:
        return False
    return any(machine.get("name") == vm for machine in machines)


def _wait_for_ssh(vm: str) -> str | None:
    """Poll ``lume ssh`` until the guest runs a command, meaning it has finished booting.

    A guest that is still booting and one that can never be reached both just fail, so
    the last probe's output is kept: it is the only thing that tells the two apart. The
    poll is otherwise silent for up to ``SSH_TIMEOUT`` seconds, so it prints a heartbeat.

    Args:
        vm: The Lume VM name.

    Returns:
        None once a command succeeds, otherwise the last failed probe's output.

    """
    start = time.monotonic()
    last = ""
    announced = 0.0
    print(f"waiting for {vm} to answer ssh (cold boot; up to {SSH_TIMEOUT}s)", flush=True)
    while time.monotonic() - start < SSH_TIMEOUT:
        probe = subprocess.run(
            ["lume", "ssh", "--timeout", SSH_PROBE_TIMEOUT, vm, "true"],
            capture_output=True,
            text=True,
            check=False,
        )
        elapsed = time.monotonic() - start
        if probe.returncode == 0:
            print(f"  ssh up after {elapsed:.0f}s", flush=True)
            return None
        last = (probe.stdout + probe.stderr).strip()
        if elapsed - announced >= SSH_HEARTBEAT_SECONDS:
            announced = elapsed
            print(f"  still booting ({elapsed:.0f}s)", flush=True)
        time.sleep(SSH_POLL_SECONDS)
    return last or "lume ssh produced no output"


def _remote_command(*, full: bool, log: str) -> str:
    """Build the shell command that runs the in-guest entrypoint.

    The read-only repo mount is expected at ``<share>/<repo directory name>``. Two
    directories are shared, so a fallback that cannot find it there looks for the
    share that carries the entrypoint rather than for the only one present.

    Everything the entrypoint prints goes through ``tee`` into the log share, which
    is what the host reads while the run is still going. ``pipefail`` keeps the exit
    code the entrypoint's; without it the pipeline reports ``tee``'s, which is 0
    whatever happened in the guest.

    Args:
        full: Whether the entrypoint should run the real bootstrap.
        log: Where in the guest to write the log, inside the read-write share.

    Returns:
        A single shell command line to hand to ``lume ssh``.

    """
    fallback = (
        f'find "{GUEST_SHARE}" -mindepth 1 -maxdepth 1 -type d '
        f'-exec test -f "{{}}/{ENTRYPOINT}" \\; -print | head -1'
    )
    return (
        f'SRC="{GUEST_SHARE}/{REPO.name}"; '
        f'[ -f "$SRC/{ENTRYPOINT}" ] || SRC="$({fallback})"; '
        # Should the log share be mounted under some other name, the run writes
        # its log inside the guest instead: the host then sees the output when
        # lume hands it over at the end, which is the whole run rather than none.
        f'LOG="{log}"; [ -d "$(dirname "$LOG")" ] || LOG=/tmp/entrypoint.log; '
        f"set -o pipefail; "
        f'FULL={"true" if full else "false"} SRC="$SRC" '
        f'bash "$SRC/{ENTRYPOINT}" 2>&1 | tee "$LOG"'
    )


def _processes(vm: str) -> str:
    """The guest's busiest processes, as evidence for a run that is given up on.

    Args:
        vm: The Lume VM name.

    Returns:
        The `ps` output, or a line saying the guest could not be asked.

    """
    probe = subprocess.run(
        [
            "lume",
            "ssh",
            "--timeout",
            SSH_PROBE_TIMEOUT,
            vm,
            "ps -Aceo pcpu,etime,comm | sort -rn | head -8",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        return f"  the guest did not answer: {(probe.stdout + probe.stderr).strip()}"
    return probe.stdout.rstrip()


def _written(vm: str) -> int:
    """How much the guest's disk image has grown into, in bytes.

    The blocks the sparse image has been allocated, not its nominal size. It is
    read from the host, so it answers "is anything happening in there" without
    the guest having to be reachable -- which is the question a quiet run raises,
    and `brew` buffers its output into chunks large enough that silence proves
    nothing on its own.

    Args:
        vm: The Lume VM name.

    Returns:
        The bytes allocated to the disk image, or 0 when it cannot be found.

    """
    disk = _storage_root() / vm / "disk.img"
    try:
        # st_blocks counts 512-byte blocks actually allocated; st_size is the
        # nominal 150 GB the image was created with and never changes.
        return disk.stat().st_blocks * 512
    except OSError:
        return 0


def _busiest(vm: str) -> str:
    """What the guest is spending its processor on, asked over a second ssh session.

    This is what the heartbeat says instead of only how long it has been quiet. The
    long silences in a bootstrap are steps that print nothing while they work --
    ``lsregister`` rebuilding the LaunchServices database is minutes of it -- and
    naming the process tells those apart from a run waiting on something.

    Args:
        vm: The Lume VM name.

    Returns:
        The busiest process as ``<cpu> <elapsed> <name>``, or an empty string when
        the guest cannot be asked.

    """
    probe = subprocess.run(
        [
            "lume",
            "ssh",
            "--timeout",
            SSH_PROBE_TIMEOUT,
            vm,
            "ps -Aceo pcpu,etime,comm | sort -rn | head -1",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        return ""
    lines = [line.strip() for line in probe.stdout.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def _stream(vm: str, argv: list[str], log: Path, captured: Path) -> int:
    """Run a lume command, printing the guest's log as the guest writes it.

    Lume's own output is sent to a file rather than to a pipe nothing is reading:
    it arrives in one piece at the end and is megabytes for a ``--full`` run, and
    a pipe that fills stops the command that is writing to it.

    Args:
        vm: The Lume VM name, for the heartbeat to ask what the guest is doing.
        argv: The lume command and its arguments.
        log: The host side of the guest's log file.
        captured: Where to put what lume itself writes.

    Returns:
        The command's exit code.

    """
    shown = 0
    start = time.monotonic()
    quiet = start
    written = _written(vm)

    def emit(chunk: str) -> None:
        sys.stdout.write(chunk)
        sys.stdout.flush()

    with captured.open("w", encoding="utf-8") as sink:
        proc = subprocess.Popen(argv, stdout=sink, stderr=subprocess.STDOUT, text=True)
        with log.open("r", encoding="utf-8", errors="replace") as reader:
            while proc.poll() is None:
                chunk = reader.read()
                if chunk:
                    emit(chunk)
                    shown += len(chunk)
                    quiet = time.monotonic()
                    continue
                now = time.monotonic()
                if now - start >= GUEST_TIMEOUT_SECONDS:
                    print(
                        f"\ngiving up: the guest has been at it for "
                        f"{GUEST_TIMEOUT_SECONDS / 3600:.0f}h. What it is running:",
                        file=sys.stderr,
                        flush=True,
                    )
                    print(_processes(vm), file=sys.stderr, flush=True)
                    proc.terminate()
                    break
                if now - quiet >= LOG_HEARTBEAT_SECONDS:
                    quiet = now
                    grown = _written(vm)
                    busy = _busiest(vm)
                    disk = f"; guest disk +{(grown - written) / 1e9:.2f} GB" if written else ""
                    written = grown
                    where = f"; busiest: {busy}" if busy else ""
                    print(f"  [{(now - start) / 60:.0f}m] quiet{disk}{where}", flush=True)
                time.sleep(LOG_POLL_SECONDS)
            # `terminate` returns before the process does, and the guest's last
            # lines can land between the poll above and the exit, so reap first.
            try:
                proc.wait(timeout=TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            tail = reader.read()
            if tail:
                emit(tail)
                shown += len(tail)

    # Nothing in the log means the guest never reached the `tee`, so whatever lume
    # said is the only account of the run there is. It holds the guest's output as
    # well when the log did work, which is why it is named rather than printed: a
    # dropped connection is explained there and nowhere else.
    if shown == 0:
        print(captured.read_text(encoding="utf-8", errors="replace").strip(), flush=True)
    elif proc.returncode != 0:
        print(f"lume's own account of the run: {captured}", file=sys.stderr, flush=True)

    return proc.returncode


def _materialise(target: Target, vm: str) -> bool:
    """Create the run VM, cloning the base when one exists so no network is needed.

    ``lume clone`` copies the base VM's disk locally (copy-on-write), so a run
    reaches the registry only until ``--build-base`` has been run once.

    Args:
        target: The macOS image to validate.
        vm: The run VM name to create.

    Returns:
        True if the VM was created.

    """
    base = _base_vm(target.name)
    if _vm_exists(base):
        print(f"cloning {base} -> {vm}", flush=True)
        return _lume("clone", base, vm) == 0
    print(f"no {base}; pulling {target.image} (needs network -- see --build-base)", flush=True)
    return _lume("pull", target.image, vm) == 0


def _build_bases(only: list[str] | None) -> int:
    """Pull each selected image into its base VM, replacing one already there.

    Args:
        only: Image names to build, or None for every image in ``IMAGES``.

    Returns:
        Process exit code: 0 when every pull succeeded.

    """
    failed = []
    for name in only or IMAGES:
        base = _base_vm(name)
        print(f"\n=== {base} ({IMAGES[name]}) ===", flush=True)
        subprocess.run(["lume", "delete", base, "--force"], capture_output=True, check=False)
        if _lume("pull", IMAGES[name], base) != 0:
            failed.append(name)
    print()
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print("Base VMs ready; runs clone them without network.")
    return 0


def run_target(target: Target, *, full: bool, keep: bool) -> bool:
    """Validate one macOS image in a throwaway Lume VM, deleting the VM afterwards.

    Args:
        target: The macOS image to validate.
        full: Whether to run the real bootstrap in-guest after render + lint.
        keep: Whether to keep the VM (and reuse an existing one) instead of
            recreating it and deleting it afterwards. Recreating clones the base
            VM when there is one, which is quick, so ``--keep`` mainly saves the
            cold boot -- at the cost of the throwaway guarantee.

    Returns:
        True if the in-guest validation exited zero.

    """
    vm = f"chezmoi-test-{target.name}"
    print(f"\n=== {target.name} ({target.image}) ===", flush=True)
    if keep and _vm_exists(vm):
        print(f"reusing the existing {vm} VM (--keep)", flush=True)
    else:
        # Clear any VM left behind by an interrupted earlier run, then materialise a fresh one.
        _clear(vm)
        if not _materialise(target, vm):
            return False

    # The guest writes here through the read-write share; the host reads the same
    # file while the run is going. Emptied first, so what is printed below is this
    # run's and a `tail -f` from another terminal starts where this one does.
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / f"{vm}.log"
    log.write_text("", encoding="utf-8")

    try:
        started = _lume(
            "run",
            "--detach",
            "--display",
            "none",
            "--shared-dir",
            f"{REPO}:ro",
            "--shared-dir",
            f"{LOG_DIR}:rw",
            vm,
        )
        if started != 0:
            return False
        unreachable = _wait_for_ssh(vm)
        if unreachable is not None:
            print(
                f"{target.name}: no ssh after {SSH_TIMEOUT}s; last probe said: {unreachable}",
                file=sys.stderr,
                flush=True,
            )
            _lume("get", vm)
            return False
        note = "render + lint, then the real bootstrap (the better part of an hour)"
        print(f"running the in-guest checks: {note if full else 'render + lint'}", flush=True)
        print(f"the guest's log, as it is written: {log}", flush=True)
        remote = _remote_command(full=full, log=f"{GUEST_SHARE}/{LOG_DIR.name}/{log.name}")
        argv = ["lume", "ssh", "--timeout", SSH_NO_TIMEOUT, vm, remote]
        return _stream(vm, argv, log, LOG_DIR / f"{vm}.lume.log") == 0
    finally:
        subprocess.run(["lume", "stop", vm], capture_output=True, check=False)
        if not keep:
            _clear(vm)


def main() -> int:
    """Validate every macOS image and report the outcome.

    Returns:
        Process exit code: 0 when all images pass, 1 otherwise.

    """
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help="also run the real bootstrap in-guest: Homebrew bundle, defaults write, dockutil",
    )
    parser.add_argument(
        "--only",
        action="append",
        choices=sorted(IMAGES),
        metavar="IMAGE",
        help="validate only this image (repeatable); also narrows --build-base",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help=(
            "reuse and keep the VM instead of recreating it and deleting it: "
            "faster, but the guest carries state from the previous run"
        ),
    )
    parser.add_argument(
        "--build-base",
        action="store_true",
        help=(
            "pull each image into its reusable chezmoi-test-base-<image> VM, then exit; "
            "later runs clone that offline instead of pulling"
        ),
    )
    args = parser.parse_args()

    if shutil.which("lume") is None:
        print(f"lume is not installed ({INSTALL_HINT})", file=sys.stderr)
        return 1

    _ensure_layer_cache()

    if args.build_base:
        return _build_bases(args.only)

    targets = [Target(name=name, image=IMAGES[name]) for name in args.only or IMAGES]
    failed = [t.name for t in targets if not run_target(t, full=args.full, keep=args.keep)]

    print()
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print("All macOS targets passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
