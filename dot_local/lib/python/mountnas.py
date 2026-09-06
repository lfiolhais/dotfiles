"""Mount the NAS while it is reachable, and say nothing while it is not.

The share is wanted whenever the network makes it possible and never otherwise,
which on macOS is less about mounting than about staying quiet. Three separate
things raise a dialog, and each needs its own guard:

- mounting a server that is not there produces a connection-failed alert, so
  nothing is attempted until TCP 445 answers. Testing the port rather than the
  network name means Ethernet and VPN count as being home, just as Wi-Fi does;
- ``mount volume`` raises an authentication sheet when the login Keychain holds
  no password for the server, so the Keychain is consulted first and a missing
  entry is a reason to do nothing rather than a reason to ask;
- a mount whose server has vanished produces interrupted-connection alerts
  until it is cleared, so an unreachable NAS that is still mounted is unmounted.

``mount volume`` is the AppleScript route rather than ``mount_smbfs`` because it
reads the login Keychain and mounts under ``/Volumes`` the way Finder does, so
the share behaves normally in the sidebar.

Every command is named by absolute path. launchd hands a job a bare ``PATH``
that has none of these directories in it.
"""

from __future__ import annotations

import socket
from dataclasses import dataclass
from pathlib import Path

from chezpkg_run import PackagesError, run

HOST = "nas.botasal.xyz"
USER = "lfiolhais"
# SMB. Answering here is the whole definition of "the NAS is reachable".
PORT = 445
# Long enough for a NAS on the far side of a VPN, short enough that a login with
# no network behind it is not held up.
TIMEOUT = 2.0
# Seconds for the commands themselves. A mount negotiates and authenticates, so
# it is given longer than the ones that only read or tear down state.
MOUNT_TIMEOUT = 60
COMMAND_TIMEOUT = 30

MOUNT = "/sbin/mount"
UMOUNT = "/sbin/umount"
DISKUTIL = "/usr/sbin/diskutil"
OSASCRIPT = "/usr/bin/osascript"
SECURITY = "/usr/bin/security"

# What a pass over a share decided. `AWAY` and `NO_PASSWORD` are the two silent
# outcomes: both mean the share cannot be mounted right now for a reason that is
# not a fault, so neither prints anything outside `status`.
AWAY = "away"
PRESENT = "present"
MOUNTED = "mounted"
UNMOUNTED = "unmounted"
NO_PASSWORD = "no-password"


class NasError(PackagesError):
    """A failure to report to the user as a message, without a traceback."""


@dataclass(frozen=True)
class Outcome:
    """What one pass over one share decided, and what it ran to get there."""

    share: Share
    action: str
    argv: tuple[str, ...] = ()
    error: str = ""

    @property
    def ok(self) -> bool:
        """Whether the pass did what it set out to do.

        Returns:
            True if nothing failed.

        """
        return not self.error


@dataclass(frozen=True)
class Share:
    """One SMB share on one server."""

    host: str
    user: str
    name: str

    @property
    def url(self) -> str:
        """The URL ``mount volume`` takes.

        Returns:
            An ``smb://`` URL naming the user, the server and the share.

        """
        return f"smb://{self.user}@{self.host}/{self.name}"

    @property
    def source(self) -> str:
        """The device column ``mount(8)`` prints for this share.

        Returns:
            The ``//user@host/share`` form macOS reports for an SMB mount.

        """
        return f"//{self.user}@{self.host}/{self.name}"

    def reachable(self, timeout: float = TIMEOUT) -> bool:
        """Report whether the server answers on the SMB port.

        The socket is opened directly, consulting no proxy settings: what is
        being asked is whether *this machine* can reach the NAS, which is the
        only thing that decides whether a mount can succeed.

        Args:
            timeout: Seconds to wait for the connection.

        Returns:
            True if the port accepted a connection. A name that does not
            resolve raises ``socket.gaierror``, itself an ``OSError``, so being
            away from the network is answered the same way as a refused port.

        """
        try:
            with socket.create_connection((self.host, PORT), timeout):
                return True
        except OSError:
            return False

    def mountpoint(self, table: str) -> str | None:
        """Find where this share is currently mounted.

        The device column is matched rather than a path, because a leftover
        directory named after the share makes macOS mount at ``/Volumes/Book2-1``
        instead, and a check that only looked at ``/Volumes/Book2`` would mount a
        second copy on every pass. A mount Finder made by IP has a device column
        that matches nothing, so it is recognised by its path instead.

        Args:
            table: The output of ``mount(8)``.

        Returns:
            The mountpoint, or None if the share is not mounted.

        """
        entries = _entries(table)
        for source, path, _ in entries:
            if source.lower() == self.source.lower():
                return path
        for _, path, options in entries:
            if Path(path).name == self.name and "smbfs" in options:
                return path
        return None

    def has_password(self) -> bool:
        """Report whether the login Keychain holds a password for this server.

        The password itself is never asked for: reading it raises a Keychain
        access sheet, while asking whether the item exists does not.

        Returns:
            True if an internet password for this server and account exists.

        """
        try:
            run(
                SECURITY,
                "find-internet-password",
                "-s",
                self.host,
                "-a",
                self.user,
                timeout=COMMAND_TIMEOUT,
            )
        except PackagesError:
            return False
        return True


SHARES = (Share(HOST, USER, "Book2"),)


def _entries(table: str) -> list[tuple[str, str, str]]:
    """Split ``mount(8)`` output into its columns.

    Args:
        table: The output of ``mount(8)``.

    Returns:
        One ``(device, mountpoint, options)`` triple per line it could parse.

    """
    entries = []
    for line in table.splitlines():
        source, on, rest = line.partition(" on ")
        mountpoint, opened, options = rest.rpartition(" (")
        if on and opened:
            entries.append((source, mountpoint, options.rstrip(")")))
    return entries


def table() -> str:
    """Read the mount table.

    Returns:
        The output of ``mount(8)``.

    Raises:
        NasError: If the mount table cannot be read.

    """
    try:
        return run(MOUNT, timeout=COMMAND_TIMEOUT)
    except PackagesError as exc:
        message = f"cannot read the mount table: {exc}"
        raise NasError(message) from exc


def mount(share: Share, *, dry_run: bool = False) -> Outcome:
    """Mount a share.

    Args:
        share: The share to mount.
        dry_run: Report the command without running it.

    Returns:
        The outcome, carrying the reason when the mount failed.

    """
    argv = (OSASCRIPT, "-e", f'mount volume "{share.url}"')
    if dry_run:
        return Outcome(share, MOUNTED, argv)
    try:
        run(*argv, timeout=MOUNT_TIMEOUT)
    except PackagesError as exc:
        return Outcome(share, MOUNTED, argv, str(exc))
    return Outcome(share, MOUNTED, argv)


def unmount(share: Share, path: str, *, dry_run: bool = False) -> Outcome:
    """Unmount a share, forcibly.

    ``sync()`` reaches here only for a share whose server has stopped answering,
    where an open file could not be written back whatever happened and leaving
    the mount in place is what produces the interrupted-connection alerts. The
    ``unmount`` command calls it directly, so it will also force a live share
    down, discarding unwritten data. ``diskutil`` is the fallback because it also
    tells Finder the volume went away.

    Args:
        share: The share being unmounted.
        path: Where it is mounted.
        dry_run: Report the command without running it.

    Returns:
        The outcome, carrying the reason when both attempts failed.

    """
    argv = (UMOUNT, "-f", path)
    if dry_run:
        return Outcome(share, UNMOUNTED, argv)
    try:
        run(*argv, timeout=COMMAND_TIMEOUT)
    except PackagesError:
        fallback = (DISKUTIL, "unmount", "force", path)
        try:
            run(*fallback, timeout=COMMAND_TIMEOUT)
        except PackagesError as exc:
            return Outcome(share, UNMOUNTED, fallback, str(exc))
        return Outcome(share, UNMOUNTED, fallback)
    return Outcome(share, UNMOUNTED, argv)


def sync(shares: tuple[Share, ...] = SHARES, *, dry_run: bool = False) -> list[Outcome]:
    """Bring every share into line with what the network currently allows.

    The mount table is read once, so every share is decided against the same
    snapshot. A mount table that cannot be read raises ``NasError`` out of
    ``table()``, since nothing below can be decided without it.

    Args:
        shares: The shares to consider.
        dry_run: Report the commands without running them.

    Returns:
        One outcome per share, in the order given.

    """
    snapshot = table()
    outcomes = []
    for share in shares:
        path = share.mountpoint(snapshot)
        if not share.reachable():
            outcomes.append(
                Outcome(share, AWAY) if path is None else unmount(share, path, dry_run=dry_run),
            )
        elif path is not None:
            outcomes.append(Outcome(share, PRESENT))
        elif not share.has_password():
            outcomes.append(Outcome(share, NO_PASSWORD))
        else:
            outcomes.append(mount(share, dry_run=dry_run))
    return outcomes


__all__ = [
    "AWAY",
    "MOUNTED",
    "NO_PASSWORD",
    "PRESENT",
    "SHARES",
    "UNMOUNTED",
    "NasError",
    "Outcome",
    "PackagesError",
    "Share",
    "mount",
    "sync",
    "table",
    "unmount",
]
