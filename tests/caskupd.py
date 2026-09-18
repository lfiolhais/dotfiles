#!/usr/bin/env python3
"""Unit tests for the cask-updates classification logic.

Nothing real is touched: the cask documents are fixture dicts, the app bundles
are built in a temporary directory, and the subprocess runner is replaced where
a test needs an answer. No ``brew``, ``defaults`` or ``ps`` is ever run.

What is being asserted is the sorting: which apps count as silenceable, which
are exempt on purpose, which are beyond reach -- a flipped predicate silently
stops silencing an app's self-updates, and the only other place that shows is
an app on the real Mac updating behind Homebrew's back.

Usage::

    python3 tests/caskupd.py
"""

from __future__ import annotations

import plistlib
import sys
import tempfile
import traceback
from itertools import starmap
from pathlib import Path
from unittest import mock

# The library is deployed rather than kept here, so it is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

import caskupd_app
import caskupd_sparkle
from caskupd_app import APPDIR, EXEMPT, App
from caskupd_sparkle import CHECKS, INSTALLS, OFF, Sparkle

EXEMPT_TOKEN = min(EXEMPT)


def _app(token: str = "foo", *, sparkle: bool = False, auto_updates: bool = False) -> App:
    """Build one classified app without reading any disk.

    Args:
        token: The cask token.
        sparkle: Whether the app embeds Sparkle.
        auto_updates: Whether the cask declares it self-updates.

    Returns:
        The app.

    """
    return App(
        token=token,
        path=APPDIR / "Foo.app",
        bundle_id="com.example.foo",
        sparkle=sparkle,
        auto_updates=auto_updates,
    )


# --- The three classifications ------------------------------------------------


def test_sparkle_app_is_manageable() -> None:
    """An app that embeds Sparkle and is not exempt can be silenced."""
    app = _app(sparkle=True)
    assert app.manageable
    assert not app.beyond_reach
    assert not app.exempt


def test_exempt_app_is_never_manageable() -> None:
    """A cask in EXEMPT is left alone even when Sparkle could silence it."""
    app = _app(EXEMPT_TOKEN, sparkle=True, auto_updates=True)
    assert app.exempt
    assert not app.manageable
    assert not app.beyond_reach


def test_self_updater_without_sparkle_is_beyond_reach() -> None:
    """A cask that self-updates with no Sparkle has no lever to pull."""
    app = _app(auto_updates=True)
    assert app.beyond_reach
    assert not app.manageable


def test_plain_app_is_none_of_the_three() -> None:
    """An app with no updater at all needs nothing and gets nothing."""
    app = _app()
    assert not app.manageable
    assert not app.beyond_reach
    assert not app.exempt


# --- Where a cask's apps land -------------------------------------------------


def test_bundles_default_to_applications() -> None:
    """An app artifact with no target lands under /Applications."""
    cask = {"artifacts": [{"app": ["Foo.app"]}, "a zap line", {"uninstall": []}]}
    assert App._bundles(cask) == [APPDIR / "Foo.app"]


def test_bundles_honour_an_explicit_target() -> None:
    """An artifact naming a target is installed exactly there."""
    cask = {"artifacts": [{"app": ["Foo.app"], "target": "/Custom/Foo.app"}]}
    assert App._bundles(cask) == [Path("/Custom/Foo.app")]


# --- Reading a bundle off disk ------------------------------------------------


def _bundle(tmp: Path, info: dict[str, str] | None) -> Path:
    """Write a minimal app bundle.

    Args:
        tmp: The directory to build it in.
        info: The Info.plist contents, or None to omit the plist.

    Returns:
        The bundle path.

    """
    path = tmp / "Foo.app"
    contents = path / "Contents"
    contents.mkdir(parents=True)
    if info is not None:
        with (contents / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
    return path


def test_read_detects_sparkle_from_plist_keys() -> None:
    """A bundle carrying a Sparkle feed key is classified as Sparkle."""
    with tempfile.TemporaryDirectory() as tmp:
        path = _bundle(Path(tmp), {"CFBundleIdentifier": "com.example.foo", "SUFeedURL": "x"})
        app = App._read({"token": "foo"}, path)
    assert app is not None
    assert app.sparkle


def test_read_without_sparkle_marks_none() -> None:
    """A bundle with neither the keys nor the framework is not Sparkle."""
    with tempfile.TemporaryDirectory() as tmp:
        path = _bundle(Path(tmp), {"CFBundleIdentifier": "com.example.foo"})
        app = App._read({"token": "foo"}, path)
    assert app is not None
    assert not app.sparkle


def test_read_skips_a_bundle_with_no_identifier() -> None:
    """No bundle identifier means no preference domain to write, so no app."""
    with tempfile.TemporaryDirectory() as tmp:
        assert App._read({"token": "foo"}, _bundle(Path(tmp), {})) is None


def test_read_skips_a_missing_bundle() -> None:
    """A cask whose app is not on disk contributes nothing."""
    with tempfile.TemporaryDirectory() as tmp:
        assert App._read({"token": "foo"}, _bundle(Path(tmp), None)) is None


# --- Which apps are open ------------------------------------------------------


def test_running_matches_the_bundle_path() -> None:
    """An app is open when a process command line sits inside its bundle."""
    app = _app()
    processes = f"{app.path}/Contents/MacOS/Foo\n/usr/sbin/somethingelse"
    with mock.patch.object(caskupd_app, "maybe", return_value=processes):
        assert App.running((app,)) == frozenset({app.token})


def test_running_ignores_other_processes() -> None:
    """A process list without the bundle reports the app closed."""
    app = _app()
    with mock.patch.object(caskupd_app, "maybe", return_value="/usr/sbin/somethingelse"):
        assert App.running((app,)) == frozenset()


# --- What enable may delete ---------------------------------------------------


def test_restore_deletes_only_what_disable_wrote() -> None:
    """A key reading false is deleted; one set true by hand stays."""
    state = {CHECKS: OFF, INSTALLS: "1"}
    deleted = []

    def fake_maybe(*argv: str, timeout: int = 0) -> str:
        """Answer ``defaults read`` from the fixture and record deletes.

        Args:
            argv: The command and its arguments.
            timeout: Accepted and ignored, to match the real runner.

        Returns:
            The fixture value for a read, the empty string otherwise.

        """
        del timeout
        if argv[:2] == ("defaults", "read"):
            return state[argv[3]]
        if argv[:2] == ("defaults", "delete"):
            deleted.append(argv[3])
        return ""

    with mock.patch.object(caskupd_sparkle, "maybe", fake_maybe):
        assert Sparkle.written("com.example.foo")
        Sparkle.restore("com.example.foo")
    assert deleted == [CHECKS]


def test_written_is_false_with_nothing_of_ours() -> None:
    """A domain with only a hand-set true holds nothing disable wrote."""
    with mock.patch.object(caskupd_sparkle, "maybe", return_value="1"):
        assert not Sparkle.written("com.example.foo")


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
