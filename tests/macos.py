#!/usr/bin/env python3
"""Lume-based macOS validation for the chezmoi dotfiles, run by a human.

The macOS analogue of tests/linux.py. Docker can't run macOS, so this uses Lume
(https://cua.ai/docs/lume) to boot a throwaway macOS VM on Apple Silicon. For
each image it renders the source and lints the darwin bootstrap scripts inside
the VM -- without touching the host and without the real age key (encrypted
files are excluded). With ``--full`` it also runs the real bootstrap in the VM
(heavy: Homebrew bundle, ``defaults write``, dockutil). Lume is the only
dependency and ships its own ``lume ssh``, so no password plumbing is needed::

    /bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"

    python3 tests/macos.py
    python3 tests/macos.py --only tahoe
    python3 tests/macos.py --keep
    python3 tests/macos.py --full

``--keep`` reuses the VM between runs instead of pulling a fresh one, which is
much faster to iterate with and means the guest carries state from the last run:
with ``--full`` that is no longer a clean-machine test.
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
# Tahoe only: every macos-sequoia-* tag ships generic OCI tar layers that Lume 0.5.1
# skips wholesale, so the pull produces no VM at all (see tests/README.md).
IMAGES = {
    "tahoe": "macos-tahoe-cua:latest",
}
INSTALL_HINT = '/bin/bash -c "$(curl -fsSL https://cua.ai/lume/install.sh)"'
# A detached VM is not reachable the moment it starts; poll `lume ssh` until it answers.
# A cold first boot of a freshly pulled image is slow, so be generous.
SSH_TIMEOUT = 900
SSH_POLL_SECONDS = 5
SSH_PROBE_TIMEOUT = "15"
# The in-guest run downloads tools and may apply the whole bootstrap: no timeout.
SSH_NO_TIMEOUT = "0"


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
    the last probe's output is kept: it is the only thing that tells the two apart.

    Args:
        vm: The Lume VM name.

    Returns:
        None once a command succeeds, otherwise the last failed probe's output.

    """
    deadline = time.monotonic() + SSH_TIMEOUT
    last = ""
    while time.monotonic() < deadline:
        probe = subprocess.run(
            ["lume", "ssh", "--timeout", SSH_PROBE_TIMEOUT, vm, "true"],
            capture_output=True,
            text=True,
            check=False,
        )
        if probe.returncode == 0:
            return None
        last = (probe.stdout + probe.stderr).strip()
        time.sleep(SSH_POLL_SECONDS)
    return last or "lume ssh produced no output"


def _remote_command(*, full: bool) -> str:
    """Build the shell command that runs the in-guest entrypoint.

    The read-only repo mount is expected at ``<share>/<repo directory name>``; should Lume
    ever name it differently, fall back to the only directory under the share.

    Args:
        full: Whether the entrypoint should run the real bootstrap.

    Returns:
        A single shell command line to hand to ``lume ssh``.

    """
    fallback = f'find "{GUEST_SHARE}" -mindepth 1 -maxdepth 1 -type d | head -1'
    return (
        f'SRC="{GUEST_SHARE}/{REPO.name}"; '
        f'[ -d "$SRC" ] || SRC="$({fallback})"; '
        f'FULL={"true" if full else "false"} SRC="$SRC" bash "$SRC/{ENTRYPOINT}"'
    )


def run_target(target: Target, *, full: bool, keep: bool) -> bool:
    """Validate one macOS image in a throwaway Lume VM, deleting the VM afterwards.

    Args:
        target: The macOS image to validate.
        full: Whether to run the real bootstrap in-guest after render + lint.
        keep: Whether to keep the VM (and reuse an existing one) instead of pulling a
            fresh copy and deleting it. Each pull is tens of gigabytes, so this makes
            repeated runs cheap at the cost of the throwaway guarantee.

    Returns:
        True if the in-guest validation exited zero.

    """
    vm = f"chezmoi-test-{target.name}"
    print(f"\n=== {target.name} ({target.image}) ===", flush=True)
    if keep and _vm_exists(vm):
        print(f"reusing the existing {vm} VM (--keep)", flush=True)
    else:
        # Clear any VM left behind by an interrupted earlier run, then materialise a fresh one.
        subprocess.run(["lume", "delete", vm, "--force"], capture_output=True, check=False)
        if _lume("pull", target.image, vm) != 0:
            return False
    try:
        if _lume("run", "--detach", "--display", "none", "--shared-dir", f"{REPO}:ro", vm) != 0:
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
        return _lume("ssh", "--timeout", SSH_NO_TIMEOUT, vm, _remote_command(full=full)) == 0
    finally:
        subprocess.run(["lume", "stop", vm], capture_output=True, check=False)
        if not keep:
            subprocess.run(["lume", "delete", vm, "--force"], capture_output=True, check=False)


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
        help="validate only this image (repeatable); each image is a large pull",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help=(
            "reuse and keep the VM instead of pulling a fresh copy and deleting it: "
            "much faster, but the guest carries state from the previous run"
        ),
    )
    args = parser.parse_args()

    if shutil.which("lume") is None:
        print(f"lume is not installed ({INSTALL_HINT})", file=sys.stderr)
        return 1

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
