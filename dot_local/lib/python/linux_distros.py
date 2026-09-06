"""The Linux targets these dotfiles support, named once.

Two consumers read this: ``chezmoi-packages search``, which asks each distro's
real repositories what a tool is called there, and ``tests/linux.py``, which
renders and lints every ``distro x sudo`` combination. Keeping the matrix here
means adding a distro is one edit rather than two that can drift apart.

It is deployed rather than kept with the harness because ``chezmoi-packages``
runs from ``~/.local/bin``, where ``tests/`` does not exist.
"""

from __future__ import annotations

# The throwaway container each distro is queried in.
IMAGES = {
    "ubuntu": "ubuntu:24.04",
    "fedora": "fedora:41",
    "rocky": "rockylinux:9",
    "alma": "almalinux:9",
}
# The .chezmoidata/packages.toml column each of those speaks for. rocky and alma
# share `el`, because they are the same repositories.
TARGET_OF = {"ubuntu": "apt", "fedora": "fedora", "rocky": "el", "alma": "el"}
