"""The bare-clone-plus-worktrees layout, and the git operations over it."""

from __future__ import annotations

import re
import shutil
from dataclasses import dataclass
from pathlib import Path

from gitwt_git import BARE_DIR, FETCH_REFSPEC, POINTER_TEXT, REMOTE, GitWtError, git


@dataclass(frozen=True)
class Repo:
    """A repository in the bare-clone-plus-worktrees layout."""

    root: Path

    @property
    def bare(self) -> Path:
        """The bare clone that backs every worktree.

        Returns:
            The path to the ``.bare`` directory.

        """
        return self.root / BARE_DIR

    @staticmethod
    def repo_name(url: str) -> str:
        """Derive the destination directory from a clone URL.

        Args:
            url: The clone URL.

        Returns:
            The repository's bare name, without any ``.git`` suffix.

        Raises:
            GitWtError: If no usable name can be derived.

        """
        # Split on ":" as well as "/" so scp-style git@host:owner/repo.git works.
        tail = re.split(r"[/:]", url.rstrip("/"))[-1]
        name = tail.removesuffix(".git")
        if not name or name in {".", ".."}:
            msg = f"cannot derive a directory name from {url!r}"
            raise GitWtError(msg)
        return name

    @classmethod
    def discover(cls, start: Path) -> Repo:
        """Find the layout root from anywhere inside it.

        Args:
            start: The directory to search from, normally the current one.

        Returns:
            The repository that ``start`` belongs to.

        Raises:
            GitWtError: If ``start`` is not inside a git repository, or is inside
                one that does not use this layout.

        """
        try:
            common = Path(git("rev-parse", "--git-common-dir", cwd=start))
        except GitWtError as exc:
            msg = f"not inside a git repository: {start}"
            raise GitWtError(msg) from exc

        if not common.is_absolute():
            common = (start / common).resolve()

        if common.name != BARE_DIR:
            msg = (
                f"{common.parent} is a plain git repository, not a {BARE_DIR} layout; "
                f"re-clone it with git-wt-clone to use worktrees this way"
            )
            raise GitWtError(msg)

        return cls(common.parent)

    @classmethod
    def create(cls, url: str, dest: Path) -> Repo:
        """Clone ``url`` into a fresh bare-clone-plus-worktrees layout.

        Args:
            url: The ssh or https clone URL.
            dest: The directory to build the layout in.

        Returns:
            The new repository, with its remote-tracking refs already fetched.

        Raises:
            GitWtError: If ``dest`` already exists and is not empty.

        """
        if dest.exists() and any(dest.iterdir()):
            msg = f"{dest} already exists and is not empty"
            raise GitWtError(msg)

        existed = dest.exists()
        dest.mkdir(parents=True, exist_ok=True)
        repo = cls(dest.resolve())

        try:
            repo._build(url)
        except GitWtError:
            repo._discard(keep_root=existed)
            raise

        return repo

    def _build(self, url: str) -> None:
        """Populate an empty layout root from a remote.

        Args:
            url: The ssh or https clone URL.

        """
        # Deliberately not "git clone --bare": that materialises every remote
        # head as a *local* branch, so later worktrees would check out branches
        # that track nothing. Init-and-fetch leaves only remote-tracking refs,
        # and a local branch appears exactly when a worktree asks for one.
        git("init", "--bare", "--quiet", str(self.bare))
        (self.root / ".git").write_text(POINTER_TEXT, encoding="utf-8")
        self.git("remote", "add", REMOTE, url)
        self.git("config", f"remote.{REMOTE}.fetch", FETCH_REFSPEC)
        self.fetch()
        self.git("remote", "set-head", REMOTE, "--auto")

    def _discard(self, *, keep_root: bool) -> None:
        """Delete an incomplete clone, so the next attempt is not blocked.

        Args:
            keep_root: Whether the root directory was already there beforehand
                and must therefore survive.

        """
        shutil.rmtree(self.bare if keep_root else self.root, ignore_errors=True)
        (self.root / ".git").unlink(missing_ok=True)

    def git(self, *args: str, stream: bool = False) -> str:
        """Run a git command inside this repository.

        Args:
            args: Arguments passed to ``git``.
            stream: Whether to let git write straight to the terminal.

        Returns:
            Git's stripped stdout, or the empty string when streaming.

        """
        return git(*args, cwd=self.root, stream=stream)

    def fetch(self) -> None:
        """Update every remote-tracking ref and tag, pruning the ones that are gone."""
        self.git("fetch", "--all", "--prune", "--tags", stream=True)

    def default_branch(self) -> str:
        """Determine the branch the remote considers its default.

        Returns:
            The branch name, for example ``main``.

        """
        # origin/HEAD only exists once `remote set-head` has run. _build does that
        # on every clone made here, but a bare repository created another way, or
        # one whose remote was empty at clone time, has no such ref -- fall back to
        # whatever HEAD points at locally.
        try:
            head = self.git("rev-parse", "--abbrev-ref", f"{REMOTE}/HEAD")
        except GitWtError:
            return self.git("symbolic-ref", "--short", "HEAD")
        return head[len(REMOTE) + 1 :]

    def has_ref(self, ref: str) -> bool:
        """Report whether a fully qualified ref exists.

        Args:
            ref: A full ref name such as ``refs/heads/main``.

        Returns:
            True if the ref resolves.

        """
        try:
            self.git("show-ref", "--verify", "--quiet", ref)
        except GitWtError:
            return False
        return True

    def worktrees(self) -> dict[Path, str | None]:
        """List the worktrees git has registered.

        Returns:
            Each worktree's resolved path, mapped to the branch checked out
            there or to ``None`` when that worktree is detached.

        """
        found: dict[Path, str | None] = {}
        current: Path | None = None

        for line in self.git("worktree", "list", "--porcelain").splitlines():
            if line.startswith("worktree "):
                current = Path(line[len("worktree ") :]).resolve()
                found[current] = None
            elif line.startswith("branch ") and current is not None:
                found[current] = line[len("branch ") :].replace("refs/heads/", "", 1)

        return found
