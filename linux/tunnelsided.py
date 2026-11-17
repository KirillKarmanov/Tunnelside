#!/usr/bin/env python3
"""Tunnelside service for Linux (runs as root).

Sends the addresses of the rules around the VPN: a route through the gateway of the physical
network in the main table (wg-quick looks there first for anything narrower than 0.0.0.0/0),
a pass in the VPN kill switch (nft set inet vpn_killswitch bypass4), and for domains a DNS
routing domain on the physical link, so the browser gets the same addresses the routes were made for.
"""
import collections
import ipaddress
import json
import os
import random
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import uuid
import grp
import pwd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunnelside_common import SOCKET_PATH, parse_target, split_input  # noqa: E402

CONFIG_PATH = "/var/lib/tunnelside/config.json"
LOG_PATH = "/var/log/tunnelside.log"
PROTO = "211"            # marks our routes in the kernel table
VPN_IF = "wg0"
NFT_TABLE = "inet vpn_killswitch"
CHECK_SECONDS = 30

lock = threading.RLock()
wake = threading.Event()
stopping = threading.Event()
log_lines = collections.deque(maxlen=500)
config = {"rules": [], "refresh_minutes": 10, "retention_hours": 6, "paused": False}
resolved = {}            # rule id -> {ip: last seen (unix time)}
resolved_at = {}         # rule id -> last resolve time
rule_errors = {}         # rule id -> text
managed_domains = []     # routing domains we put on the physical link
last_network = None


def log(text):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + text
    log_lines.append(line)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(*args, stdin=None):
    return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=20)


def load_config():
    try:
        with open(CONFIG_PATH, encoding="utf-8") as f:
            config.update(json.load(f))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        log(f"Не прочитал {CONFIG_PATH}: {e} — начинаю с пустого списка")


def save_config():
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=1)
    os.replace(tmp, CONFIG_PATH)


# ---------- network ----------

def physical_network():
    """(gateway, device) of the default route of the physical network, or None."""
    r = run("ip", "-j", "route", "show", "default", "table", "main")
    try:
        routes = [x for x in json.loads(r.stdout or "[]") if x.get("dev") != VPN_IF and x.get("gateway")]
    except ValueError:
        return None
    if not routes:
        return None
    best = min(routes, key=lambda x: x.get("metric", 0))
    return best["gateway"], best["dev"]


def link_dns(dev):
    r = run("resolvectl", "dns", dev)
    for part in r.stdout.split(":", 1)[-1].split():
        try:
            if ipaddress.ip_address(part).version == 4:
                return part
        except ValueError:
            continue
    return None


def dns_a(name, server, timeout=3.0):
    """IPv4 addresses of a name, asked straight from the DNS server of the physical network."""
    tid = random.randint(0, 0xFFFF)
    q = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        s.sendto(q, (server, 53))
        data, _ = s.recvfrom(4096)
    rid, flags, qd, an = struct.unpack(">HHHH", data[:8])
    if rid != tid:
        raise OSError("чужой ответ DNS")
    if flags & 0xF == 3:
        raise OSError("такого домена нет (NXDOMAIN)")
    if flags & 0xF:
        raise OSError(f"DNS ответил ошибкой {flags & 0xF}")

    def skip(off):
        while True:
            n = data[off]
            if n == 0:
                return off + 1
            if n & 0xC0 == 0xC0:
                return off + 2
            off += n + 1

    off = 12
    for _ in range(qd):
        off = skip(off) + 4
    ips = []
    for _ in range(an):
        off = skip(off)
        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        if rtype == 1 and rdlen == 4:
            ips.append(socket.inet_ntoa(data[off:off + 4]))
        off += rdlen
    return ips


def wanted_networks(now):
    nets = []
    retention = config["retention_hours"] * 3600
    for rule in config["rules"]:
        if not rule["enabled"]:
            continue
        kind, target = parse_target(rule["target"]) or (None, None)
        if kind in ("ip", "subnet"):
            nets.append(ipaddress.IPv4Network(target, strict=False))
        elif kind == "domain":
            for ip, seen in resolved.get(rule["id"], {}).items():
                if now - seen <= retention:
                    nets.append(ipaddress.IPv4Network(ip + "/32"))
    return list(ipaddress.collapse_addresses(nets))


def refresh_domains(server, now, force):
    for rule in config["rules"]:
        kind, host = parse_target(rule["target"]) or (None, None)
        if kind != "domain" or not rule["enabled"]:
            continue
        rid = rule["id"]
        if not force and now - resolved_at.get(rid, 0) < config["refresh_minutes"] * 60:
            continue
        resolved_at[rid] = now
        try:
            ips = dns_a(host, server)
            if not ips:
                raise OSError("у домена нет IPv4-адресов")
        except (OSError, struct.error, IndexError) as e:
            rule_errors[rid] = f"DNS {server}: {e}"
            log(f"{host}: адреса не получил — {rule_errors[rid]}")
            continue
        rule_errors.pop(rid, None)
        known = resolved.setdefault(rid, {})
        new = [ip for ip in ips if ip not in known]
        for ip in ips:
            known[ip] = now
        if new:
            log(f"{host}: адреса {', '.join(sorted(new))}")
        for ip, seen in list(known.items()):
            if now - seen > config["retention_hours"] * 3600:
                del known[ip]
                log(f"{host}: старый адрес {ip} больше не держу")


def our_routes():
    r = run("ip", "-j", "route", "show", "table", "main", "proto", PROTO)
    try:
        return {str(ipaddress.ip_network(x["dst"])): x for x in json.loads(r.stdout or "[]")}
    except (ValueError, KeyError):
        return {}


def foreign_routes():
    r = run("ip", "-j", "route", "show", "table", "main")
    try:
        return {str(ipaddress.ip_network(x["dst"])) for x in json.loads(r.stdout or "[]")
                if x.get("dst") != "default" and str(x.get("protocol")) not in (PROTO, "211")}
    except (ValueError, KeyError):
        return set()


def sync_routes(nets, gw, dev):
    have = our_routes()
    foreign = foreign_routes()
    want = {str(n) for n in nets}
    for dst in sorted(want):
        cur = have.get(dst)
        if cur and cur.get("gateway") == gw and cur.get("dev") == dev:
            continue
        if not cur and dst in foreign:
            continue  # someone else routed it already — leave it alone
        r = run("ip", "route", "replace", dst, "via", gw, "dev", dev, "proto", PROTO)
        log(f"маршрут {dst} → {gw} ({dev})" if r.returncode == 0 else f"маршрут {dst} не добавлен: {r.stderr.strip()}")
    for dst in sorted(set(have) - want):
        run("ip", "route", "del", dst, "table", "main", "proto", PROTO)
        log(f"маршрут {dst} убран")


def sync_killswitch(nets):
    if run("nft", "list", "set", *NFT_TABLE.split(), "bypass4").returncode != 0:
        return  # no kill switch on this computer
    script = f"flush set {NFT_TABLE} bypass4\n"
    if nets:
        script += f"add element {NFT_TABLE} bypass4 {{ {', '.join(str(n) for n in nets)} }}\n"
    r = run("nft", "-f", "-", stdin=script)
    if r.returncode != 0:
        log(f"пропуск в блокировке VPN не обновлён: {r.stderr.strip()}")


def sync_dns_domains(dev):
    global managed_domains
    domains = []
    if not config["paused"]:
        for rule in config["rules"]:
            kind, host = parse_target(rule["target"]) or (None, None)
            if kind == "domain" and rule["enabled"]:
                domains.append("~" + host)
    current = run("resolvectl", "domain", dev).stdout.split(":", 1)[-1].split()
    others = [d for d in current if d not in managed_domains]
    if sorted(current) != sorted(others + domains):
        run("resolvectl", "domain", dev, *(others + domains or [""]))  # "" clears; no args only prints
    managed_domains = domains


def reconcile():
    global last_network
    with lock:
        net = physical_network()
        now = time.time()
        if not net:
            if last_network:
                log("нет физической сети — жду")
            last_network = None
            return
        gw, dev = net
        changed = net != last_network
        if changed:
            log(f"сеть: шлюз {gw}, интерфейс {dev}")
            last_network = net
        if config["paused"]:
            sync_routes([], gw, dev)
            sync_killswitch([])
            sync_dns_domains(dev)
            return
        server = link_dns(dev) or gw
        refresh_domains(server, now, force=changed)
        nets = wanted_networks(now)
        sync_routes(nets, gw, dev)
        sync_killswitch(nets)
        sync_dns_domains(dev)


def clear_all():
    with lock:
        for dst in our_routes():
            run("ip", "route", "del", dst, "table", "main", "proto", PROTO)
        sync_killswitch([])
        if last_network:
            config_paused = config["paused"]
            config["paused"] = True
            sync_dns_domains(last_network[1])
            config["paused"] = config_paused
        log("служба остановлена, маршруты убраны")


# ---------- commands ----------

def vpn_state():
    r = run("wg", "show", VPN_IF, "latest-handshakes")
    if r.returncode != 0:
        return "нет туннеля"
    times = [int(x.split()[1]) for x in r.stdout.splitlines() if len(x.split()) == 2]
    if times and time.time() - max(times) < 180:
        return "включён"
    return "нет связи с сервером"


def status():
    with lock:
        rules = []
        for rule in config["rules"]:
            kind = (parse_target(rule["target"]) or ("?",))[0]
            rules.append({**rule, "kind": kind, "ips": sorted(resolved.get(rule["id"], {})),
                          "error": rule_errors.get(rule["id"], "")})
        gw, dev = last_network or ("", "")
        return {"rules": rules, "gateway": gw, "device": dev, "vpn": vpn_state(),
                "paused": config["paused"], "refresh_minutes": config["refresh_minutes"],
                "retention_hours": config["retention_hours"]}


def find(rid):
    for rule in config["rules"]:
        if rule["id"] == rid:
            return rule
    raise ValueError("Нет такого правила")


def cmd_add(req):
    added, bad, dup = [], [], []
    with lock:
        existing = {(parse_target(r["target"]) or (0, r["target"]))[1] for r in config["rules"]}
        for raw in split_input(str(req.get("text", ""))):
            parsed = parse_target(raw)
            if not parsed:
                bad.append(raw)
                continue
            if parsed[1] in existing:
                dup.append(parsed[1])
                continue
            existing.add(parsed[1])
            config["rules"].append({"id": str(uuid.uuid4()), "target": parsed[1], "enabled": True,
                                    "note": str(req.get("note", ""))[:200]})
            added.append(parsed[1])
        if added:
            save_config()
            log("добавлено: " + ", ".join(added))
    wake.set()
    return {"added": added, "invalid": bad, "duplicates": dup}


def cmd_update(req):
    with lock:
        rule = find(req.get("id"))
        if "enabled" in req:
            rule["enabled"] = bool(req["enabled"])
            log(f"{rule['target']}: {'включено' if rule['enabled'] else 'выключено'}")
        if "note" in req:
            rule["note"] = str(req["note"])[:200]
        save_config()
    wake.set()
    return {}


def cmd_delete(req):
    with lock:
        rule = find(req.get("id"))
        config["rules"].remove(rule)
        resolved.pop(rule["id"], None)
        rule_errors.pop(rule["id"], None)
        save_config()
        log(f"удалено: {rule['target']}")
    wake.set()
    return {}


def cmd_settings(req):
    with lock:
        if "paused" in req:
            config["paused"] = bool(req["paused"])
            log("пауза: все исключения сняты" if config["paused"] else "пауза снята")
        if "refresh_minutes" in req:
            config["refresh_minutes"] = max(1, min(1440, int(req["refresh_minutes"])))
        if "retention_hours" in req:
            config["retention_hours"] = max(0, min(168, int(req["retention_hours"])))
        save_config()
    wake.set()
    return {}


def cmd_check(req):
    parsed = parse_target(str(req.get("target", "")))
    if not parsed or parsed[0] == "subnet":
        raise ValueError("Нужен домен, ссылка или один IP-адрес")
    kind, target = parsed
    out = {"target": target, "direct_dns": [], "system_dns": [], "paths": []}
    ips = [target]
    if kind == "domain":
        net = last_network
        try:
            out["direct_dns"] = dns_a(target, (link_dns(net[1]) if net else None) or (net[0] if net else "192.168.1.1"))
        except (OSError, struct.error, IndexError, TypeError) as e:
            out["direct_dns_error"] = str(e)
        try:
            out["system_dns"] = sorted({a[4][0] for a in socket.getaddrinfo(target, 443, socket.AF_INET)})
        except OSError as e:
            out["system_dns_error"] = str(e)
        ips = sorted(set(out["direct_dns"]) | set(out["system_dns"]))[:8]
    for ip in ips:
        r = run("ip", "-j", "route", "get", ip)
        try:
            route = json.loads(r.stdout)[0]
        except (ValueError, IndexError):
            route = {}
        start = time.time()
        try:
            with socket.create_connection((ip, 443), timeout=4):
                tcp = f"соединение есть, {int((time.time() - start) * 1000)} мс"
        except OSError as e:
            tcp = f"нет соединения: {e.strerror or e}"
        out["paths"].append({"ip": ip, "dev": route.get("dev", "?"), "via": route.get("gateway", ""), "tcp": tcp})
    return out


COMMANDS = {
    "status": lambda req: status(),
    "add": cmd_add,
    "update": cmd_update,
    "delete": cmd_delete,
    "settings": cmd_settings,
    "check": cmd_check,
    "log": lambda req: {"lines": list(log_lines)[-300:]},
}


def allowed(sock):
    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    _pid, uid, gid = struct.unpack("3i", creds)
    if uid == 0:
        return True
    try:
        return grp.getgrnam("sudo").gr_gid in os.getgrouplist(pwd.getpwuid(uid).pw_name, gid)
    except KeyError:
        return False


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        if not allowed(self.request):
            self.wfile.write(b'{"ok": false, "error": "no access"}\n')
            return
        try:
            req = json.loads(self.rfile.readline(65536).decode())
            answer = {"ok": True, **COMMANDS[req["cmd"]](req)}
        except KeyError:
            answer = {"ok": False, "error": "Неизвестная команда"}
        except (ValueError, TypeError) as e:
            answer = {"ok": False, "error": str(e)}
        self.wfile.write(json.dumps(answer, ensure_ascii=False).encode() + b"\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def watch_network():
    """Wake up on any change of routes, addresses or links (Wi-Fi switch, cable, wake from sleep)."""
    while not stopping.is_set():
        p = subprocess.Popen(["ip", "monitor", "route", "address", "link"], stdout=subprocess.PIPE, text=True)
        for _ in p.stdout:
            wake.set()
            if stopping.is_set():
                break
        p.kill()
        time.sleep(5)


def main():
    load_config()
    log("служба запущена")
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    server = Server(SOCKET_PATH, Handler)
    os.chown(SOCKET_PATH, 0, grp.getgrnam("sudo").gr_gid)
    os.chmod(SOCKET_PATH, 0o660)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=watch_network, daemon=True).start()

    def stop(*_):
        stopping.set()
        wake.set()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while not stopping.is_set():
        try:
            reconcile()
        except Exception as e:  # keep the service alive whatever one pass hits
            log(f"ошибка проверки: {e!r}")
        wake.wait(CHECK_SECONDS)
        if not stopping.is_set():
            time.sleep(2)  # gather a burst of network events into one pass
        wake.clear()
    clear_all()
    server.shutdown()


if __name__ == "__main__":
    main()
