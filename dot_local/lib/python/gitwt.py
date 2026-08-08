"""Shared library to manage Git worktrees.

This module is the whole public surface: the commands under ``~/.local/bin``
import from ``gitwt`` and nothing else.
"""

from __future__ import annotations

from gitwt_git import (
    BARE_DIR,
    FETCH_REFSPEC,
    POINTER_TEXT,
    REMOTE,
    GitWtError,
    git,
)
from gitwt_plan import Plan
from gitwt_refkind import RefKind
from gitwt_repo import Repo
from gitwt_worktree import Worktree

__all__ = [
    "BARE_DIR",
    "FETCH_REFSPEC",
    "POINTER_TEXT",
    "REMOTE",
    "GitWtError",
    "Plan",
    "RefKind",
    "Repo",
    "Worktree",
    "git",
]
