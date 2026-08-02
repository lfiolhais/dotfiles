#!/usr/bin/env python3
"""Safety harness for the chezmoi dotfiles.

It confirms the source still renders and that shell scripts are sane, without
touching ``$HOME`` and without running the ``run_*`` bootstrap scripts.

Usage::

    python3 tests/check.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BREWFILE = REPO / "private_dot_config" / "Brewfile"
# Target paths that must never be deployed (kept out via .chezmoiignore).
MUST_NOT_DEPLOY = ("CLAUDE.md", "LICENSE", "key.txt.age")
# Exit code a shell uses for "command not found".
MISSING = 127


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

    Args:
        argv: The command and its arguments.
        stdin: Optional text piped to the command's standard input.

    Returns:
        The exit code and stripped stdout+stderr; a missing binary yields code 127.

    """
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return Command(MISSING, f"command not found: {argv[0]}")
    return Command(proc.returncode, (proc.stdout + proc.stderr).strip())


def chezmoi(*args: str, stdin: str | None = None) -> Command:
    """Run ``chezmoi`` against this repository as the source directory.

    Args:
        args: Arguments passed after ``chezmoi --source <repo>``.
        stdin: Optional text piped to chezmoi's standard input.

    Returns:
        The command result.

    """
    return run("chezmoi", "--source", str(REPO), *args, stdin=stdin)


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


def _render_template(rel: Path, path: Path, workdir: Path) -> tuple[Path, Result | None]:
    rendered = chezmoi("execute-template", stdin=path.read_text(encoding="utf-8"))

    if not rendered.ok:
        return path, Result(Status.FAIL, f"{rel}: template render", rendered.output)

    script = workdir / (rel.name + ".rendered")
    script.write_text(rendered.output, encoding="utf-8")

    return script, None


def check_scripts(workdir: Path) -> list[Result]:
    """Lint every ``run_*`` bootstrap script; render ``.tmpl`` scripts via chezmoi first.

    ``bash -n`` and shellcheck errors are hard failures; shellcheck warnings are advisory.
    Vendored app filters (for example aerc's) are config data, not ours, so they are skipped.

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
    check = run("brew", "bundle", "check", "--file", str(BREWFILE), "--no-upgrade")

    if check.ok:
        return Result(Status.OK, "Brewfile satisfied")

    if check.missing:
        return Result(Status.OK, "Brewfile skipped (brew not installed)")

    return Result(Status.WARN, "Brewfile has unmet entries", check.output)


def check_python() -> Result:
    """Lint the harness's own Python with ruff (rules live in tests/pyproject.toml).

    Returns:
        A failing result if ruff is missing or reports issues, otherwise a passing result.

    """
    tests_dir = REPO / "tests"

    lint = run("ruff", "check", "--preview", str(tests_dir))
    if not lint.ok:
        return Result(Status.FAIL, "ruff check", lint.output)

    fmt = run("ruff", "format", "--check", str(tests_dir))
    if not fmt.ok:
        return Result(Status.FAIL, "ruff format", fmt.output)

    return Result(Status.OK, "python: ruff clean")


def _dry_run() -> None:
    diff = chezmoi("apply", "--dry-run", "--verbose").output

    print("\n-- chezmoi apply --dry-run (nothing applied, no scripts run) --")
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
            check_python(),
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
