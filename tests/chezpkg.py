#!/usr/bin/env python3
"""Unit tests for the package bookkeeping logic.

Nothing real is touched: the Brewfiles are fixture strings, the manifests are
built in memory or in a temporary file, and the subprocess runner is replaced
where a test needs one. No ``brew`` or ``uv`` is ever run.

What is being asserted is ``Manifest.problems`` clause by clause. The harness
also runs it against the live files, but those are healthy, so every clause is
vacuously green there -- a regression in one would pass everything and be
discovered when a real clash breaks the no-sudo profile's generated mise
config. Feeding each clause a fixture that fires it is what keeps the clauses
themselves honest.

Needs Python 3.11, like everything in ``chezpkg``: the manifest reader uses
``tomllib``.

Usage::

    python3 tests/chezpkg.py
"""

from __future__ import annotations

import sys
import tempfile
import traceback
from itertools import starmap
from pathlib import Path
from unittest import mock

# The library is deployed rather than kept here, so it is not on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

import chezpkg_brew
from chezpkg_brew import Brewfile, Entry
from chezpkg_manifest import Manifest
from chezpkg_run import PackagesError

SAMPLE = """tap "homebrew/bundle"
brew "ripgrep"
brew "gh", link: false
cask "ghostty"
mas "Tapestry", id: 6448078074
uv "ty"
vscode "ms-python.python"
"""


def _brewfile(*entries: Entry) -> Brewfile:
    """Build a Brewfile snapshot without reading any disk.

    Args:
        entries: The entries it should hold.

    Returns:
        The snapshot; its text is unused by anything under test.

    """
    return Brewfile(Path("Brewfile"), "", tuple(entries))


def _manifest(packages: dict[str, dict[str, str]]) -> Manifest:
    """Build a manifest without reading any disk.

    Args:
        packages: The ``[packages]`` table.

    Returns:
        The manifest.

    """
    return Manifest(Path("packages.toml"), packages)


# --- Reading a Brewfile -------------------------------------------------------


def test_parse_reads_every_kind() -> None:
    """Each declaration kind is one entry, whatever trails the name."""
    assert Brewfile.parse(SAMPLE) == (
        Entry("tap", "homebrew/bundle"),
        Entry("brew", "ripgrep"),
        Entry("brew", "gh"),
        Entry("cask", "ghostty"),
        Entry("mas", "Tapestry"),
        Entry("uv", "ty"),
        Entry("vscode", "ms-python.python"),
    )


def test_accountable_is_brew_and_uv_only() -> None:
    """Only the kinds that put a CLI tool on the Mac need a manifest claim."""
    assert _brewfile(*Brewfile.parse(SAMPLE)).accountable == {"ripgrep", "gh", "ty"}


def test_declaring_finds_every_line_for_a_name() -> None:
    """A formula and a uv tool of one name are both that package's entries."""
    brewfile = _brewfile(Entry("brew", "x"), Entry("uv", "x"), Entry("brew", "y"))
    assert brewfile.declaring("x") == (Entry("brew", "x"), Entry("uv", "x"))


def test_uninstall_reports_the_kinds_it_cannot_remove() -> None:
    """A mas app or tap has no uninstall route and is returned, not dropped."""
    ran = []
    with mock.patch.object(chezpkg_brew, "run", lambda *argv, **_kw: ran.append(argv)):
        done, skipped = Brewfile.uninstall(
            (Entry("brew", "x"), Entry("mas", "Tapestry"), Entry("tap", "a/b")),
        )
    assert done == ("brew uninstall x",)
    assert skipped == (Entry("mas", "Tapestry"), Entry("tap", "a/b"))
    assert ran == [("brew", "uninstall", "x")]


# --- What the two files disagreeing means, clause by clause -------------------


def test_problems_clean_pair_is_empty() -> None:
    """A claimed formula with a target raises no problem."""
    manifest = _manifest({"ripgrep": {"brew": "ripgrep", "apt": "ripgrep"}})
    assert manifest.problems(_brewfile(Entry("brew", "ripgrep"))) == []


def test_problems_unaccounted_brewfile_entry() -> None:
    """A Brewfile tool no manifest entry claims is reported by name."""
    problems = _manifest({}).problems(_brewfile(Entry("brew", "ripgrep")))
    assert problems == ["ripgrep: in the Brewfile, unaccounted for in the manifest"]


def test_problems_stale_claim() -> None:
    """An entry claiming a formula the Brewfile lost is reported with its owner."""
    manifest = _manifest({"rg": {"brew": "ripgrep", "apt": "ripgrep"}})
    problems = manifest.problems(_brewfile())
    assert problems == ["rg: claims the formula 'ripgrep', which the Brewfile no longer has"]


def test_problems_installs_nowhere_without_a_note() -> None:
    """An entry with no target and no reason is the case `note` exists for."""
    manifest = _manifest({"x": {"brew": "x"}})
    problems = manifest.problems(_brewfile(Entry("brew", "x")))
    assert problems == ["x: installs nowhere and says no reason -- name a target, or add a note"]


def test_problems_note_or_repo_excuse_a_targetless_entry() -> None:
    """A note, or `repo`, is accepted as the reason a tool skips Linux."""
    noted = _manifest({"x": {"brew": "x", "note": "macOS only"}})
    assert noted.problems(_brewfile(Entry("brew", "x"))) == []
    repo = _manifest({"x": {"brew": "x", "repo": "official"}})
    assert repo.problems(_brewfile(Entry("brew", "x"))) == []


def test_problems_unknown_field() -> None:
    """A misspelled field is named rather than silently carried."""
    manifest = _manifest({"x": {"brew": "x", "apt": "x", "aptt": "x"}})
    problems = manifest.problems(_brewfile(Entry("brew", "x")))
    assert problems == ["x: unknown field(s) aptt"]


def test_problems_mise_clash() -> None:
    """Two entries claiming one mise tool would render a duplicate TOML key."""
    manifest = _manifest(
        {"a": {"brew": "a", "mise": "tool"}, "b": {"brew": "b", "mise": "tool"}},
    )
    problems = manifest.problems(_brewfile(Entry("brew", "a"), Entry("brew", "b")))
    assert problems == ["b: mise tool 'tool' already claimed by a"]


def test_problems_brew_clash() -> None:
    """Two entries claiming one formula would hide one from the stale check."""
    manifest = _manifest(
        {"a": {"brew": "x", "apt": "x"}, "b": {"brew": "x", "apt": "x"}},
    )
    problems = manifest.problems(_brewfile(Entry("brew", "x")))
    assert problems == ["b: formula 'x' already claimed by a"]


# --- Reading a hand-broken manifest -------------------------------------------


def test_read_refuses_an_entry_that_is_not_a_table() -> None:
    """A string where a table belongs is a message, not an AttributeError."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "packages.toml"
        path.write_text('[packages]\nx = "y"\n', encoding="utf-8")
        try:
            Manifest.read(path)
        except PackagesError as exc:
            refused = str(exc)
        else:
            refused = ""
    assert "x" in refused
    assert "not tables" in refused


def test_read_accepts_the_generated_shape() -> None:
    """A well-formed file reads back as its entries."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "packages.toml"
        path.write_text('[packages.x]\nbrew = "x"\n', encoding="utf-8")
        assert Manifest.read(path).packages == {"x": {"brew": "x"}}


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
