"""Creating a worktree for a ref, or accepting the one already there."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from gitwt_git import GitWtError, git
from gitwt_plan import Plan
from gitwt_refkind import RefKind
from gitwt_repo import Repo


@dataclass(frozen=True)
class Worktree:
    """A worktree that was created, or found already in place."""

    path: Path
    kind: RefKind
    summary: str

    @classmethod
    def _reuse(cls, repo: Repo, plan: Plan, ref: str) -> Worktree:
        """Reuse a folder as a worktree.

        Args:
            repo: The layout being added to.
            plan: What would otherwise have been created.
            ref: The ref as the user typed it.

        Returns:
            The worktree already at that path, so re-running a command is harmless.

        Raises:
            GitWtError: If the folder is not a worktree, or holds a different ref.

        """
        resolved = plan.path.resolve()
        registered = repo.worktrees()

        if resolved not in registered:
            msg = f"{plan.path} already exists and is not a worktree"
            raise GitWtError(msg)

        branch = registered[resolved]

        if plan.kind in {RefKind.TAG, RefKind.COMMIT}:
            # Detached: the branch name says nothing, so compare the commits.
            here = git("rev-parse", "HEAD", cwd=plan.path)
            wanted = repo.git("rev-parse", f"{ref}^{{commit}}")
            same = here == wanted
        else:
            same = branch == ref

        if not same:
            holds = f"branch {branch!r}" if branch is not None else "a detached HEAD"
            msg = f"{plan.path} already holds {holds}, not {ref!r}"
            raise GitWtError(msg)

        return cls(plan.path, plan.kind, "already checked out")

    @classmethod
    def add_worktree(cls, repo: Repo, ref: str) -> Worktree:
        """Check a ref out into its own folder beside the bare clone.

        A branch is checked out as a branch, tracking its remote when it exists only
        there. A tag or commit is checked out detached, since moving a branch onto a
        tag is never what was meant. A ref that matches nothing triggers a single
        fetch; if it still matches nothing it is taken as the name of a new branch to
        create off the default branch.

        Args:
            repo: The layout to add to.
            ref: A branch, tag, commit, or new branch name.

        Returns:
            The worktree, whether it was just created or was already there.

        """
        kind = RefKind.resolve(repo, ref)
        if kind is RefKind.UNKNOWN:
            # Only pay for the network when the ref is genuinely unfamiliar.
            repo.fetch()
            kind = RefKind.resolve(repo, ref)

        plan = Plan.from_repo(repo, ref, kind)

        if plan.path.exists():
            return cls._reuse(repo, plan, ref)

        repo.git("worktree", "add", *plan.argv, stream=True)

        return cls(plan.path, plan.kind, plan.summary)
