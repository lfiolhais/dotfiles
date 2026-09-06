#!/usr/bin/env python3
"""SOCKS5 ProxyCommand with RFC 1929 user/pass auth.

The Claude Code sandbox exposes a SOCKS5 proxy whose credentials live in
$ALL_PROXY and whose port is re-allocated on every tool call, so the port is
read from the environment at run time rather than hardcoded. macOS `nc -X 5`
cannot do SOCKS5 authentication, which is why this exists.
"""
import os
import socket
import sys
import threading
from urllib.parse import urlparse


def main() -> None:
    p = urlparse(os.environ["ALL_PROXY"])
    s = socket.create_connection(("127.0.0.1", p.port))
    s.sendall(b"\x05\x01\x02")
    if s.recv(2)[1] != 2:
        sys.exit("proxy refused username/password auth")
    u, w = p.username.encode(), p.password.encode()
    s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(w)]) + w)
    if s.recv(2)[1] != 0:
        sys.exit("socks auth failed")
    host, port = sys.argv[1].encode(), int(sys.argv[2])
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + port.to_bytes(2, "big"))
    r = s.recv(4)
    if r[1] != 0:
        sys.exit(f"socks connect rejected rep={r[1]}")
    atyp = r[3]
    s.recv(4 if atyp == 1 else s.recv(1)[0] if atyp == 3 else 16)
    s.recv(2)

    def pump_up() -> None:
        while True:
            d = os.read(0, 65536)
            if not d:
                break
            s.sendall(d)
        s.shutdown(socket.SHUT_WR)

    threading.Thread(target=pump_up, daemon=True).start()
    while True:
        d = s.recv(65536)
        if not d:
            break
        os.write(1, d)


if __name__ == "__main__":
    main()
