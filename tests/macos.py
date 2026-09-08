#!/usr/bin/env python3
"""Lume-based macOS validation for the chezmoi dotfiles, run by a human.

The macOS analogue of tests/linux.py. Docker can't run macOS, so this uses Lume
(https://cua.ai/docs/lume) to boot a throwaway macOS VM on Apple Silicon. For
each image it renders the source and lints the darwin bootstrap scripts inside
the VM, with the real age key absent so encrypted files are excluded. The run VM
is deleted afterwards; Lume's layer cache and the ``lume config cache enable``
that fills it stay on the host (below). With ``--full`` it also runs the real
bootstrap in the VM (heavy: Homebrew bundle, ``defaults write``, dockutil). Lume
is the only dependency and ships its own ``lume ssh``, so no password plumbing is
needed::

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
        subprocess.run(["lume", "delete", vm, "--force"], capture_output=True, check=False)
        if not _materialise(target, vm):
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
