#!/usr/bin/env python3
"""tunnelside — the same list from the terminal: list, add, del, on, off, check, pause, resume, log."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunnelside_common import ServiceError, call, parse_target  # noqa: E402

USAGE = """tunnelside list                     список исключений
tunnelside add <сайт|ссылка|IP> …   добавить (несколько через пробел)
tunnelside del|on|off <сайт|IP>     удалить, включить, выключить
tunnelside check <сайт|IP>          куда идёт адрес и открывается ли
tunnelside pause|resume             всё через VPN / вернуть исключения
tunnelside log                      журнал"""


def rule_id(state, raw):
    parsed = parse_target(raw)
    key = parsed[1] if parsed else raw
    for rule in state["rules"]:
        if rule["target"] == key:
            return rule["id"]
    raise ServiceError(f"В списке нет {key}")


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cmd, args = argv[0], argv[1:]
    if cmd == "list":
        s = call("status")
        print(f"VPN: {s['vpn']}; шлюз {s['gateway'] or '—'} ({s['device'] or '—'})" + ("; ПАУЗА" if s["paused"] else ""))
        for r in s["rules"]:
            extra = r["error"] or ", ".join(r["ips"])
            print(f"[{'x' if r['enabled'] else ' '}] {r['target']}" + (f"  — {r['note']}" if r["note"] else "")
                  + (f"  ({extra})" if extra and r["kind"] == "domain" else ""))
    elif cmd == "add":
        a = call("add", text=" ".join(args))
        for label, key in (("добавлено", "added"), ("уже было", "duplicates"), ("не понял", "invalid")):
            if a[key]:
                print(f"{label}: {', '.join(a[key])}")
    elif cmd in ("del", "on", "off"):
        s = call("status")
        for raw in args:
            rid = rule_id(s, raw)
            call("delete", id=rid) if cmd == "del" else call("update", id=rid, enabled=(cmd == "on"))
        print("готово")
    elif cmd == "check":
        a = call("check", target=" ".join(args))
        if a.get("direct_dns") or a.get("system_dns"):
            print("DNS сети:", ", ".join(a["direct_dns"]) or a.get("direct_dns_error", ""))
            print("DNS системы:", ", ".join(a["system_dns"]) or a.get("system_dns_error", ""))
        for p in a["paths"]:
            print(f"{p['ip']}: {p['dev']} {p['via']}; 443 — {p['tcp']}")
    elif cmd in ("pause", "resume"):
        call("settings", paused=(cmd == "pause"))
        print("пауза" if cmd == "pause" else "исключения снова работают")
    elif cmd == "log":
        print("\n".join(call("log")["lines"][-60:]))
    else:
        print(USAGE)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ServiceError as e:
        print(e, file=sys.stderr)
        sys.exit(1)
