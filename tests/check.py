#!/usr/bin/env python3
"""Safety harness for the chezmoi dotfiles.

It renders the source, lints the bootstrap scripts and the rest of the deployed
shell and awk, parses every fish file, hands the ssh config and the gitconfig
to the programs that read them, refuses a compiled binary in the source, checks
that its own hand-maintained lists cover everything deployed, asks Homebrew
whether it still installs every Brewfile entry, checks the Brewfile against the
Linux manifest and the target matrix against its template, lints and imports
this repo's Python under every interpreter on the host, runs the unit-test
suites, and prints a dry-run diff -- without touching ``$HOME`` and without
running the ``run_*`` bootstrap scripts.

Needs Python 3.11: ``enum.StrEnum`` below, and ``tomllib`` inside the manifest
reader it imports. That is a higher floor than the 3.9 it holds the deployed
libraries to, which is why it probes for other interpreters rather than assuming
its own will do.

Usage::

    python3 tests/check.py
"""

from __future__ import annotations

import sys

if sys.version_info < (3, 11):
    # StrEnum below and tomllib inside the manifest reader arrive in 3.11. On
    # an older interpreter every import after this line is a bare traceback,
    # which reads as a broken harness rather than as the requirement it is --
    # and the pre-push hook runs this under whatever python3 is on PATH, which
    # on a fresh Mac is Apple's 3.9.
    sys.exit(
        "tests/check.py needs Python 3.11 or newer; this is Python "
        + ".".join(str(part) for part in sys.version_info[:3])
        + ". Run it with a newer python3 -- Homebrew's, or the distro's.",
    )

import itertools
import json
import re
import shutil
import subprocess
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
from linux_distros import TARGET_OF

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
# The unit-test suites, each named after the library it exercises. All of them
# stub subprocess and the network, so nothing mounts, clones, or writes. The
# 3.9-clean ones run under every interpreter `_interpreters()` finds, which is
# the runtime half of the 3.9 floor: the import check above proves the syntax
# parses, and only running the code catches a 3.10+ stdlib call inside a
# function body. `chezpkg`'s suite needs tomllib, so it runs under this
# harness's own 3.11+ interpreter alone.
UNIT_TESTS_39 = (
    REPO / "tests" / "mountnas.py",
    REPO / "tests" / "gitwt.py",
    REPO / "tests" / "caskupd.py",
)
UNIT_TESTS_311 = (REPO / "tests" / "chezpkg.py",)
# The render-time half of the Linux target matrix; the Python half is
# `linux_distros.TARGET_OF` and the manifest columns in `chezpkg.TARGETS`.
LINUX_TARGET_TEMPLATE = REPO / ".chezmoitemplates" / "linux-target"
# Deployed awk, listed by hand like SHELL_FILES: shellcheck refuses awk, ruff
# does not read it, and an aerc filter with a syntax error renders every
# message of its type as an awk complaint.
AWK_FILES = (
    REPO / "private_dot_config" / "aerc" / "private_filters" / "executable_calendar",
    REPO / "private_dot_config" / "aerc" / "private_filters" / "executable_hldiff",
    REPO / "private_dot_config" / "aerc" / "private_filters" / "executable_plaintext",
)
# Deployed Python that ruff would not otherwise find: it lives outside tests/,
# and the entry points have no .py extension because they are commands.
DEPLOYED_PYTHON = (*sorted(LIB_PYTHON.glob("*.py")), *DEPLOYED_ENTRY_POINTS, CHEZMOI_PACKAGES)
# Target paths that must never be deployed (kept out via .chezmoiignore).
MUST_NOT_DEPLOY = ("CLAUDE.md", "LICENSE", "key.txt.age", "tests")
# Deployed shell that `_scripts()` does not find, because it is not named run_*
# and does not live at the repo root. An rc file has no shebang, so it carries a
# `# shellcheck shell=` directive instead.
SHELL_FILES = (
    REPO / "dot_bashrc.tmpl",
    REPO / "private_dot_config" / "aerc" / "executable_check-mail.sh",
    REPO / "private_dot_config" / "aerc" / "private_filters" / "executable_html",
    REPO / "private_dot_config" / "aerc" / "private_filters" / "executable_test.sh",
    REPO / "private_dot_config" / "git" / "hooks-dco" / "executable_prepare-commit-msg",
    REPO / "dot_local" / "share" / "mail" / "dot_notmuch" / "hooks" / "executable_post-new",
)
# Every fish file this repository deploys. fish is the login shell, so a syntax
# error here is a shell that greets a new terminal with a parse error -- and
# nothing else in this harness parses fish.
FISH_ROOT = REPO / "private_dot_config" / "private_fish"
# A source file whose first bytes are one of these is a compiled binary. It was
# built for one architecture and one operating system, and deploying it to any
# other is a file that cannot be executed: `\x7fELF` is Linux, and the four
# Mach-O magics are macOS, thin and fat, either byte order.
BINARY_MAGIC = (
    b"\x7fELF",
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
)
# Names no source directory should carry: written by a program, never by hand,
# and meaningless on the machine they are copied to.
GENERATED_NAMES = ("dot_DS_Store", ".DS_Store", "dot_vimdid", "fish_variables")
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
    # `mas` entries are left out. Checking one runs `mas list`, which talks to
    # the App Store: away from the network it hangs until this harness's timeout
    # kills it, and a Brewfile check is then reported as a config failure.
    text = BREWFILE.read_text(encoding="utf-8")
    without_mas = "".join(
        line for line in text.splitlines(keepends=True) if not line.startswith("mas ")
    )

    # --no-upgrade: report only what is missing. Without it an installed but
    # outdated package counts as unmet, and every machine merely behind fails.
    check = run("brew", "bundle", "check", "--file", "-", "--no-upgrade", stdin=without_mas)

    if check.ok:
        return Result(Status.OK, "Brewfile satisfied (App Store entries not checked)")

    if check.missing:
        return Result(Status.OK, "Brewfile skipped (brew not installed)")

    return Result(Status.WARN, "Brewfile has unmet entries", check.output)


def _brew_states(kind: str, names: list[str]) -> tuple[list[str], list[str], Command]:
    """Ask Homebrew which of these packages it has disabled or deprecated.

    Args:
        kind: ``--formula`` or ``--cask``.
        names: The names to ask about.

    Returns:
        The disabled packages, the deprecated ones -- each as a line naming the
        date and the reason -- and the command that answered, so that an empty
        answer can be told from a failed one.

    """
    info = run("brew", "info", "--json=v2", kind, *names)
    if not info.ok:
        return [], [], info

    # `run` returns stdout and stderr together and brew writes its warnings to
    # stderr, so the document starts at the first brace rather than at the top.
    start = info.output.find("{")
    if start < 0:
        return [], [], Command(1, info.output)
    payload = json.loads(info.output[start:])

    disabled: list[str] = []
    deprecated: list[str] = []
    for package in payload["formulae"] + payload["casks"]:
        # A cask is identified by its token; a formula has no token and its
        # `name` is the string. A cask's `name` is the list of display names.
        name = package.get("token") or package["name"]
        if package.get("disabled"):
            reported, date, why = disabled, "disable_date", "disable_reason"
        elif package.get("deprecated"):
            reported, date, why = deprecated, "deprecation_date", "deprecation_reason"
        else:
            continue
        reported.append(f"{name}: {package.get(date)} -- {package.get(why)}")

    return disabled, deprecated, info


def check_brew_disabled() -> Result:
    """Check that Homebrew still installs every formula and cask the Brewfile names.

    Homebrew disables a package it can no longer install -- an app that stopped
    passing Gatekeeper, an upstream that went away -- and ``brew bundle install``
    exits non-zero on it. The darwin bootstrap installs everything in one bundle
    and stops there, so a package disabled upstream today is a fresh machine that
    cannot be set up tomorrow. The Mac that dumped the Brewfile is the last place
    it shows: the package is installed here already, so ``brew bundle check``
    passes and only a clean machine finds out.

    Returns:
        A failing result naming every disabled package, a warning for one that is
        only deprecated or for a Homebrew that could not answer, otherwise a
        passing or skipped result.

    """
    brewfile = Brewfile.read(BREWFILE)
    formulae = [entry.name for entry in brewfile.entries if entry.kind == "brew"]
    casks = [entry.name for entry in brewfile.entries if entry.kind == "cask"]

    disabled: list[str] = []
    deprecated: list[str] = []
    for kind, names in (("--formula", formulae), ("--cask", casks)):
        if not names:
            continue
        gone, going, info = _brew_states(kind, names)
        if info.missing:
            return Result(Status.OK, "Brewfile disables skipped (brew not installed)")
        if not info.ok:
            return Result(Status.WARN, "Homebrew could not be asked about disables", info.output)
        disabled.extend(gone)
        deprecated.extend(going)

    if disabled:
        detail = [
            *disabled,
            "",
            "A disabled package cannot be installed by anyone, so every apply on a",
            "machine without it stops at 01. Drop it from the Brewfile, and from",
            "this Mac too -- `brew bundle dump` writes back whatever is installed.",
            *(["", "Deprecated, still installable:", *deprecated] if deprecated else []),
        ]
        return Result(Status.FAIL, "the Brewfile names a disabled package", "\n".join(detail))

    if deprecated:
        return Result(
            Status.WARN,
            "the Brewfile names a deprecated package",
            "\n".join([*deprecated, "", "Still installable; Homebrew disables it at some point."]),
        )

    return Result(
        Status.OK,
        f"Homebrew still installs every Brewfile entry "
        f"({len(formulae)} formulae, {len(casks)} casks)",
    )


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


def _run_suite(tests: Path, interpreters: list[str]) -> Result:
    """Run one unit-test file under each of these interpreters.

    Args:
        tests: The test file, named after the library it exercises.
        interpreters: The python3 executables to run it under.

    Returns:
        A failing result naming the interpreter that failed, otherwise a
        passing result with the suite's own tally.

    """
    tally = ""
    for interp in interpreters:
        # -B: never leave a __pycache__ behind in the source directory.
        tested = run(interp, "-B", str(tests))
        if not tested.ok:
            return Result(Status.FAIL, f"{tests.stem} unit tests ({interp})", tested.output)
        tally = tested.output.splitlines()[-1] if tested.output else ""

    return Result(Status.OK, f"{tests.stem}: {tally} ({len(interpreters)} interpreter(s))")


def check_unit_tests() -> list[Result]:
    """Run every unit-test suite, the 3.9-clean ones under every interpreter.

    They stub out the network and every subprocess, so this starts no mount,
    clones nothing, and reads no Keychain -- safe with the share mounted and
    away from home alike.

    Returns:
        One result per suite, or a single warning if the host has no python3.

    """
    interpreters = _interpreters()
    if not interpreters:
        return [Result(Status.WARN, "unit tests skipped (no python3 found)")]

    results = [_run_suite(tests, interpreters) for tests in UNIT_TESTS_39]
    results += [_run_suite(tests, [sys.executable]) for tests in UNIT_TESTS_311]

    return results


def check_target_matrix() -> Result:
    """Check the three spellings of the Linux target matrix agree.

    The targets live in three places: ``TARGET_OF`` maps each distro onto its
    manifest column, ``TARGETS`` is the column set the manifest accepts, and
    ``.chezmoitemplates/linux-target`` dispatches a machine onto a column at
    render time. A distro added to the first two but not the template falls
    into the template's apt fallback, and the container harness then checks
    that distro's names against the wrong repositories with nothing failing.

    Returns:
        A failing result naming each disagreement, otherwise a passing result.

    """
    spoken = set(TARGET_OF.values())
    columns = TARGETS - {"mise"}
    template = LINUX_TARGET_TEMPLATE.read_text(encoding="utf-8")

    problems = []
    if spoken != columns:
        problems.append(
            f"TARGET_OF speaks for {sorted(spoken)}; the manifest's distro "
            f"columns are {sorted(columns)}",
        )
    problems += [
        f"{target!r} is not a branch of .chezmoitemplates/linux-target"
        for target in sorted(spoken)
        if not re.search(rf"^{re.escape(target)}$", template, flags=re.MULTILINE)
    ]

    if problems:
        return Result(Status.FAIL, "Linux target matrix", "\n".join(problems))

    return Result(Status.OK, "Linux target matrix agrees in all three spellings")


def check_awk_files() -> list[Result]:
    """Parse the deployed awk with awk itself.

    ``awk -f`` reads the whole program before its first input line, and stdin
    is empty here, so a syntax error is reported and a valid filter does
    nothing.

    Returns:
        One result per file in ``AWK_FILES``.

    """
    results = []
    for path in AWK_FILES:
        rel = path.relative_to(REPO)
        if not path.exists():
            results.append(Result(Status.FAIL, f"{rel}: missing", "listed in AWK_FILES"))
            continue
        parsed = run("awk", "-f", str(path))
        if parsed.missing:
            return [Result(Status.WARN, "awk files not parsed (awk not installed)")]
        if not parsed.ok:
            results.append(Result(Status.FAIL, f"{rel}: awk syntax", parsed.output))
        else:
            results.append(Result(Status.OK, str(rel)))
    return results


def _shebang(path: Path) -> str:
    """Read the interpreter a deployed file names on its first line.

    Args:
        path: The file to read.

    Returns:
        The first line when it is a shebang, otherwise the empty string.

    """
    with path.open("rb") as handle:
        first = handle.readline(120)
    if not first.startswith(b"#!"):
        return ""
    return first.decode("utf-8", errors="replace").strip()


def check_coverage() -> Result:
    """Check the hand-maintained lists cover everything actually deployed.

    Each list fails when a file it names is missing; this is the other
    direction, which nothing else reports: a new command under
    ``dot_local/bin/``, or a new deployed script, is linted and imported by
    nothing until it is named in a list -- and it deploys anyway.

    Returns:
        A failing result naming each uncovered file and the list it belongs
        in, otherwise a passing result.

    """
    known_bin = {*DEPLOYED_ENTRY_POINTS, CHEZMOI_PACKAGES}
    covered_python = set(DEPLOYED_PYTHON)
    covered_shell = {*SHELL_FILES, *_scripts()}

    uncovered = [
        f"{path.relative_to(REPO)}: a deployed command; add it to DEPLOYED_ENTRY_POINTS"
        for path in sorted((REPO / "dot_local" / "bin").glob("executable_*"))
        if path not in known_bin
    ]

    wants = (
        ("sh", covered_shell, "SHELL_FILES"),
        ("bash", covered_shell, "SHELL_FILES"),
        ("awk", set(AWK_FILES), "AWK_FILES"),
        ("python3", covered_python | known_bin, "DEPLOYED_PYTHON"),
    )
    for path in sorted(REPO.rglob("*")):
        rel = path.relative_to(REPO)
        if not path.is_file() or path.is_symlink() or path in known_bin:
            continue
        if rel.parts[0] in {".git", ".claude", ".ruff_cache", "tests"}:
            continue
        shebang = _shebang(path)
        if not shebang:
            continue
        # The interpreter is the first non-flag token's basename, looked up
        # through `env` when the shebang goes that way -- so `/usr/bin/awk -f`,
        # `/bin/sh` and `/usr/bin/env bash` all name their program.
        names = [Path(token).name for token in shebang[2:].split() if not token.startswith("-")]
        if names and names[0] == "env":
            names = names[1:]
        interpreter = names[0] if names else ""
        uncovered += [
            f"{rel}: deployed {name} that no check reads; add it to {where}"
            for name, covered, where in wants
            if interpreter == name and path not in covered
        ]

    if uncovered:
        return Result(Status.FAIL, "deployed but checked by nothing", "\n".join(uncovered))

    return Result(Status.OK, "every deployed script and command is in a checked list")


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


def check_shell_files() -> list[Result]:
    """Lint the deployed shell that is not a bootstrap script.

    Returns:
        One result per file, rendering it first when it is a template.

    """
    results: list[Result] = []
    for path in SHELL_FILES:
        rel = path.relative_to(REPO)
        if not path.exists():
            results.append(Result(Status.FAIL, f"{rel}: missing", "listed in SHELL_FILES"))
            continue
        if path.name.endswith(".tmpl"):
            with tempfile.TemporaryDirectory() as tmp:
                script, error = _render_template(rel, path, Path(tmp))
                if error is not None:
                    results.append(error)
                    continue
                if script is None:
                    continue
                results.append(_lint(rel, script))
        else:
            results.append(_lint(rel, path))
    return results


def check_fish(workdir: Path) -> Result:
    """Parse every deployed fish file with ``fish -n``.

    fish is the login shell, so a parse error here is what every new terminal
    opens with. Nothing else in this harness reads fish: ruff does not, and
    shellcheck refuses it.

    Args:
        workdir: A temporary directory for rendered templates.

    Returns:
        A failing result naming the first file that will not parse, a warning if
        fish is not installed, otherwise a passing result.

    """
    if shutil.which("fish") is None:
        return Result(Status.WARN, "fish files not parsed (fish not installed)")

    paths = sorted(FISH_ROOT.rglob("*.fish")) + sorted(FISH_ROOT.rglob("*.fish.tmpl"))
    if not paths:
        return Result(Status.FAIL, "fish", f"no fish files found under {FISH_ROOT}")

    checked = 0
    for path in paths:
        rel = path.relative_to(REPO)
        target = path
        if path.name.endswith(".tmpl"):
            rendered, error = _render_template(rel, path, workdir)
            if error is not None:
                return error
            if rendered is None:
                continue
            target = rendered

        parsed = run("fish", "-n", str(target))
        if not parsed.ok:
            return Result(Status.FAIL, f"{rel}: fish syntax", parsed.output)
        checked += 1

    return Result(Status.OK, f"fish: {checked} files parse")


def check_ssh_config(workdir: Path) -> Result:
    """Ask OpenSSH itself whether the deployed ssh config is valid.

    ``ssh -G`` resolves a host against a config and connects to nothing. A
    keyword the local OpenSSH does not know makes it exit non-zero, which is the
    failure worth catching: ssh rejects the whole file over one bad option, so
    every ssh on the machine stops working rather than just that one host.

    Args:
        workdir: A temporary directory for the rendered config.

    Returns:
        A failing result with ssh's complaint, otherwise a passing result.

    """
    source = REPO / "private_dot_ssh" / "config.tmpl"
    rel = source.relative_to(REPO)
    rendered, error = _render_template(rel, source, workdir)
    if error is not None:
        return error
    if rendered is None:
        return Result(Status.FAIL, f"{rel}: rendered empty")

    resolved = run("ssh", "-F", str(rendered), "-G", "github.com")
    if resolved.missing:
        return Result(Status.WARN, "ssh config not checked (ssh not installed)")
    if not resolved.ok:
        return Result(Status.FAIL, f"{rel}: ssh rejects it", resolved.output)

    return Result(Status.OK, "ssh config parses")


def check_gitconfig(workdir: Path) -> Result:
    """Ask git whether the deployed gitconfig parses.

    Args:
        workdir: A temporary directory for the rendered config.

    Returns:
        A failing result with git's complaint, otherwise a passing result.

    """
    source = REPO / "private_dot_gitconfig.tmpl"
    rel = source.relative_to(REPO)
    rendered, error = _render_template(rel, source, workdir)
    if error is not None:
        return error
    if rendered is None:
        return Result(Status.FAIL, f"{rel}: rendered empty")

    listed = run("git", "config", "--file", str(rendered), "--list")
    if not listed.ok:
        return Result(Status.FAIL, f"{rel}: git rejects it", listed.output)

    return Result(Status.OK, "gitconfig parses")


def check_source_is_text() -> Result:
    """Assert that no compiled binary or program-written file is in the source.

    A binary in the source is built for whatever machine built it, and chezmoi
    copies it unchanged to every other -- an arm64 Mach-O filter deployed to
    Linux is a file that cannot run. Encrypted files are exempt: age armour is
    text, so they never match anyway, and their plaintext is not read here.

    Returns:
        A failing result naming every offending file, otherwise a passing one.

    """
    offenders: list[str] = []
    for path in sorted(REPO.rglob("*")):
        rel = path.relative_to(REPO)
        if not path.is_file() or rel.parts[0] in {".git", ".claude", ".ruff_cache", "tests"}:
            continue
        if path.name in GENERATED_NAMES or any(part in GENERATED_NAMES for part in rel.parts):
            offenders.append(f"{rel}: written by a program, not by hand")
            continue
        with path.open("rb") as handle:
            head = handle.read(4)
        if head in BINARY_MAGIC:
            offenders.append(f"{rel}: compiled binary; build it on the machine instead")

    if offenders:
        return Result(Status.FAIL, "source holds files it should not", "\n".join(offenders))

    return Result(Status.OK, "source is text, and nothing in it is program-written")


def _dry_run() -> None:
    # --force answers apply's "overwrite/remove?" prompts up front, so the diff is
    # complete rather than truncated at the first question. It changes nothing on
    # its own: --dry-run still writes nothing and still runs no script.
    #
    # --exclude=encrypted because a verbose diff renders an encrypted file
    # decrypted, and this runs from the pre-push hook: without it every push
    # prints the ssh keys, the mail passwords and every contact whose target
    # differs. On a machine where nothing is deployed yet, that is all of them.
    diff = chezmoi("apply", "--dry-run", "--force", "--verbose", "--exclude=encrypted").output

    print("\n-- chezmoi apply --dry-run (encrypted files excluded) --")
    print("\n".join("  " + line for line in diff.splitlines()) if diff else "  (no differences)")

    # The exclusion above hides the change as well as the content, so the
    # encrypted entries are listed by name instead. `chezmoi status` prints two
    # status columns and the path, which is what a name-only view needs.
    encrypted = chezmoi("status", "--include=encrypted").output

    print("\n-- encrypted files that differ --")
    listed = "\n".join("  " + line for line in encrypted.splitlines())
    print(listed or "  (none)")


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
            *check_shell_files(),
            check_fish(workdir),
            check_ssh_config(workdir),
            check_gitconfig(workdir),
            *check_awk_files(),
            check_source_is_text(),
            check_coverage(),
            check_brewfile(),
            check_brew_disabled(),
            check_package_parity(),
            check_target_matrix(),
            check_python(),
            check_python_imports(),
            *check_unit_tests(),
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
