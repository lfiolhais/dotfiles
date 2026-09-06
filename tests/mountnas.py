#!/usr/bin/env python3
"""Unit tests for the NAS mount logic.

Nothing real is touched: the mount table is a fixture string, the subprocess
runner is replaced by a recorder, and the socket that decides reachability is
replaced by one that answers however a test needs. No ``mount``, ``umount``,
``diskutil``, ``osascript`` or ``security`` is ever run, so this is safe on a
machine with the share mounted and away from home alike.

What is being asserted is mostly what does *not* happen. The command exists to
be silent away from home and to never raise a dialog, and both of those are
claims about commands that were not issued.

Usage::

    python3 tests/mountnas.py
"""

from __future__ import annotations

import socket
import sys
import traceback
from pathlib import Path
from unittest import mock

# The library is deployed rather than kept here, so it is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

from itertools import starmap

import mountnas
from mountnas import AWAY, MOUNTED, NO_PASSWORD, PRESENT, UNMOUNTED, PackagesError, Share

SHARE = Share("nas.botasal.xyz", "lfiolhais", "Book2")

# A mount table with nothing of ours in it: the boot volume and the usual maps.
BARE = """/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
devfs on /dev (devfs, local, nobrowse)
map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)"""

# The share mounted where it is expected.
AT_VOLUME = (
    BARE + "\n//lfiolhais@nas.botasal.xyz/Book2 on /Volumes/Book2 "
    "(smbfs, nodev, nosuid, mounted by lipe)"
)

# The same share, mounted beside a leftover directory of its own name, which is
# what macOS does rather than reusing the path.
AT_SUFFIXED = (
    BARE + "\n//lfiolhais@nas.botasal.xyz/Book2 on /Volumes/Book2-1 "
    "(smbfs, nodev, nosuid, mounted by lipe)"
)

# A mount Finder made by IP: the device column matches nothing this would write.
BY_ADDRESS = BARE + "\n//lfiolhais@10.0.0.4/Book2 on /Volumes/Book2 (smbfs, nodev, nosuid)"

# A different share from the same server, which must not be mistaken for ours.
OTHER_SHARE = (
    BARE + "\n//lfiolhais@nas.botasal.xyz/Backups on /Volumes/Backups (smbfs, nodev, nosuid)"
)


class Recorder:
    """Stands in for the subprocess runner, remembering what it was asked to run."""

    def __init__(self, table: str = BARE, *, password: bool = True, fails: str = "") -> None:
        """Prepare a runner.

        Args:
            table: What ``mount(8)`` should appear to print.
            password: Whether the Keychain should appear to hold a password.
            fails: A command whose invocation should raise, or "" for none.

        """
        self.table = table
        self.password = password
        self.fails = fails
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, *argv: str, timeout: int = 0) -> str:
        """Record a command and answer as the test configured it.

        Args:
            argv: The command and its arguments.
            timeout: Accepted and ignored, to match the real runner.

        Returns:
            The mount table for ``mount``, and the empty string otherwise.

        Raises:
            PackagesError: If this is the command the test wants to fail, or if
                the Keychain was configured to hold nothing.

        """
        del timeout
        self.calls.append(argv)
        if self.fails and self.fails == argv[0]:
            message = f"{argv[0]}: refused"
            raise PackagesError(message)
        if argv[0] == mountnas.MOUNT:
            return self.table
        if argv[0] == mountnas.SECURITY and not self.password:
            message = "security: The specified item could not be found in the keychain."
            raise PackagesError(message)
        return ""

    @property
    def ran(self) -> list[str]:
        """The programs that were run, in order.

        Returns:
            One entry per call, the program name only.

        """
        return [argv[0] for argv in self.calls]


def unreachable(failure: Exception) -> mock.MagicMock:
    """Replace the socket so that connecting fails.

    Args:
        failure: The error the socket should raise.

    Returns:
        A patch context manager for ``socket.create_connection``.

    """
    return mock.patch.object(mountnas.socket, "create_connection", side_effect=failure)


def pass_over(recorder: Recorder, *, answer: bool, dry_run: bool = False) -> mountnas.Outcome:
    """Run one sync over the single share, with the world stubbed out.

    Args:
        recorder: The runner to use.
        answer: Whether the NAS should appear to answer on the SMB port.
        dry_run: Whether to report commands rather than run them.

    Returns:
        The outcome for the share.

    """
    socket_patch = (
        mock.patch.object(mountnas.socket, "create_connection", mock.MagicMock())
        if answer
        else unreachable(socket.gaierror("nodename nor servname"))
    )
    with mock.patch.object(mountnas, "run", recorder), socket_patch:
        outcomes = mountnas.sync((SHARE,), dry_run=dry_run)
    assert len(outcomes) == 1
    return outcomes[0]


# --- How a share names itself, and finds itself in the mount table -----------


def test_url_and_source() -> None:
    """The mount URL and the device column are built from the same three parts."""
    assert SHARE.url == "smb://lfiolhais@nas.botasal.xyz/Book2"
    assert SHARE.source == "//lfiolhais@nas.botasal.xyz/Book2"


def test_not_mounted() -> None:
    """A table without the share reports no mountpoint."""
    assert SHARE.mountpoint(BARE) is None


def test_mounted_at_expected_path() -> None:
    """The ordinary case: the share is at /Volumes/<name>."""
    assert SHARE.mountpoint(AT_VOLUME) == "/Volumes/Book2"


def test_mounted_at_suffixed_path() -> None:
    """A share pushed to /Volumes/Book2-1 is still found.

    Matching on the path alone would miss this and mount a second copy on every
    pass, which is the failure this test exists for.
    """
    assert SHARE.mountpoint(AT_SUFFIXED) == "/Volumes/Book2-1"


def test_mounted_by_address() -> None:
    """A mount Finder made by IP is recognised by its path and filesystem."""
    assert SHARE.mountpoint(BY_ADDRESS) == "/Volumes/Book2"


def test_other_share_is_not_ours() -> None:
    """A different share on the same server is not mistaken for this one."""
    assert SHARE.mountpoint(OTHER_SHARE) is None


# --- What counts as the NAS answering ----------------------------------------


def test_failures_are_unreachable() -> None:
    """Every way a socket can fail means the same thing: not here."""
    for failure in (
        socket.gaierror("nodename nor servname"),
        TimeoutError("timed out"),
        ConnectionRefusedError("refused"),
        OSError("host is down"),
    ):
        with unreachable(failure):
            assert SHARE.reachable() is False


def test_connection_is_reachable() -> None:
    """A socket that opens means the NAS is there."""
    with mock.patch.object(mountnas.socket, "create_connection", mock.MagicMock()):
        assert SHARE.reachable() is True


# --- The states a pass can find, and what each one runs -----------------


def test_away_runs_nothing() -> None:
    """Unreachable and unmounted is the away case: read the table, stop.

    This is the whole point of the reachability check. Anything else here would
    be a command issued while off the network, which is what raises a dialog.
    """
    recorder = Recorder(BARE)
    outcome = pass_over(recorder, answer=False)
    assert outcome.action == AWAY
    assert outcome.ok
    assert recorder.ran == [mountnas.MOUNT]


def test_stale_mount_is_cleared() -> None:
    """Unreachable but still mounted: force the unmount.

    Leaving it is what produces the interrupted-connection alerts.
    """
    recorder = Recorder(AT_VOLUME)
    outcome = pass_over(recorder, answer=False)
    assert outcome.action == UNMOUNTED
    assert outcome.ok
    assert recorder.calls[-1] == (mountnas.UMOUNT, "-f", "/Volumes/Book2")


def test_stale_mount_falls_back_to_diskutil() -> None:
    """When umount refuses, diskutil is asked instead."""
    recorder = Recorder(AT_VOLUME, fails=mountnas.UMOUNT)
    outcome = pass_over(recorder, answer=False)
    assert outcome.action == UNMOUNTED
    assert outcome.ok
    assert recorder.calls[-1] == (mountnas.DISKUTIL, "unmount", "force", "/Volumes/Book2")


# --- Unmounting on request, which is not clearing a stale mount --------------


def test_requested_unmount_does_not_force() -> None:
    """An unmount asked for by a person is plain, not forced.

    A forced unmount of a server that still answers discards whatever has not
    been written back, which is exactly the data a plain unmount refuses to
    lose.
    """
    recorder = Recorder(AT_VOLUME)
    with mock.patch.object(mountnas, "run", recorder):
        outcome = mountnas.unmount(SHARE, "/Volumes/Book2")
    assert outcome.action == UNMOUNTED
    assert outcome.ok
    assert recorder.calls == [(mountnas.UMOUNT, "/Volumes/Book2")]


def test_requested_unmount_falls_back_without_forcing() -> None:
    """When a plain umount refuses, diskutil is asked -- also without force."""
    recorder = Recorder(AT_VOLUME, fails=mountnas.UMOUNT)
    with mock.patch.object(mountnas, "run", recorder):
        outcome = mountnas.unmount(SHARE, "/Volumes/Book2")
    assert outcome.action == UNMOUNTED
    assert recorder.calls[-1] == (mountnas.DISKUTIL, "unmount", "/Volumes/Book2")


def test_forced_unmount_is_forced_at_both_steps() -> None:
    """Asking for force forces both the umount and the diskutil fallback."""
    recorder = Recorder(AT_VOLUME, fails=mountnas.UMOUNT)
    with mock.patch.object(mountnas, "run", recorder):
        outcome = mountnas.unmount(SHARE, "/Volumes/Book2", force=True)
    assert outcome.action == UNMOUNTED
    assert recorder.calls[0] == (mountnas.UMOUNT, "-f", "/Volumes/Book2")
    assert recorder.calls[-1] == (mountnas.DISKUTIL, "unmount", "force", "/Volumes/Book2")


def test_flush_runs_sync() -> None:
    """The flush is one sync(8) over every volume, not a per-share command."""
    recorder = Recorder(AT_VOLUME)
    with mock.patch.object(mountnas, "run", recorder):
        argv = mountnas.flush()
    assert argv == (mountnas.SYNC,)
    assert recorder.calls == [(mountnas.SYNC,)]


def test_dry_run_flush_runs_nothing() -> None:
    """A dry-run flush names sync without running it."""
    recorder = Recorder(AT_VOLUME)
    with mock.patch.object(mountnas, "run", recorder):
        argv = mountnas.flush(dry_run=True)
    assert argv == (mountnas.SYNC,)
    assert recorder.calls == []


def test_already_mounted_runs_nothing() -> None:
    """Reachable and mounted: there is nothing to do."""
    recorder = Recorder(AT_VOLUME)
    outcome = pass_over(recorder, answer=True)
    assert outcome.action == PRESENT
    assert outcome.ok
    assert recorder.ran == [mountnas.MOUNT]


def test_missing_password_never_reaches_osascript() -> None:
    """Reachable, unmounted, no Keychain entry: stop before the dialog.

    ``mount volume`` with no stored password raises an authentication sheet, so
    the Keychain is asked first and a missing entry ends the pass.
    """
    recorder = Recorder(BARE, password=False)
    outcome = pass_over(recorder, answer=True)
    assert outcome.action == NO_PASSWORD
    assert outcome.ok
    assert mountnas.OSASCRIPT not in recorder.ran
    assert recorder.ran == [mountnas.MOUNT, mountnas.SECURITY]


def test_mounts_when_everything_is_in_place() -> None:
    """Reachable, unmounted, password stored: mount it."""
    recorder = Recorder(BARE)
    outcome = pass_over(recorder, answer=True)
    assert outcome.action == MOUNTED
    assert outcome.ok
    assert recorder.calls[-1] == (
        mountnas.OSASCRIPT,
        "-e",
        'mount volume "smb://lfiolhais@nas.botasal.xyz/Book2"',
    )


def test_failed_mount_is_reported() -> None:
    """A mount that fails carries its reason rather than raising."""
    recorder = Recorder(BARE, fails=mountnas.OSASCRIPT)
    outcome = pass_over(recorder, answer=True)
    assert outcome.action == MOUNTED
    assert not outcome.ok
    assert "refused" in outcome.error


# --- A dry run reports the command and issues none ---------------------------


def test_dry_run_mount_is_only_described() -> None:
    """The mount case names osascript without running it."""
    recorder = Recorder(BARE)
    outcome = pass_over(recorder, answer=True, dry_run=True)
    assert outcome.argv[0] == mountnas.OSASCRIPT
    assert recorder.ran == [mountnas.MOUNT, mountnas.SECURITY]


def test_dry_run_unmount_is_only_described() -> None:
    """The unmount case names umount without running it."""
    recorder = Recorder(AT_VOLUME)
    outcome = pass_over(recorder, answer=False, dry_run=True)
    assert outcome.argv == (mountnas.UMOUNT, "-f", "/Volumes/Book2")
    assert recorder.ran == [mountnas.MOUNT]


def _run(name: str, test: object) -> bool:
    """Run one test and report it.

    Args:
        name: The test's name.
        test: The test function.

    Returns:
        True if it passed.

    """
    try:
        test()
    except Exception:  # ruff: ignore[blind-except] - any failure is a failed test, not a crash
        print(f"FAIL  {name}")
        indented = traceback.format_exc().splitlines(keepends=True)
        print("".join(f"      {line}" for line in indented))
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
