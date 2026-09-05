"""Shared library behind the ``chezmoi-packages`` command.

This module is the whole public surface: the command imports from ``chezpkg``
and nothing else.

Unlike ``gitwt``, this family needs Python 3.11 rather than 3.9 -- the command
runs under ``uv``, which supplies its own interpreter, so the floor that exists
for the ``git-wt-*`` commands (Apple's 3.9 on a fresh Mac) does not apply. Only
writing the manifest needs the one third-party dependency, and that import is
guarded, so importing this library needs nothing beyond the standard one.
"""

from __future__ import annotations

from chezpkg_brew import Brewfile, Entry
from chezpkg_manifest import FIELDS, TARGETS, Manifest
from chezpkg_run import PackagesError, have, maybe, run
from chezpkg_search import Match, Search
from chezpkg_source import Source

__all__ = [
    "FIELDS",
    "TARGETS",
    "Brewfile",
    "Entry",
    "Manifest",
    "Match",
    "PackagesError",
    "Search",
    "Source",
    "have",
    "maybe",
    "run",
]
