"""Shared pieces of Tunnelside for Linux: target parsing and the client of the service socket."""
import ipaddress
import json
import re
import socket

SOCKET_PATH = "/run/tunnelside.sock"
MIN_PREFIX = 8  # rules wider than /8 would send almost everything around the VPN
_LABEL = re.compile(r"^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?$")


def parse_target(raw):
    """Return (kind, normalized) for an IPv4 address, a subnet or a domain; None if it is none of them.

    Accepts a full link: only the host is taken from https://user@example.com:8080/page.
    National (Cyrillic) domains are stored by their Punycode name.
    """
    s = raw.strip().strip(".,;")
    if not s:
        return None
    if "://" in s:
        s = s.split("://", 1)[1]
        s = re.split(r"[/?#]", s, maxsplit=1)[0]
        s = s.rsplit("@", 1)[-1]
        if s.count(":") == 1:
            s = s.split(":", 1)[0]
    elif not re.match(r"^[\d.]+/\d+$", s):
        s = re.split(r"[/?#]", s, maxsplit=1)[0]
        if s.count(":") == 1:
            s = s.split(":", 1)[0]
    if re.match(r"^[\d.]+/\d+$", s):
        try:
            net = ipaddress.IPv4Network(s, strict=False)
        except ValueError:
            return None
        if net.prefixlen < MIN_PREFIX:
            return None
        return ("subnet", str(net)) if net.prefixlen < 32 else ("ip", str(net.network_address))
    if re.match(r"^[\d.]+$", s):
        try:
            return "ip", str(ipaddress.IPv4Address(s))
        except ValueError:
            return None
    host = s.lower().strip(".")
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        return None
    labels = host.split(".")
    if len(labels) < 2 or len(host) > 253 or not all(_LABEL.match(l) for l in labels):
        return None
    return "domain", host


def split_input(text):
    """Several targets in one field, separated by spaces, commas, semicolons or new lines."""
    return [p for p in re.split(r"[\s,;]+", text) if p]


class ServiceError(Exception):
    pass


def call(command, **args):
    """Send one command to the service and return its answer (a dict)."""
    req = json.dumps({"cmd": command, **args}).encode() + b"\n"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(20)
            sock.connect(SOCKET_PATH)
            sock.sendall(req)
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = sock.recv(65536)
                if not chunk:
                    break
                buf += chunk
    except (FileNotFoundError, ConnectionRefusedError):
        raise ServiceError("Служба Tunnelside не запущена (sudo systemctl start tunnelsided)")
    except PermissionError:
        raise ServiceError("Нет доступа к службе: пользователь должен быть в группе sudo")
    except OSError as e:
        raise ServiceError(f"Служба не ответила: {e}")
    try:
        answer = json.loads(buf.decode())
    except ValueError:
        raise ServiceError("Служба прислала непонятный ответ")
    if not answer.get("ok"):
        raise ServiceError(answer.get("error", "Ошибка службы"))
    return answer
