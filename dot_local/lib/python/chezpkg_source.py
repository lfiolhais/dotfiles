"""Where the two package files live."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from chezpkg_run import PackagesError, run


@dataclass(frozen=True)
class Source:
    """The chezmoi source directory holding the Brewfile and the manifest."""

    root: Path

    @classmethod
    def discover(cls) -> Source:
        """Ask chezmoi where its source directory is.

        Asked of chezmoi rather than derived from ``__file__``: this library is
        deployed to ``~/.local/lib``, which says nothing about where the source
        it edits lives.

        Returns:
            The source directory.

        Raises:
            PackagesError: If chezmoi is absent or reports no source directory.

        """
        try:
            found = run("chezmoi", "source-path")
        except PackagesError as exc:
            message = f"cannot find the chezmoi source directory: {exc}"
            raise PackagesError(message) from exc

        if not found:
            message = "chezmoi reported no source directory"
            raise PackagesError(message)

        return cls(Path(found))

    @property
    def manifest(self) -> Path:
        """The per-distro Linux package manifest.

        Returns:
            The path to ``.chezmoidata/packages.toml``.

        """
        return self.root / ".chezmoidata" / "packages.toml"

    @property
    def brewfile(self) -> Path:
        """The Brewfile listing what macOS installs.

        Returns:
            The path to ``private_dot_config/Brewfile``.

        """
        return self.root / "private_dot_config" / "Brewfile"

    def name(self, path: Path) -> str:
        """Shorten a path for a message.

        Args:
            path: A path inside the source directory.

        Returns:
            The path relative to the source directory, or unchanged if it lies
            outside.

        """
        try:
            return str(path.relative_to(self.root))
        except ValueError:
            return str(path)
