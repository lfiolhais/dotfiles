#!/usr/bin/env python3
"""Docker-based Linux validation.

The default run renders and lints the source in a throwaway container for every
distro in ``IMAGES`` crossed with sudo and no-sudo, and asks each distro's
package manager whether every name the manifest targets at it resolves --
installing nothing. That last check is what makes the one-transaction install in
the 01 bootstrap script safe, and it is the reason to run this after editing
packages.

``--full`` additionally runs the real bootstrap in each container, installing the
whole toolchain, TeX included: gigabytes, and a long wait. It also wants
``GITHUB_TOKEN`` in the environment, because the no-sudo profile resolves most of
mise's toolchain from GitHub releases and four no-sudo targets exhaust the
unauthenticated rate limit.

Requires Docker. Usage::

   python3 tests/linux.py
   python3 tests/linux.py --full
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass
from itertools import product
from pathlib import Path

# The distro matrix is shared with the chezmoi-packages command, so it lives in
# the deployed library rather than being spelled out in both places.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

from linux_distros import IMAGES

REPO = Path(__file__).resolve().parent.parent
ENTRYPOINT = "/src/tests/docker/entrypoint.sh"
# Both profiles the dotfiles support: with sudo the distro package manager
# installs the toolchain, without it mise does. Each is crossed with every
# image, because the bootstrap takes a different path for each.
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
        # read-only: a --full bootstrap in the container must not write to the source
        f"{REPO}:/src:ro",
        "-e",
        f"SUDO={'true' if target.sudo else 'false'}",
        "-e",
        f"FULL={'true' if full else 'false'}",
    ]
    # mise resolves most of the no-sudo toolchain through GitHub releases, and
    # unauthenticated that is 60 requests an hour for the whole host -- which a
    # --full run across four no-sudo targets exhausts. Forward a token when the
    # environment has one; without it, expect rate-limit failures on repeat runs.
    if os.environ.get("GITHUB_TOKEN"):
        cmd += ["-e", "GITHUB_TOKEN"]
    cmd += [IMAGES[target.distro], "bash", ENTRYPOINT]
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
    parser.add_argument(
        "--full",
        action="store_true",
        help="also install the whole toolchain in each container (gigabytes; wants GITHUB_TOKEN)",
    )
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
