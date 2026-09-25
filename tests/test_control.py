#!/usr/bin/env python3
"""Exercise live proxy settings without a VPN server or administrator access."""
import pathlib
import errno
import socket
import subprocess
import sys
import tempfile
import time


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(path, command):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(2)
        sock.connect(str(path))
        sock.sendall(command.encode())
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError as error:
            if error.errno != errno.ENOTCONN:
                raise
        reply = bytearray()
        while not reply.endswith(b"\n"):
            part = sock.recv(256)
            if not part:
                break
            reply.extend(part)
        return reply.decode()


def main(binary):
    with tempfile.TemporaryDirectory(prefix="pt-") as temporary:
        directory = pathlib.Path(temporary)
        fake = directory / "fake.sh"
        fake.write_text("#!/bin/sh\nexec /bin/cat >/dev/null\n")
        fake.chmod(0o700)
        control = directory / "ctl.sock"
        ports = set()
        while len(ports) < 5:
            ports.add(unused_port())
        old_http, old_socks, new_http, new_socks, forward = sorted(ports)
        process = subprocess.Popen(
            [binary, "--server", "127.0.0.1", "--user", "test", "--pptp", str(fake),
             "--control-socket", str(control), "--http", str(old_http),
             "--socks", str(old_socks)],
            stdin=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            process.stdin.write("test-only-password\n")
            process.stdin.close()
            for _ in range(50):
                if control.exists():
                    break
                time.sleep(0.05)
            assert control.exists(), "control socket was not created"
            initial_status = request(control, "STATUS\n")
            assert initial_status.startswith(
                f"STATUS 0 0 0 0 {old_http} {old_socks}"
            ), repr(initial_status)
            applied = request(control, f"APPLY {new_http} {new_socks}\n"
                                       f"F {forward} example.com 80\nEND\n")
            assert applied == "OK APPLY\n", repr(applied)
            for port in (new_http, new_socks, forward):
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    pass
            with socket.socket() as blocked:
                blocked.bind(("127.0.0.1", old_http))
                blocked.listen()
                assert request(control, f"APPLY {old_http} {old_socks}\nEND\n") == (
                    f"ERR APPLY {old_http}\n"
                )
            status = request(control, "STATUS\n")
            assert status.startswith(f"STATUS 0 0 0 0 {new_http} {new_socks}"), repr(status)
            assert request(control, "STOP\n") == "OK STOP\n"
            assert process.wait(timeout=5) == 0
            print("PASS: live apply, status, rollback, stop")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main(sys.argv[1])
