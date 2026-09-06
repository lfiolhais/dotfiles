"""Process plumbing and layout constants shared by every other module."""

from __future__ import annotations

import shlex
import subprocess

# No timeout is set on git itself, unlike chezpkg_run: a clone or fetch of a large
# repository legitimately outlasts any cap short enough to be useful, and killing
# one halfway leaves a partial object store behind.
from pathlib import Path

# The bare clone lives here, and every worktree is created beside it.
BARE_DIR = ".bare"
# What the layout root's .git file holds, so git treats the root as a repository.
POINTER_TEXT = f"gitdir: ./{BARE_DIR}\n"
REMOTE = "origin"
# "git init --bare" configures no refspec at all; this is the one a clone has.
FETCH_REFSPEC = f"+refs/heads/*:refs/remotes/{REMOTE}/*"


class GitWtError(Exception):
    """A failure to report to the user as a message, without a traceback."""


def git(*argv: str, cwd: Path | None = None, stream: bool = False) -> str:
    """Run a git command and return its output.

    Args:
        argv: git command's arguments.
        cwd: Directory to run in; defaults to the current one.
        stream: Let the command write straight to the terminal instead of being
            captured, so slow git operations can show their progress.

    Returns:
        The command's stripped stdout, or the empty string when streaming.

    Raises:
        GitWtError: If the binary is missing or the command fails.

    """
    try:
        args = ["git", *argv]
        proc = subprocess.run(
            args,
            cwd=str(cwd) if cwd is not None else None,
            capture_output=not stream,
            text=True,
            check=False,
        )
    except FileNotFoundError as exc:
        msg = "command not found: git"
        raise GitWtError(msg) from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
        msg = f"{shlex.join(argv)}: {detail}"
        raise GitWtError(msg)

    return "" if stream else proc.stdout.strip()
