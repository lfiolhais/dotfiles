"""Process plumbing shared by every other module.

Standard library only, and Python 3.9-clean. The rest of ``chezpkg`` is 3.11+
because uv supplies its interpreter, but ``caskupd`` and ``mountnas`` import this
module and run under whatever ``python3`` a fresh Mac or a RHEL rebuild has --
3.9. A 3.10+ construct here breaks ``mount-nas`` and ``cask-updates`` there,
which is exactly the case ``tests/check.py`` probes for by importing both under
every interpreter it can find.
"""

from __future__ import annotations

import shlex
import shutil
import subprocess

# Seconds any one command may take. Long enough for a container to download a
# distribution's repository metadata, or for Homebrew to enumerate everything
# installed, both of which are the slow cases here.
TIMEOUT = 600


class PackagesError(Exception):
    """A failure to report to the user as a message, without a traceback."""


def run(*argv: str, stream: bool = False, timeout: int = TIMEOUT) -> str:
    """Run a command and return its output.

    Args:
        argv: The command and its arguments.
        stream: Let the command write straight to the terminal instead of being
            captured, so a slow install can show its progress.
        timeout: Seconds to wait before giving up.

    Returns:
        The command's stripped stdout, or the empty string when streaming.

    Raises:
        PackagesError: If the binary is missing, the command fails, or it
            outstays the timeout.

    """
    try:
        proc = subprocess.run(
            argv,
            capture_output=not stream,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        message = f"command not found: {argv[0]}"
        raise PackagesError(message) from exc
    except subprocess.TimeoutExpired as exc:
        message = f"{shlex.join(argv)}: gave up after {timeout}s"
        raise PackagesError(message) from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
        message = f"{shlex.join(argv)}: {detail}"
        raise PackagesError(message)

    return "" if stream else proc.stdout.strip()


def maybe(*argv: str, timeout: int = TIMEOUT) -> str:
    """Run a command whose failure is an answer rather than an error.

    Asking a package manager about a name it does not have is not a failure, and
    neither is asking a tool that is not installed -- both mean "no match here".

    Args:
        argv: The command and its arguments.
        timeout: Seconds to wait before giving up.

    Returns:
        The command's stripped stdout, empty if it failed or was missing.

    """
    try:
        return run(*argv, timeout=timeout)
    except PackagesError:
        return ""


def have(command: str) -> bool:
    """Report whether a command exists on PATH.

    Args:
        command: The command's name.

    Returns:
        True if it can be found.

    """
    return shutil.which(command) is not None
