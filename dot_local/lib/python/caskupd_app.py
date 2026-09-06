"""What Homebrew installed, and what would update it behind Homebrew's back.

Every app considered here came from a cask, which is what makes it fair game:
Homebrew knows its version and can move it. Apps installed by hand are never
looked at, because nothing else would update them.

Discovery is the whole point of this module. There is no list of apps to keep
current -- the set is whatever ``brew list --cask`` says today, and whether an
app can be silenced is read out of its own bundle rather than remembered here.
"""

from __future__ import annotations

import json
import plistlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from xml.parsers.expat import ExpatError

from chezpkg_run import PackagesError, maybe, run

# Where a cask puts its app when the artifact does not resolve a target itself.
APPDIR = Path("/Applications")
# Info.plist keys only a Sparkle-equipped bundle carries. Some apps set the feed
# in code and carry none of them, which is what the framework check below is for.
SPARKLE_KEYS = ("SUFeedURL", "SUPublicEDKey", "SUPublicDSAKeyFile")
# Sparkle 2 bundles its XPC services inside the framework, so an app that links
# it has the framework on disk even when nothing appears in Info.plist.
SPARKLE_FRAMEWORK = Path("Contents", "Frameworks", "Sparkle.framework")

# Apps deliberately left to update themselves, and why. These ship security
# fixes on their own schedule, and the gap until the next `update` run is a real
# exposure for a firewall, a VPN, or a hardened browser. `cask-updates status`
# reports which of them embed Sparkle, and so which the exemption actually
# concedes; an app that embeds none would be unreachable regardless.
EXEMPT = {
    "adguard": "network filter, patches on its own schedule",
    "little-snitch": "host firewall",
    "proton-mail-bridge": "breaks mail when it drifts from the server",
    "protonvpn": "VPN client",
    "tor-browser": "security-critical browser",
}


@dataclass(frozen=True)
class App:
    """One application a cask put on this Mac."""

    token: str
    path: Path
    bundle_id: str
    sparkle: bool
    auto_updates: bool

    @property
    def exempt(self) -> bool:
        """Whether this app is deliberately left to update itself.

        Returns:
            True if its cask is named in :data:`EXEMPT`.

        """
        return self.token in EXEMPT

    @property
    def manageable(self) -> bool:
        """Whether Sparkle's preference keys can silence this app.

        Returns:
            True if it embeds Sparkle and is not exempt.

        """
        return self.sparkle and not self.exempt

    @property
    def beyond_reach(self) -> bool:
        """Whether this app self-updates through something with no lever.

        Returns:
            True if its cask declares ``auto_updates`` but it embeds no Sparkle
            and was not exempted on purpose.

        """
        return self.auto_updates and not self.sparkle and not self.exempt

    @classmethod
    def discover(cls) -> tuple[App, ...]:
        """Find every app Homebrew installed, and classify its updater.

        Returns:
            One entry per installed app bundle, ordered by cask token.

        Raises:
            PackagesError: If Homebrew is missing or answers with nonsense.

        """
        tokens = run("brew", "list", "--cask").split()
        if not tokens:
            return ()

        try:
            report = json.loads(run("brew", "info", "--json=v2", "--cask", *tokens))
        except json.JSONDecodeError as exc:
            message = f"brew info returned no usable JSON: {exc}"
            raise PackagesError(message) from exc

        found = [
            app
            for cask in report.get("casks", [])
            for path in cls._bundles(cask)
            if (app := cls._read(cask, path)) is not None
        ]
        return tuple(sorted(found, key=lambda app: (app.token, app.bundle_id)))

    @classmethod
    def running(cls, apps: tuple[App, ...]) -> frozenset[str]:
        """Report which of these apps are open right now.

        An app writes its own preferences on quit, which can overwrite a key set
        while it was running. Naming those apps lets the caller say the change
        may not stick, rather than reporting a clean sweep.

        Args:
            apps: The apps to look for.

        Returns:
            The cask tokens whose app has a running process.

        """
        processes = maybe("ps", "-Awwxo", "command=")
        return frozenset(app.token for app in apps if f"{app.path}/" in processes)

    @staticmethod
    def _bundles(cask: dict[str, Any]) -> list[Path]:
        """Work out where a cask's apps were installed.

        Args:
            cask: One cask as ``brew info --json=v2`` describes it.

        Returns:
            The app bundle paths the cask declares, resolved.

        """
        paths: list[Path] = []
        for artifact in cask.get("artifacts", []):
            if not isinstance(artifact, dict) or "app" not in artifact:
                continue
            target = artifact.get("target")
            if target:
                paths.append(Path(str(target)))
                continue
            paths.extend(APPDIR / str(name) for name in artifact["app"])
        return paths

    @classmethod
    def _read(cls, cask: dict[str, Any], path: Path) -> App | None:
        """Read one app bundle and say what updates it.

        Args:
            cask: The cask that installed it.
            path: The app bundle.

        Returns:
            The app, or None if it is not on disk or carries no bundle
            identifier to write preferences against.

        """
        plist = path / "Contents" / "Info.plist"
        if not plist.is_file():
            return None

        try:
            with plist.open("rb") as handle:
                info = plistlib.load(handle)
        except (OSError, ExpatError, plistlib.InvalidFileException):
            return None

        bundle_id = info.get("CFBundleIdentifier")
        if not bundle_id:
            return None

        return cls(
            token=str(cask.get("token", path.stem)),
            path=path,
            bundle_id=str(bundle_id),
            sparkle=any(key in info for key in SPARKLE_KEYS) or (path / SPARKLE_FRAMEWORK).is_dir(),
            auto_updates=bool(cask.get("auto_updates")),
        )
