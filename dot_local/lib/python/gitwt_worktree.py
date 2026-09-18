"""Creating a worktree for a ref, removing one, or accepting the one in place."""

from __future__ import annotations

from collections.abc import Callable
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
    def add_worktree(
        cls,
        repo: Repo,
        ref: str,
        confirm_new: Callable[[str], bool] | None = None,
    ) -> Worktree:
        """Check a ref out into its own folder beside the bare clone.

        A branch is checked out as a branch, tracking its remote when it exists only
        there. A tag or commit is checked out detached, since moving a branch onto a
        tag is never what was meant. A ref that matches nothing triggers a single
        fetch; if it still matches nothing it is taken as the name of a new branch to
        create off the default branch.

        Args:
            repo: The layout to add to.
            ref: A branch, tag, commit, or new branch name.
            confirm_new: Called with the default branch's name when ``ref``
                still matches nothing after the fetch, before the new branch
                and its folder exist -- the moment a typo is still free to
                abandon. None creates the branch without asking, which is what
                a non-interactive caller wants.

        Returns:
            The worktree, whether it was just created or was already there.

        Raises:
            GitWtError: If ``confirm_new`` declined the new branch.

        """
        kind = RefKind.resolve(repo, ref)
        if kind is RefKind.UNKNOWN:
            # Only pay for the network when the ref is genuinely unfamiliar.
            repo.fetch()
            kind = RefKind.resolve(repo, ref)

        if (
            kind is RefKind.UNKNOWN
            and confirm_new is not None
            and not confirm_new(repo.default_branch())
        ):
            msg = f"{ref!r} matches no branch, tag or commit; nothing created"
            raise GitWtError(msg)

        plan = Plan.from_repo(repo, ref, kind)

        if plan.path.exists():
            return cls._reuse(repo, plan, ref)

        repo.git("worktree", "add", *plan.argv, stream=True)

        return cls(plan.path, plan.kind, plan.summary)


@dataclass(frozen=True)
class Removal:
    """A worktree that was removed, and what happened to its branch."""

    path: Path
    branch: str | None
    branch_deleted: bool
    branch_error: str


def remove_worktree(
    repo: Repo,
    ref: str,
    *,
    force: bool = False,
    delete_branch: bool = True,
) -> Removal:
    """Remove a ref's worktree, and the local branch it held.

    The folder is found the way ``add`` named it, so the argument is the ref as
    it was checked out and ``feature/foo`` removes ``feature-foo/``. ``git
    worktree remove`` refuses a folder holding uncommitted work unless
    ``force``. The branch is deleted with ``git branch -d``, which refuses an
    unmerged one; that refusal comes back in the result rather than escalating
    to ``-D``, because deleting unmerged work is the caller's decision alone. A
    detached worktree -- a tag or a commit -- has no branch to delete.

    Args:
        repo: The layout to remove from.
        ref: The ref whose worktree should go.
        force: Remove the worktree even when it holds uncommitted changes,
            discarding them.
        delete_branch: Whether to delete the local branch the worktree held.

    Returns:
        What was removed, and what the branch deletion said.

    Raises:
        GitWtError: If the ref has no worktree here.

    """
    path = (repo.root / Plan._folder_name(ref)).resolve()
    registered = repo.worktrees()
    if path not in registered:
        names = sorted(p.name for p in registered if p != repo.bare)
        listing = f"; the worktrees here are: {', '.join(names)}" if names else ""
        msg = f"{path.name} is not a worktree of {repo.root}{listing}"
        raise GitWtError(msg)

    branch = registered[path]
    force_flag = ("--force",) if force else ()
    repo.git("worktree", "remove", *force_flag, str(path))

    if branch is None or not delete_branch:
        return Removal(path, branch, branch_deleted=False, branch_error="")

    try:
        repo.git("branch", "-d", branch)
    except GitWtError as exc:
        return Removal(path, branch, branch_deleted=False, branch_error=str(exc))

    return Removal(path, branch, branch_deleted=True, branch_error="")
