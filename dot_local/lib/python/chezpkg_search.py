"""What every platform calls a tool.

Asking is the hard part of keeping the two package files in step: a tool exists
under one name on Homebrew, another on Fedora, and not at all on EPEL. This asks
each platform's real repositories -- the distributions in throwaway containers,
Homebrew and mise on this host -- and returns the answer rather than printing it.
"""

from __future__ import annotations

from dataclasses import dataclass

from chezpkg_run import maybe
from linux_distros import IMAGES, TARGET_OF

# Enough near-matches to spot a renamed package without flooding the terminal.
MAX_MATCHES = 8

# One shell line per distro family: refresh metadata quietly, then print only
# package names. repoquery/`--names-only` avoid parsing localised descriptions.
APT_SEARCH = "apt-get update -qq >/dev/null 2>&1; apt-cache search --names-only {q} | cut -d' ' -f1"
DNF_SEARCH = "dnf -q repoquery --qf '%{{name}}' '*{q}*' 2>/dev/null"
EPEL_SETUP = (
    "dnf install -y -q dnf-plugins-core epel-release >/dev/null 2>&1; "
    "dnf config-manager --set-enabled crb >/dev/null 2>&1 || "
    "dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true; "
)


def _ranked(names: list[str], query: str) -> tuple[str, ...]:
    """Order matches so an exact one comes first.

    Args:
        names: The names a platform returned.
        query: The name that was asked for.

    Returns:
        The names, deduplicated, exact match first and the rest alphabetical.

    """
    return tuple(sorted(set(names), key=lambda name: (name != query, name)))


@dataclass(frozen=True)
class Match:
    """What one platform returned for one query."""

    platform: str
    query: str
    names: tuple[str, ...]

    @property
    def exact(self) -> str | None:
        """The name that matches the query exactly.

        Returns:
            The query if the platform has it under that name, otherwise None.

        """
        return self.query if self.query in self.names else None

    @property
    def summary(self) -> str:
        """One line of matches, truncated.

        Returns:
            The first ``MAX_MATCHES`` names with a count when there are more,
            or ``-`` when the platform has nothing.

        """
        if not self.names:
            return "-"

        shown = ", ".join(self.names[:MAX_MATCHES])
        if len(self.names) <= MAX_MATCHES:
            return shown

        return f"{shown}, ... ({len(self.names)} total)"


@dataclass(frozen=True)
class Search:
    """What every platform returned for one query."""

    query: str
    matches: tuple[Match, ...]

    @classmethod
    def everywhere(cls, query: str) -> Search:
        """Ask every platform what it calls a tool.

        Args:
            query: The name to look for.

        Returns:
            One match per platform, in the order the manifest lists them.

        """
        found = [cls._brew(query)]
        for distro in IMAGES:
            target = TARGET_OF[distro]
            # rocky and alma are the same repositories; ask once.
            if not any(match.platform == target for match in found):
                found.append(cls._distro(distro, target, query))
        found.append(cls._mise(query))

        return cls(query, tuple(found))

    @staticmethod
    def _brew(query: str) -> Match:
        """Ask Homebrew on this host.

        Args:
            query: The name to look for.

        Returns:
            Homebrew's matches, empty if brew is absent.

        """
        names = [
            line.strip()
            for line in maybe("brew", "search", "--formula", query).splitlines()
            if line.strip() and not line.startswith("==>")
        ]

        return Match("brew", query, _ranked(names, query))

    @staticmethod
    def _distro(distro: str, target: str, query: str) -> Match:
        """Ask one distribution's real repositories, in a throwaway container.

        Args:
            distro: A key of ``linux_distros.IMAGES``.
            target: The manifest field that distro speaks for.
            query: The name to look for.

        Returns:
            That target's matches, empty if Docker is absent.

        """
        if distro == "ubuntu":
            script = APT_SEARCH.format(q=query)
        else:
            script = DNF_SEARCH.format(q=query)
            if distro in {"rocky", "alma"}:
                script = EPEL_SETUP + script

        found = maybe("docker", "run", "--rm", IMAGES[distro], "sh", "-c", script)

        return Match(target, query, _ranked(found.split(), query))

    @staticmethod
    def _mise(query: str) -> Match:
        """Ask mise on this host.

        Args:
            query: The name to look for.

        Returns:
            mise's registry matches, empty if mise is absent.

        """
        names = [
            line.split()[0]
            for line in maybe("mise", "registry").splitlines()
            if line.split() and query in line.split()[0]
        ]

        return Match("mise", query, _ranked(names, query))

    @property
    def exact(self) -> dict[str, str]:
        """The platforms that have the tool under exactly this name.

        Returns:
            Platform to name, in platform order.

        """
        return {m.platform: m.exact for m in self.matches if m.exact is not None}

    @property
    def empty(self) -> bool:
        """Whether no platform returned anything at all.

        Returns:
            True when there is nothing to report.

        """
        return not any(match.names for match in self.matches)

    @property
    def add_command(self) -> str:
        """The ``add`` that would record this tool.

        Returns:
            The command line, using only the exact matches.

        """
        flags = [f"--{p} {n}" for p, n in self.exact.items() if p != "brew"]
        if "brew" not in self.exact:
            # Nothing to install on macOS: a Linux-only tool needs no formula.
            flags.insert(0, "--no-brew")

        return " ".join(["chezmoi-packages add", self.query, *flags])
