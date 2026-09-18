#!/usr/bin/env python3
"""Unit tests for the worktree planning logic.

Nothing real is touched: the repository is a recorder that answers ref lookups
from a fixture set, so no git runs, nothing is fetched, and no folder is
created. What is being asserted is the pure middle of the ``git-wt`` commands:
which ``git worktree add`` argv each kind of ref produces, how a ref becomes a
folder name, and when an existing folder is accepted as already checked out.

A wrong answer here is quiet in every other harness -- a dropped ``--no-track``
still clones, still checks out, and only shows up as a wrong upstream at the
first push.

Usage::

    python3 tests/gitwt.py
"""

from __future__ import annotations

import sys
import traceback
from collections.abc import Callable
from itertools import starmap
from pathlib import Path

# The library is deployed rather than kept here, so it is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

from gitwt_git import REMOTE, GitWtError
from gitwt_plan import Plan
from gitwt_refkind import RefKind
from gitwt_worktree import Worktree

ROOT = Path("/repo")
SHORT = "abc1234"


def _message(action: Callable[[], object]) -> str:
    """Run an action expected to fail with a GitWtError.

    Args:
        action: The call under test.

    Returns:
        The error's message, or the empty string when nothing was raised --
        so a test asserts on the message and an unexpected success fails it.

    """
    try:
        action()
    except GitWtError as exc:
        return str(exc)
    return ""


class FakeRepo:
    """Stands in for a Repo: answers ref lookups from fixtures, records git calls."""

    def __init__(
        self,
        heads: tuple[str, ...] = (),
        remotes: tuple[str, ...] = (),
        tags: tuple[str, ...] = (),
        *,
        commit: bool = False,
    ) -> None:
        """Prepare a repository.

        Args:
            heads: Local branch names that exist.
            remotes: Branch names that exist on the remote.
            tags: Tag names that exist.
            commit: Whether an unmatched ref still resolves to a commit.

        """
        self.root = ROOT
        self.refs = (
            {f"refs/heads/{name}" for name in heads}
            | {f"refs/remotes/{REMOTE}/{name}" for name in remotes}
            | {f"refs/tags/{name}" for name in tags}
        )
        self.commit = commit
        self.calls: list[tuple[str, ...]] = []
        self.fetched = 0
        self.registered: dict[Path, str | None] = {}

    def has_ref(self, ref: str) -> bool:
        """Answer whether a fully qualified ref exists.

        Args:
            ref: The ref, as ``refs/...``.

        Returns:
            True when the fixtures name it.

        """
        return ref in self.refs

    def git(self, *argv: str, stream: bool = False) -> str:
        """Record a git invocation and answer like the fixtures say.

        Args:
            argv: The arguments after ``git``.
            stream: Accepted and ignored, to match the real signature.

        Returns:
            ``SHORT`` for a short rev-parse, the empty string otherwise.

        Raises:
            GitWtError: For a commit probe when the fixtures hold no commit.

        """
        del stream
        self.calls.append(argv)
        if argv[:2] == ("rev-parse", "--short"):
            return SHORT
        if argv[:3] == ("rev-parse", "--verify", "--quiet") and not self.commit:
            message = "not a commit"
            raise GitWtError(message)
        return ""

    def fetch(self) -> None:
        """Count a fetch instead of touching any network."""
        self.fetched += 1

    @staticmethod
    def default_branch() -> str:
        """Name the default branch.

        Returns:
            Always ``main``; the tests need one stable answer.

        """
        return "main"

    def worktrees(self) -> dict[Path, str | None]:
        """List the registered worktrees.

        Returns:
            The fixture mapping of resolved path to branch name.

        """
        return self.registered


# --- Folder names -------------------------------------------------------------


def test_folder_name_flattens_slashes() -> None:
    """A ref with slashes and spaces becomes one dash-separated folder."""
    assert Plan._folder_name("feature/foo bar") == "feature-foo-bar"


def test_folder_name_keeps_words_dots_dashes() -> None:
    """Word characters, dots and dashes pass through untouched."""
    assert Plan._folder_name("v1.2-rc.1") == "v1.2-rc.1"


def test_folder_name_strips_leading_dots_and_dashes() -> None:
    """A name cannot begin or end with the characters a shell trips over."""
    assert Plan._folder_name("--weird..") == "weird"


def test_folder_name_refuses_nothing() -> None:
    """A ref that sanitises to nothing is an error, not an empty folder."""
    assert "cannot derive" in _message(lambda: Plan._folder_name("///"))


# --- What each kind of ref plans ----------------------------------------------


def test_plan_local_branch() -> None:
    """A local branch is checked out plainly: path and ref, no flags."""
    plan = Plan.from_repo(FakeRepo(heads=("dev",)), "dev", RefKind.LOCAL_BRANCH)
    assert plan.path == ROOT / "dev"
    assert plan.argv == (str(ROOT / "dev"), "dev")


def test_plan_remote_branch_tracks() -> None:
    """A branch that exists only on the remote is created tracking it."""
    plan = Plan.from_repo(FakeRepo(remotes=("dev",)), "dev", RefKind.REMOTE_BRANCH)
    assert plan.argv == ("--track", "-b", "dev", str(ROOT / "dev"), f"{REMOTE}/dev")


def test_plan_tag_detaches() -> None:
    """A tag is checked out detached, never as a branch."""
    plan = Plan.from_repo(FakeRepo(tags=("v1.0",)), "v1.0", RefKind.TAG)
    assert plan.argv == ("--detach", str(ROOT / "v1.0"), "v1.0")


def test_plan_commit_shortens_and_detaches() -> None:
    """A commit is shortened for the folder name and checked out detached."""
    plan = Plan.from_repo(FakeRepo(commit=True), "HEAD~2", RefKind.COMMIT)
    assert plan.path == ROOT / SHORT
    assert plan.argv == ("--detach", str(ROOT / SHORT), SHORT)


def test_plan_new_branch_has_no_upstream() -> None:
    """A new branch forks off the default branch with --no-track.

    Without it, git makes the start point the upstream, whose name differs
    from the branch's, and the first push is refused.
    """
    plan = Plan.from_repo(FakeRepo(), "topic", RefKind.UNKNOWN)
    assert plan.argv == ("--no-track", "-b", "topic", str(ROOT / "topic"), f"{REMOTE}/main")


# --- What a user-typed ref resolves to ----------------------------------------


def test_resolve_prefers_local_branch() -> None:
    """A name that is a local branch resolves as one, whatever else matches."""
    repo = FakeRepo(heads=("dev",), remotes=("dev",), tags=("dev",))
    assert RefKind.resolve(repo, "dev") is RefKind.LOCAL_BRANCH


def test_resolve_remote_then_tag_then_commit() -> None:
    """The remaining kinds resolve in remote, tag, commit order."""
    assert RefKind.resolve(FakeRepo(remotes=("dev",)), "dev") is RefKind.REMOTE_BRANCH
    assert RefKind.resolve(FakeRepo(tags=("v1",)), "v1") is RefKind.TAG
    assert RefKind.resolve(FakeRepo(commit=True), "abc") is RefKind.COMMIT


def test_resolve_unknown() -> None:
    """A name matching nothing is UNKNOWN, which is what plans a new branch."""
    assert RefKind.resolve(FakeRepo(), "typo") is RefKind.UNKNOWN


# --- Creating, confirming, and reusing ----------------------------------------


def test_add_fetches_once_for_unknown_ref() -> None:
    """An unfamiliar ref costs exactly one fetch before it becomes a branch."""
    repo = FakeRepo()
    worktree = Worktree.add_worktree(repo, "topic")
    assert repo.fetched == 1
    assert worktree.kind is RefKind.UNKNOWN
    assert repo.calls[-1][:2] == ("worktree", "add")


def test_add_known_ref_does_not_fetch() -> None:
    """A ref that already resolves pays for no network."""
    repo = FakeRepo(heads=("dev",))
    Worktree.add_worktree(repo, "dev")
    assert repo.fetched == 0


def test_add_declined_new_branch_creates_nothing() -> None:
    """When confirm_new says no, no branch and no folder appear."""
    repo = FakeRepo()
    declined = _message(
        lambda: Worktree.add_worktree(repo, "typo", confirm_new=lambda _default: False),
    )
    assert "matches no branch" in declined
    assert all(call[:2] != ("worktree", "add") for call in repo.calls)


def test_add_confirmed_new_branch_is_created() -> None:
    """When confirm_new says yes, the new-branch plan runs as before."""
    repo = FakeRepo()
    Worktree.add_worktree(repo, "topic", confirm_new=lambda _default: True)
    assert repo.calls[-1][:2] == ("worktree", "add")


def test_reuse_same_branch() -> None:
    """A folder already holding the asked-for branch is accepted, not an error."""
    repo = FakeRepo(heads=("dev",))
    repo.registered = {(ROOT / "dev").resolve(): "dev"}
    plan = Plan.from_repo(repo, "dev", RefKind.LOCAL_BRANCH)
    worktree = Worktree._reuse(repo, plan, "dev")
    assert worktree.summary == "already checked out"


def test_reuse_other_branch_refuses() -> None:
    """A folder holding a different branch is named, not silently reused."""
    repo = FakeRepo(heads=("dev",))
    repo.registered = {(ROOT / "dev").resolve(): "other"}
    plan = Plan.from_repo(repo, "dev", RefKind.LOCAL_BRANCH)
    assert "other" in _message(lambda: Worktree._reuse(repo, plan, "dev"))


def test_reuse_non_worktree_refuses() -> None:
    """A folder git does not register as a worktree is never adopted."""
    repo = FakeRepo(heads=("dev",))
    plan = Plan.from_repo(repo, "dev", RefKind.LOCAL_BRANCH)
    assert "not a worktree" in _message(lambda: Worktree._reuse(repo, plan, "dev"))


def _run(name: str, test: object) -> bool:
    """Run one test, printing its outcome.

    Args:
        name: The test's name.
        test: The test callable.

    Returns:
        True when it passed.

    """
    try:
        test()  # type: ignore[operator]
    except Exception:  # ruff: ignore[blind-except] - any failure is a failed test, not a crash
        print(f"FAIL  {name}")
        indented = traceback.format_exc().splitlines()
        print("".join(f"      {line}\n" for line in indented), end="")
        return False
    print(f"ok    {name}")
    return True


def main() -> int:
    """Run every test in this file, in the order it defines them.

    Returns:
        Process exit code: 0 if every test passed, otherwise 1.

    """
    tests = [
        (name, value)
        for name, value in globals().items()
        if name.startswith("test_") and callable(value)
    ]
    passed = sum(starmap(_run, tests))
    print(f"\n{passed}/{len(tests)} passed")
    return 0 if passed == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
