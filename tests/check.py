#!/usr/bin/env python3
"""Safety harness for the chezmoi dotfiles.

It renders the source, lints the bootstrap scripts, checks the Brewfile against
the Linux manifest, lints and imports this repo's Python under every interpreter
on the host, runs the mount-nas unit tests, and prints a dry-run diff -- without
touching ``$HOME`` and without running the ``run_*`` bootstrap scripts.

Needs Python 3.11: ``enum.StrEnum`` below, and ``tomllib`` inside the manifest
reader it imports. That is a higher floor than the 3.9 it holds the deployed
libraries to, which is why it probes for other interpreters rather than assuming
its own will do.

Usage::

    python3 tests/check.py
"""

from __future__ import annotations

import itertools
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

# chezpkg is deployed rather than kept here, so it is not on sys.path. What the
# two package files are, and what it means for them to agree, is described there
# once -- by the command that maintains them -- rather than a second time here.
# Importing it here is what sets this harness's 3.11 floor: the manifest reader
# needs tomllib. `chezmoi-packages` reaches the same code through uv instead.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

from chezpkg import TARGETS, Brewfile, Manifest

REPO = Path(__file__).resolve().parent.parent
BREWFILE = REPO / "private_dot_config" / "Brewfile"
# Maps every Brewfile formula onto its per-distro Linux equivalent.
MANIFEST = REPO / ".chezmoidata" / "packages.toml"
# The fields that mean "Linux installs this", for counting: a distro name, or
# `repo` for gh and starship, which the 01 script installs from their own.
LINUX = TARGETS | {"repo"}
RUFF_CONFIG = REPO / "tests" / "pyproject.toml"
# The libraries the deployed commands share. Globbed rather than listed, so
# splitting a module in two cannot silently drop it out of the lint.
LIB_PYTHON = REPO / "dot_local" / "lib" / "python"
# The facade of each library that must import under the oldest interpreter on the
# host. Importing these is what catches an import cycle or a construct too new
# for 3.9; ruff cannot see either. `chezpkg` is deliberately absent: it needs
# 3.11, which uv supplies to the command that uses it, so it is exercised by
# CHEZMOI_PACKAGES below instead.
DEPLOYED_LIBRARIES = ("caskupd", "gitwt", "linux_distros", "mountnas")
# Runs under uv, which resolves its PEP 723 dependencies and supplies its own
# interpreter -- so it is checked the way it really runs, not under each python3.
CHEZMOI_PACKAGES = REPO / "dot_local" / "bin" / "executable_chezmoi-packages"
DEPLOYED_ENTRY_POINTS = (
    REPO / "dot_local" / "bin" / "executable_git-wt-clone",
    REPO / "dot_local" / "bin" / "executable_git-wt-add",
    REPO / "dot_local" / "bin" / "executable_cask-updates",
    REPO / "dot_local" / "bin" / "executable_mount-nas",
)
# The one part of this repo with unit tests of its own: what mount-nas decides
# is a table of outcomes, and most of them assert that no command was run --
# being silent away from home is the behaviour, so it is what has to be tested.
MOUNTNAS_TESTS = REPO / "tests" / "mountnas.py"
# Deployed Python that ruff would not otherwise find: it lives outside tests/,
# and the entry points have no .py extension because they are commands.
DEPLOYED_PYTHON = (*sorted(LIB_PYTHON.glob("*.py")), *DEPLOYED_ENTRY_POINTS, CHEZMOI_PACKAGES)
# Target paths that must never be deployed (kept out via .chezmoiignore).
MUST_NOT_DEPLOY = ("CLAUDE.md", "LICENSE", "key.txt.age", "tests")
# Exit code a shell uses for "command not found".
MISSING = 127
# Exit code timeout(1) uses; reused for a command that outstayed TIMEOUT.
TIMED_OUT = 124
# Seconds any single command may take before the harness gives up on it.
TIMEOUT = 180
# --no-tty: never open the terminal to ask a question. chezmoi prompts on
# /dev/tty rather than stdin, so a prompt raised here would be invisible behind
# the captured output and would hang the harness. --no-pager: never hand output
# to a pager, which would wait on the terminal for the same reason.
CHEZMOI_FLAGS = ("--no-tty", "--no-pager")


class Status(StrEnum):
    """Outcome of a single check."""

    OK = "ok"
    WARN = "warn"
    FAIL = "fail"


@dataclass(frozen=True)
class Command:
    """Result of running a subprocess: its exit code and combined output."""

    code: int
    output: str

    @property
    def ok(self) -> bool:
        """Whether the command exited successfully.

        Returns:
            True if the exit code was zero.

        """
        return self.code == 0

    @property
    def missing(self) -> bool:
        """Whether the command's binary was not found.

        Returns:
            True if the binary could not be located.

        """
        return self.code == MISSING


@dataclass(frozen=True)
class Result:
    """The outcome of one check, ready to print."""

    status: Status
    title: str
    detail: str = ""


def run(*argv: str, stdin: str | None = None) -> Command:
    """Run a command, capturing combined output; never raises.

    The child never inherits this terminal's stdin: it gets the given text, or an
    immediately closed pipe. Anything that stops to ask a question therefore reads
    EOF and fails, instead of hanging the harness on a prompt nobody can see.

    Args:
        argv: The command and its arguments.
        stdin: Optional text piped to the command's standard input.

    Returns:
        The exit code and stripped stdout+stderr; a missing binary yields code 127
        and one that outstays ``TIMEOUT`` yields code 124.

    """
    try:
        proc = subprocess.run(
            argv,
            input=stdin or "",
            capture_output=True,
            text=True,
            check=False,
            timeout=TIMEOUT,
        )
    except FileNotFoundError:
        return Command(MISSING, f"command not found: {argv[0]}")
    except subprocess.TimeoutExpired:
        return Command(TIMED_OUT, f"timed out after {TIMEOUT}s: {' '.join(argv)}")
    return Command(proc.returncode, (proc.stdout + proc.stderr).strip())


def chezmoi(*args: str, stdin: str | None = None) -> Command:
    """Run ``chezmoi`` against this repository as the source directory.

    Args:
        args: Arguments passed after ``chezmoi --source <repo>``.
        stdin: Optional text piped to chezmoi's standard input.

    Returns:
        The command result.

    """
    return run("chezmoi", *CHEZMOI_FLAGS, "--source", str(REPO), *args, stdin=stdin)


def check_render(workdir: Path) -> Result:
    """Render the whole source with ``chezmoi archive`` (templates plus age decryption).

    This has zero side effects: nothing is written to ``$HOME`` and no scripts run.

    Args:
        workdir: A temporary directory for the throwaway archive.

    Returns:
        A passing result with the entry count, or a failing result with the error.

    """
    archive = workdir / "state.tar"
    rendered = chezmoi("archive", "--format", "tar", "--output", str(archive))
    if not rendered.ok:
        return Result(Status.FAIL, "render + decrypt", rendered.output)

    entries = len(run("tar", "tf", str(archive)).output.splitlines())

    return Result(Status.OK, f"render + decrypt ({entries} target entries)")


def check_no_leaks() -> Result:
    """Assert that ignored docs and secrets are not part of the deployed target state.

    Returns:
        A failing result naming any leaked path, otherwise a passing result.

    """
    managed = chezmoi("managed")
    if not managed.ok:
        return Result(Status.FAIL, "ignore check", managed.output)

    tracked = set(managed.output.split())
    leaked = [path for path in MUST_NOT_DEPLOY if path in tracked]
    if leaked:
        return Result(Status.FAIL, "ignore check", f"managed but must not be: {', '.join(leaked)}")

    return Result(Status.OK, "docs/secrets stay out of the target")


def _scripts() -> list[Path]:
    return sorted(REPO.glob("run_*.sh")) + sorted(REPO.glob("run_*.sh.tmpl"))


def _lint(rel: Path, script: Path) -> Result:
    syntax = run("bash", "-n", str(script))
    if not syntax.ok:
        return Result(Status.FAIL, f"{rel}: bash syntax", syntax.output)

    errors = run("shellcheck", "--severity=error", str(script))
    if not errors.ok:
        return Result(Status.FAIL, f"{rel}: shellcheck error", errors.output)

    warnings = run("shellcheck", "--severity=warning", str(script))
    if not warnings.ok:
        return Result(Status.WARN, f"{rel}: shellcheck warnings", warnings.output)

    return Result(Status.OK, str(rel))


def _render_template(rel: Path, path: Path, workdir: Path) -> tuple[Path | None, Result | None]:
    rendered = chezmoi("execute-template", stdin=path.read_text(encoding="utf-8"))

    if not rendered.ok:
        return None, Result(Status.FAIL, f"{rel}: template render", rendered.output)

    if not rendered.output.strip():
        return None, None  # gated off for this OS (e.g. a linux-only script on darwin)

    script = workdir / (rel.name + ".rendered")
    script.write_text(rendered.output, encoding="utf-8")

    return script, None


def check_scripts(workdir: Path) -> list[Result]:
    """Lint every ``run_*`` bootstrap script; render ``.tmpl`` scripts via chezmoi first.

    ``bash -n`` and shellcheck errors are hard failures; shellcheck warnings are advisory.
    Only the ``run_*`` scripts at the repo root are in scope -- ``_scripts()`` does not
    recurse, so shell shipped inside a config directory is not linted by anything.

    Args:
        workdir: A temporary directory for rendered templates.

    Returns:
        One result per discovered script.

    """
    results: list[Result] = []
    for path in _scripts():
        rel = path.relative_to(REPO)

        if path.name.endswith(".tmpl"):
            script, error = _render_template(rel, path, workdir)

            if error is not None:
                results.append(error)
                continue

            if script is None:
                continue  # rendered empty: OS-gated off, nothing to lint
        else:
            script = path

        results.append(_lint(rel, script))

    return results


def check_brewfile() -> Result:
    """Check that every Brewfile entry is installed, skipping if Homebrew is absent.

    Missing packages are advisory (a config change does not require them), not a hard failure.

    Returns:
        A passing, skipped, or advisory-warning result.

    """
    # --no-upgrade: report only what is missing. Without it an installed but
    # outdated package counts as unmet, and every machine merely behind fails.
    check = run("brew", "bundle", "check", "--file", str(BREWFILE), "--no-upgrade")

    if check.ok:
        return Result(Status.OK, "Brewfile satisfied")

    if check.missing:
        return Result(Status.OK, "Brewfile skipped (brew not installed)")

    return Result(Status.WARN, "Brewfile has unmet entries", check.output)


def check_package_parity() -> Result:
    """Check the Linux package manifest still accounts for every Brewfile entry.

    macOS installs from the Brewfile and Linux from ``.chezmoidata/packages.toml``,
    so the two drift apart silently -- a ``brew bundle dump`` widens the gap with no
    warning. Every ``brew``/``uv`` entry must therefore be claimed by a manifest
    entry, and one that installs nowhere on Linux must say why. The comparison
    itself lives in ``chezpkg``, so the command that maintains the two files and
    the harness that gates them cannot disagree about what agreement means. Pure
    text, so it runs on Linux too, where there is no ``brew`` to ask.

    Returns:
        A failing result listing every problem, otherwise a passing result.

    """
    manifest = Manifest.read(MANIFEST)
    problems = manifest.problems(Brewfile.read(BREWFILE))

    if problems:
        return Result(Status.FAIL, "Brewfile <-> package manifest", "\n".join(problems))

    installed = sum(1 for entry in manifest.packages.values() if entry.keys() & LINUX)

    return Result(
        Status.OK,
        f"package manifest in step with the Brewfile "
        f"({installed} installed on Linux, {len(manifest.packages) - installed} not)",
    )


def check_python() -> Result:
    """Lint this repo's Python with ruff (rules live in tests/pyproject.toml).

    Returns:
        A failing result if ruff is missing or reports issues, otherwise a passing result.

    """
    targets = [str(REPO / "tests"), *(str(path) for path in DEPLOYED_PYTHON)]
    config = ["--config", str(RUFF_CONFIG)]

    # --preview repeats what tests/pyproject.toml sets, because the DOC
    # (pydoclint) rules only fire in preview and a config that loses the setting
    # would otherwise disable them silently rather than failing.
    lint = run("ruff", "check", "--preview", *config, *targets)
    if not lint.ok:
        return Result(Status.FAIL, "ruff check", lint.output)

    fmt = run("ruff", "format", "--check", *config, *targets)
    if not fmt.ok:
        return Result(Status.FAIL, "ruff format", fmt.output)

    return Result(Status.OK, "python: ruff clean")


def _interpreters() -> list[str]:
    """Find the python3 interpreters the deployed commands could run under.

    Returns:
        Executable paths, deduplicated by what they resolve to, oldest-standing
        system interpreter included when it exists.

    """
    found: dict[Path, str] = {}
    for candidate in (shutil.which("python3"), "/usr/bin/python3", sys.executable):
        if not candidate:
            continue
        path = Path(candidate)
        if path.exists():
            found.setdefault(path.resolve(), candidate)
    return list(found.values())


def check_python_imports() -> Result:
    """Import each deployed library and run each command's ``--help``.

    Returns:
        A failing result if an import or ``--help`` fails, a warning if the host
        has no python3 at all, otherwise a passing result.

    """
    interpreters = _interpreters()
    if not interpreters:
        return Result(Status.WARN, "python: no python3 found, imports not checked")

    for interp, library in itertools.product(interpreters, DEPLOYED_LIBRARIES):
        probe = f"import sys; sys.path.insert(0, {str(LIB_PYTHON)!r}); import {library}"
        # -B: never leave a __pycache__ behind in the source directory.
        imported = run(interp, "-B", "-c", probe)
        if not imported.ok:
            return Result(Status.FAIL, f"python: import {library} ({interp})", imported.output)

    for interp, entry in itertools.product(interpreters, DEPLOYED_ENTRY_POINTS):
        helped = run(interp, "-B", str(entry), "--help")
        if not helped.ok:
            return Result(Status.FAIL, f"python: {entry.name} --help ({interp})", helped.output)

    return Result(Status.OK, f"python: imports clean ({len(interpreters)} interpreter(s))")


def check_mountnas() -> Result:
    """Run the NAS mount unit tests.

    They stub out the network and every subprocess, so this starts no mount and
    reads no Keychain -- safe with the share mounted and away from home alike.

    Returns:
        A failing result if any test fails, a warning if the host has no
        python3, otherwise a passing result.

    """
    interpreters = _interpreters()
    if not interpreters:
        return Result(Status.WARN, "mount-nas tests skipped (no python3 found)")

    # -B: never leave a __pycache__ behind in the source directory.
    tested = run(interpreters[0], "-B", str(MOUNTNAS_TESTS))
    if not tested.ok:
        return Result(Status.FAIL, "mount-nas unit tests", tested.output)

    return Result(Status.OK, f"mount-nas: {tested.output.splitlines()[-1]}")


def check_uv_script() -> Result:
    """Run ``chezmoi-packages --help`` the way it really runs: through uv.

    Its shebang is a PEP 723 script, so uv supplies both the interpreter and
    ``tomlkit`` -- there is no TOML writer in the standard library, and Homebrew
    packages none. Running it here is what proves the dependency block resolves
    and that ``chezpkg`` imports under the interpreter uv picks.

    Returns:
        A failing result if it will not run, a warning if the host has no uv,
        otherwise a passing result.

    """
    helped = run("uv", "run", "--script", str(CHEZMOI_PACKAGES), "--help")

    if helped.missing:
        return Result(Status.WARN, "chezmoi-packages skipped (uv not installed)")

    if not helped.ok:
        return Result(Status.FAIL, "chezmoi-packages --help (uv)", helped.output)

    return Result(Status.OK, "chezmoi-packages runs under uv")


def _dry_run() -> None:
    # --force answers apply's "overwrite/remove?" prompts up front, so the diff is
    # complete rather than truncated at the first question. It changes nothing on
    # its own: --dry-run still writes nothing and still runs no script.
    diff = chezmoi("apply", "--dry-run", "--force", "--verbose").output

    print("\n-- chezmoi apply --dry-run --")
    print("\n".join("  " + line for line in diff.splitlines()) if diff else "  (no differences)")


def _report(results: list[Result]) -> bool:
    marks = {Status.OK: "ok  ", Status.WARN: "warn", Status.FAIL: "FAIL"}

    for result in results:
        print(f"  [{marks[result.status]}] {result.title}")

        if result.detail:
            print("\n".join("         " + line for line in result.detail.splitlines()))

    return any(result.status is Status.FAIL for result in results)


def main() -> int:
    """Run every check and report the outcome.

    Returns:
        Process exit code: 0 when all hard checks pass, 1 otherwise.

    """
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        results = [
            check_render(workdir),
            check_no_leaks(),
            *check_scripts(workdir),
            check_brewfile(),
            check_package_parity(),
            check_python(),
            check_python_imports(),
            check_mountnas(),
            check_uv_script(),
        ]
        hard_failure = _report(results)
        _dry_run()

    print()
    if hard_failure:
        print("FAILED — fix the issues above before pushing to main.")
        return 1
    print("All checks passed. Review the dry-run diff above, then push.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
