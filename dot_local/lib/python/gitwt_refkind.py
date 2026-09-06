"""Resolve references passed by the user."""

from __future__ import annotations

from enum import Enum
from typing import TYPE_CHECKING

from gitwt_git import REMOTE, GitWtError

if TYPE_CHECKING:
    from gitwt_repo import Repo


class RefKind(Enum):
    """What a ref names, which decides how the worktree is created.

    A branch that exists on origin is tracked, a tag or commit is checked out
    detached, and a name that matches nothing becomes a new branch.
    """

    LOCAL_BRANCH = "branch"
    REMOTE_BRANCH = "remote branch"
    TAG = "tag"
    COMMIT = "commit"
    UNKNOWN = "unknown"

    @classmethod
    def resolve(cls, repo: Repo, ref: str) -> RefKind:
        """Classify a user-supplied ref name.

        Args:
            repo: The layout to look the ref up in.
            ref: A branch, tag, commit, or unknown name.

        Returns:
            The kind of thing ``ref`` names.

        """
        if repo.has_ref(f"refs/heads/{ref}"):
            return cls.LOCAL_BRANCH
        if repo.has_ref(f"refs/remotes/{REMOTE}/{ref}"):
            return cls.REMOTE_BRANCH
        if repo.has_ref(f"refs/tags/{ref}"):
            return cls.TAG

        try:
            repo.git("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
        except GitWtError:
            return cls.UNKNOWN
        return cls.COMMIT
