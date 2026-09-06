#!/usr/bin/env python3
"""Ask the real NAS whether it is still an SMB server.

The host and port in ``mountnas.py`` are the two facts nothing else can check:
the unit tests stub the network out, and a wrong hostname produces exactly the
same silence as being away from home. This sends an SMB2 NEGOTIATE and prints
the dialect the server picks, so a name that has stopped pointing at a file
server says so instead of looking like a quiet evening in.

It connects directly when it can, and tunnels through the SOCKS5 proxy named in
``$ALL_PROXY`` when a direct socket is refused, which is what lets it run from a
sandbox as well as from a normal shell.

Dialects are offered up to 3.0.2 and not 3.1.1. A 3.1.1 offer must carry
negotiate contexts, and without them a server answers STATUS_INVALID_PARAMETER
-- a valid SMB2 reply that reads as a failure.

This is standalone rather than part of ``check.py`` on purpose: the pre-push
hook has to pass away from home, and a check that fails whenever the NAS is out
of reach would be switched off within a week.

Usage::

    python3 tests/nasprobe.py
    python3 tests/nasprobe.py --host other.example.com --port 445
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

# The host and port under test are the ones the command itself uses.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dot_local" / "lib" / "python"))

import mountnas

TIMEOUT = 10.0

SOCKS_VERSION = 5
SOCKS_AUTH_USERPASS = 2
SOCKS_OK = 0
SOCKS_CONNECT = 1
# Address types, and the length of the bound address each one implies. The reply
# carries one, and reading the wrong number of bytes leaves the stream misaligned
# rather than failing, so the two are kept apart deliberately.
SOCKS_IPV4 = 1
SOCKS_DOMAIN = 3
SOCKS_IPV6 = 4
SOCKS_ADDRESS_LENGTH = {SOCKS_IPV4: 4, SOCKS_IPV6: 16}

SMB2_MAGIC = b"\xfeSMB"
SMB2_NEGOTIATE = 0x0000
SMB2_HEADER_SIZE = 64
STATUS_SUCCESS = 0
DIALECTS = (0x0202, 0x0210, 0x0300, 0x0302)
DIALECT_NAMES = {0x0202: "2.0.2", 0x0210: "2.1", 0x0300: "3.0", 0x0302: "3.0.2", 0x0311: "3.1.1"}
# The response is 64 bytes of header plus a body whose dialect sits at 68.
NEGOTIATE_REPLY_SIZE = 70
# SMB rides on the NetBIOS session service: one zero byte, then a 17-bit length.
# Anything else on the port is some other protocol talking, and saying so beats
# waiting for however many bytes its greeting happened to spell.
NETBIOS_SESSION_MESSAGE = 0
NETBIOS_MAX_LENGTH = 0x1FFFF


class ProbeError(Exception):
    """A failure to report as a message, without a traceback."""


def _recv(sock: socket.socket, count: int) -> bytes:
    """Read exactly this many bytes.

    Args:
        sock: The connected socket.
        count: How many bytes to read.

    Returns:
        The bytes read.

    Raises:
        ProbeError: If the peer closed before sending them all.

    """
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            message = f"connection closed after {len(buf)} of {count} bytes"
            raise ProbeError(message)
        buf += chunk
    return buf


def _through_proxy(host: str, port: int, proxy: str) -> socket.socket:
    """Open a tunnel to the host through a SOCKS5 proxy with user/password auth.

    The name is resolved by the proxy rather than locally, which is the point:
    a sandbox that blocks DNS can still reach the NAS this way.

    Args:
        host: The host to reach.
        port: The port to reach.
        proxy: The proxy URL, as found in ``$ALL_PROXY``.

    Returns:
        A socket connected to the host through the proxy.

    Raises:
        ProbeError: If the proxy refuses authentication or the connection.

    """
    parsed = urlparse(proxy)
    # A sandbox that blocks DNS blocks "localhost" with everything else, so the
    # loopback proxy is reached by address rather than by name.
    address = "127.0.0.1" if parsed.hostname == "localhost" else parsed.hostname
    sock = socket.create_connection((address, parsed.port), TIMEOUT)
    sock.settimeout(TIMEOUT)

    sock.sendall(bytes([SOCKS_VERSION, 1, SOCKS_AUTH_USERPASS]))
    if _recv(sock, 2)[1] != SOCKS_AUTH_USERPASS:
        message = "proxy refused username/password authentication"
        raise ProbeError(message)

    user = (parsed.username or "").encode()
    password = (parsed.password or "").encode()
    sock.sendall(bytes([1, len(user)]) + user + bytes([len(password)]) + password)
    if _recv(sock, 2)[1] != SOCKS_OK:
        message = "proxy rejected the credentials in $ALL_PROXY"
        raise ProbeError(message)

    name = host.encode()
    sock.sendall(
        bytes([SOCKS_VERSION, SOCKS_CONNECT, 0, SOCKS_DOMAIN, len(name)])
        + name
        + port.to_bytes(2, "big"),
    )
    reply = _recv(sock, 4)
    if reply[1] != SOCKS_OK:
        message = f"proxy could not reach {host}:{port} (SOCKS reply {reply[1]})"
        raise ProbeError(message)

    kind = reply[3]
    length = _recv(sock, 1)[0] if kind == SOCKS_DOMAIN else SOCKS_ADDRESS_LENGTH[kind]
    _recv(sock, length)
    _recv(sock, 2)
    return sock


def connect(host: str, port: int) -> tuple[socket.socket, str]:
    """Reach the host directly, or through the sandbox proxy if that is refused.

    Args:
        host: The host to reach.
        port: The port to reach.

    Returns:
        The connected socket and how it was reached.

    Raises:
        ProbeError: If neither route works.

    """
    try:
        sock = socket.create_connection((host, port), TIMEOUT)
    except OSError as direct:
        proxy = os.environ.get("ALL_PROXY", "")
        if not proxy:
            message = f"cannot reach {host}:{port}: {direct}"
            raise ProbeError(message) from direct
        return _through_proxy(host, port, proxy), f"through the proxy at {urlparse(proxy).port}"
    sock.settimeout(TIMEOUT)
    return sock, "directly"


def negotiate(sock: socket.socket) -> tuple[int, int, int]:
    """Send an SMB2 NEGOTIATE and read what comes back.

    Args:
        sock: A socket connected to the SMB port.

    Returns:
        The status, the dialect the server chose, and its security mode.

    Raises:
        ProbeError: If the answer is not an SMB2 message.

    """
    # MS-SMB2 2.2.1.2, the SYNC header. Every field but the command and the
    # credit request is zero for a NEGOTIATE, which is sent before a session
    # exists. The trailing 16 zero bytes are the unused signature field.
    header = (
        SMB2_MAGIC
        + struct.pack(
            "<HHIHHIIQIIQ",
            SMB2_HEADER_SIZE,  # StructureSize, fixed at 64
            0,  # CreditCharge
            0,  # Status
            SMB2_NEGOTIATE,  # Command
            1,  # CreditRequest: ask for one credit
            0,  # Flags
            0,  # NextCommand: not a compound request
            0,  # MessageId: first message on the connection
            0,  # Reserved (ProcessId)
            0,  # TreeId
            0,  # SessionId: none yet
        )
        + bytes(16)  # Signature
    )
    # MS-SMB2 2.2.3, NEGOTIATE Request. StructureSize is 36 by the specification
    # and is validated by the server, so it is not a count of anything here.
    body = (
        struct.pack(
            "<HHHHI",
            36,  # StructureSize, fixed by the specification
            len(DIALECTS),  # DialectCount
            1,  # SecurityMode: signing enabled
            0,  # Reserved
            0,  # Capabilities
        )
        + uuid.uuid4().bytes  # ClientGuid
        + bytes(8)  # ClientStartTime, unused below 3.1.1
        + b"".join(struct.pack("<H", dialect) for dialect in DIALECTS)
    )
    message = header + body
    sock.sendall(struct.pack(">I", len(message)) + message)

    prefix = _recv(sock, 4)
    length = int.from_bytes(prefix[1:], "big")
    if prefix[0] != NETBIOS_SESSION_MESSAGE or length > NETBIOS_MAX_LENGTH:
        detail = f"this is not an SMB service: it answered with {prefix!r}"
        raise ProbeError(detail)

    reply = _recv(sock, length)
    if reply[:4] != SMB2_MAGIC:
        detail = f"the answer does not start with an SMB2 header: {reply[:8]!r}"
        raise ProbeError(detail)
    if len(reply) < NEGOTIATE_REPLY_SIZE:
        detail = f"the SMB2 answer is only {len(reply)} bytes, too short to carry a dialect"
        raise ProbeError(detail)

    status = struct.unpack("<I", reply[8:12])[0]
    security_mode, dialect = struct.unpack("<HH", reply[66:70])
    return status, dialect, security_mode


def main() -> int:
    """Probe the NAS and report what it is.

    Returns:
        Process exit code: 0 if an SMB server answered, otherwise 1.

    """
    parser = argparse.ArgumentParser(
        prog="nasprobe.py",
        description="Confirm the configured host is still an SMB server.",
    )
    parser.add_argument(
        "--host",
        default=mountnas.HOST,
        help=f"server to probe (default: {mountnas.HOST}, the host mount-nas uses)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=mountnas.PORT,
        help=f"port to probe (default: {mountnas.PORT})",
    )
    args = parser.parse_args()

    try:
        sock, route = connect(args.host, args.port)
        with sock:
            status, dialect, security_mode = negotiate(sock)
    except (ProbeError, OSError) as exc:
        print(f"nasprobe: {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    if status != STATUS_SUCCESS:
        print(
            f"nasprobe: {args.host}:{args.port} answered SMB2 but refused the "
            f"negotiate (status {status:#010x})",
            file=sys.stderr,
        )
        return 1

    name = DIALECT_NAMES.get(dialect, "unknown")
    # SecurityMode is a bitfield: bit 0 signing enabled, bit 1 signing required.
    # Both are reported as enabled, since either means the server will sign.
    signing = "signing enabled" if security_mode else "signing off"
    print(f"{args.host}:{args.port} reached {route}")
    print(f"  SMB {name} (dialect {dialect:#06x}), {signing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
