"""The Brewfile: what this Mac has, in Homebrew's own words.

The Brewfile is *derived* state. ``brew bundle dump`` writes it from what is
installed -- descriptions, taps, casks, Mac App Store apps and uv tools included
-- so nothing here ever edits it by hand; :meth:`Brewfile.refresh` re-dumps it
whole. Reading it is a different matter: it is Ruby, not a data format, and the
only thing anyone needs from it is which package each line declares.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from itertools import starmap
from pathlib import Path

from chezpkg_run import PackagesError, run

# One entry per line: the keyword, then the package name in double quotes.
# Anything after the name (`, trusted: true`, `, id: 1440147259`) is Homebrew's
# business, not ours.
ENTRY = re.compile(r'^(brew|cask|uv|mas|tap|vscode)\s+"([^"]+)"', re.MULTILINE)
# The kinds that put a command on the Mac, and so must be accounted for in the
# Linux manifest. A tap is where formulae come from rather than a package; casks,
# Mac App Store apps and editor extensions are macOS GUI software, which the
# Linux profiles do not attempt to mirror.
ACCOUNTABLE = frozenset({"brew", "uv"})
# How to remove each kind. `mas` has no uninstall verb and a tap is not
# installed software, so neither appears here.
UNINSTALL = {
    "brew": ("brew", "uninstall"),
    "cask": ("brew", "uninstall"),
    "uv": ("uv", "tool", "uninstall"),
}


@dataclass(frozen=True)
class Entry:
    """One line of a Brewfile: the keyword that installs it, and the name."""

    kind: str
    name: str

    def __str__(self) -> str:
        """Render the entry as the Brewfile line it was parsed from.

        Returns:
            The line, such as ``brew "ripgrep"``.

        """
        return f'{self.kind} "{self.name}"'


@dataclass(frozen=True)
class Brewfile:
    """A snapshot of the Brewfile, as it was on disk."""

    path: Path
    text: str
    entries: tuple[Entry, ...]

    @staticmethod
    def parse(text: str) -> tuple[Entry, ...]:
        """Read every package line of a Brewfile.

        Args:
            text: The whole Brewfile.

        Returns:
            One entry per declaration, in file order.

        """
        return tuple(starmap(Entry, ENTRY.findall(text)))

    @classmethod
    def read(cls, path: Path) -> Brewfile:
        """Read the Brewfile from disk.

        Args:
            path: The Brewfile's path.

        Returns:
            The snapshot.

        Raises:
            PackagesError: If the file cannot be read.

        """
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            message = f"cannot read {path}: {exc}"
            raise PackagesError(message) from exc

        return cls(path, text, cls.parse(text))

    @classmethod
    def refresh(cls, path: Path) -> Brewfile:
        """Rewrite the Brewfile from what this machine has installed.

        Piped through stdout rather than written with ``--force``, so a failed or
        empty dump cannot truncate the tracked file.

        Args:
            path: The Brewfile's path.

        Returns:
            The new snapshot, already written to ``path``.

        Raises:
            PackagesError: If Homebrew is absent or the dump produced nothing.

        """
        dumped = run("brew", "bundle", "dump", "--file=-")
        if not dumped.strip():
            message = "brew bundle dump produced nothing; leaving the Brewfile alone"
            raise PackagesError(message)

        text = dumped + "\n"
        path.write_text(text, encoding="utf-8")

        return cls(path, text, cls.parse(text))

    @staticmethod
    def install(formula: str) -> None:
        """Install a formula with Homebrew.

        A failed install raises, which is what stops ``add`` from recording a
        package this Mac does not have.

        Args:
            formula: The formula name, tap-qualified if it needs to be.

        """
        run("brew", "install", formula, stream=True)

    @staticmethod
    def uninstall(entries: tuple[Entry, ...]) -> tuple[str, ...]:
        """Remove a package by every route that installed it.

        Args:
            entries: The Brewfile entries naming one package -- a formula and a
                uv tool of the same name are two entries, and both have to go.

        A failed uninstall raises, which is what stops ``remove`` from dropping
        an entry for something still installed.

        Returns:
            One description per uninstall that ran, empty when nothing could be.

        """
        done = []
        for entry in entries:
            argv = UNINSTALL.get(entry.kind)
            if argv is None:
                continue
            run(*argv, entry.name, stream=True)
            done.append(f"{' '.join(argv)} {entry.name}")

        return tuple(done)

    @property
    def accountable(self) -> frozenset[str]:
        """The names the Linux manifest has to account for.

        Returns:
            Every ``brew`` and ``uv`` name in the file.

        """
        return frozenset(e.name for e in self.entries if e.kind in ACCOUNTABLE)

    def declaring(self, name: str) -> tuple[Entry, ...]:
        """Find every line that declares a package.

        Args:
            name: The package name as the Brewfile spells it.

        Returns:
            Its entries, empty when the Brewfile does not declare it.

        """
        return tuple(entry for entry in self.entries if entry.name == name)
