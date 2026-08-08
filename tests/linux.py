#!/usr/bin/env python3
"""Docker-based Linux validation.

With ``--full`` it runs the real bootstrap in-container. Requires Docker.
Usage::
   python3 tests/linux.py
   python3 tests/linux.py --full
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from itertools import product
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENTRYPOINT = "/src/tests/docker/entrypoint.sh"
IMAGES = {
    "ubuntu": "ubuntu:24.04",
    "fedora": "fedora:41",
    "rocky": "rockylinux:9",
    "alma": "almalinux:9",
}
SUDO_MODES = (True, False)


@dataclass(frozen=True)
class Target:
    """A Linux configuration to validate."""

    distro: str
    sudo: bool

    @property
    def label(self) -> str:
        """Human-readable name combining the distro and sudo mode.

        Returns:
            A label like ``ubuntu/no-sudo``.

        """
        return f"{self.distro}/{'sudo' if self.sudo else 'no-sudo'}"


def run_target(target: Target, *, full: bool) -> bool:
    """Validate one target in a throwaway container.

    Args:
        target: The distro and sudo mode to validate.
        full: Whether to run the real bootstrap in-container after render + lint.

    Returns:
        True if the container exited zero.

    """
    cmd = [
        "docker",
        "run",
        "--rm",
        "-v",
        f"{REPO}:/src:ro",
        "-e",
        f"SUDO={'true' if target.sudo else 'false'}",
        "-e",
        f"FULL={'true' if full else 'false'}",
        IMAGES[target.distro],
        "bash",
        ENTRYPOINT,
    ]
    print(f"\n=== {target.label} ({IMAGES[target.distro]}) ===")
    return subprocess.run(cmd, check=False).returncode == 0


def main() -> int:
    """Validate every Linux target and report the outcome.

    Returns:
        Process exit code: 0 when all targets pass, 1 otherwise.

    """
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--full", action="store_true", help="run the real bootstrap in-container")
    args = parser.parse_args()

    probe = subprocess.run(["docker", "info"], capture_output=True, check=False)
    if probe.returncode != 0:
        print("docker is not available or not running", file=sys.stderr)
        return 1

    targets = [Target(distro=distro, sudo=sudo) for distro, sudo in product(IMAGES, SUDO_MODES)]
    failed = [t.label for t in targets if not run_target(t, full=args.full)]

    print()
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print("All Linux targets passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
