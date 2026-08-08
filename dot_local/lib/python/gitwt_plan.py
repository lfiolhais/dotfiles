"""Where a ref should go, and the arguments that put it there."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from gitwt_git import REMOTE, GitWtError
from gitwt_refkind import RefKind
from gitwt_repo import Repo

# Everything that is not a word character, a dot, or a dash collapses to a single
# dash, so "feature/foo bar" becomes "feature-foo-bar".
_UNSAFE = re.compile(r"[^\w.-]+")


@dataclass(frozen=True)
class Plan:
    """How one ref is about to be turned into a worktree."""

    kind: RefKind
    path: Path
    summary: str
    argv: tuple[str, ...]

    @staticmethod
    def _folder_name(ref: str) -> str:
        """Turn a ref into a directory name that is safe to create.

        Args:
            ref: A branch, tag, or commit.

        Returns:
            The ref with unsafe runs collapsed to dashes: ``feature/foo`` becomes
            ``feature-foo``.

        Raises:
            GitWtError: If nothing usable is left of the ref.

        """
        name = _UNSAFE.sub("-", ref).strip("-.")
        if not name:
            msg = f"cannot derive a folder name from {ref!r}"
            raise GitWtError(msg)
        return name

    @classmethod
    def from_repo(cls, repo: Repo, ref: str, kind: RefKind) -> Plan:
        """Work out where a ref should go and how to check it out there.

        Args:
            repo: The layout to add to.
            ref: The ref as the user typed it.
            kind: What that ref names, from :meth:`RefKind.resolve`.

        Returns:
            The folder to create, plus the arguments to ``git worktree add`` that
            create it.

        """
        if kind is RefKind.COMMIT:
            # A full hash, or something like HEAD~2, reads badly as a folder name.
            ref = repo.git("rev-parse", "--short", ref)

        path = repo.root / cls._folder_name(ref)
        target = str(path)

        if kind is RefKind.LOCAL_BRANCH:
            return cls(kind, path, f"branch {ref!r}", (target, ref))

        if kind is RefKind.REMOTE_BRANCH:
            upstream = f"{REMOTE}/{ref}"
            return cls(
                kind,
                path,
                f"branch {ref!r}, tracking {upstream}",
                ("--track", "-b", ref, target, upstream),
            )

        if kind in {RefKind.TAG, RefKind.COMMIT}:
            return cls(
                kind,
                path,
                f"{kind.value} {ref!r}, detached",
                ("--detach", target, ref),
            )

        base = f"{REMOTE}/{repo.default_branch()}"
        return cls(
            kind,
            path,
            f"new branch {ref!r}, off {base}",
            ("-b", ref, target, base),
        )
