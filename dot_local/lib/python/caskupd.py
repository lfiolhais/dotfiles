"""Shared library to keep app self-updaters out of Homebrew's way.

This module is the whole public surface: the command under ``~/.local/bin``
imports from ``caskupd`` and nothing else.
"""

from __future__ import annotations

from caskupd_app import APPDIR, EXEMPT, SPARKLE_FRAMEWORK, SPARKLE_KEYS, App
from caskupd_sparkle import CHECKS, INSTALLS, KEYS, OFF, Sparkle
from chezpkg_run import PackagesError, have

__all__ = [
    "APPDIR",
    "CHECKS",
    "EXEMPT",
    "INSTALLS",
    "KEYS",
    "OFF",
    "SPARKLE_FRAMEWORK",
    "SPARKLE_KEYS",
    "App",
    "PackagesError",
    "Sparkle",
    "have",
]
