#!/bin/bash
# Скриншоты для README без Xcode.
#   scripts/screenshots-spm.sh
# Отладочная сборка → демо-служба в пользовательском домене launchd (не от root, в холостом режиме:
# системные маршруты НЕ меняются) → правила из Design/Screenshots/demo-config.json →
# приложение само снимает своё главное окно (разрешение на запись экрана не нужно) → PNG в Design/Screenshots.
# Окно приложения будет видно на экране около полуминуты.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d)"
OUT="$ROOT/Design/Screenshots"
LABEL="com.hyperits.app.MacOSRoute.helper"
APP="$WORK/MacOSRoute.app"

cleanup() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -rf "$WORK" "${TMPDIR:-/tmp}/MacOSRouteHelperDev"
}
trap cleanup EXIT

echo "→ Отладочная сборка"
CONFIG=debug APP="$APP" scripts/build-spm.sh >/dev/null

echo "→ Демо-служба (холостой режим)"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
cat > "$WORK/helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/$LABEL</string><string>--allow-unsigned-clients</string></array>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$WORK/helper.plist"
sleep 2

echo "→ Демо-правила"
cat > "$WORK/seed.swift" <<'SWIFT'
import Foundation
@objc(RouteHelperProtocol) protocol RouteHelperProtocol {
    func fetchState(withReply reply: @escaping (Data?, String?) -> Void)
    func updateConfig(_ configData: Data, withReply reply: @escaping (String?, Bool) -> Void)
    func reapplyAll(withReply reply: @escaping (String?) -> Void)
    func removeAllRoutes(withReply reply: @escaping (String?) -> Void)
    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void)
}
let connection = NSXPCConnection(machServiceName: CommandLine.arguments[1], options: [])
connection.remoteObjectInterface = NSXPCInterface(with: RouteHelperProtocol.self)
connection.resume()
let helper = connection.remoteObjectProxyWithErrorHandler { print("XPC: \($0)"); exit(1) } as! RouteHelperProtocol
helper.updateConfig(try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) { error, conflict in
    if let error { print(error); exit(1) }
    helper.reapplyAll { _ in exit(conflict ? 1 : 0) }
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
exit(1)
SWIFT
swiftc -O "$WORK/seed.swift" -o "$WORK/seed"
"$WORK/seed" "$LABEL" "$OUT/demo-config.json"
sleep 3   # даём службе разрешить домены

echo "→ Съёмка окна"
mkdir -p "$WORK/raw"
MACOSROUTE_DEV_AGENT=1 MACOSROUTE_SCREENSHOT_DIR="$WORK/raw" MACOSROUTE_SCREENSHOT_DIAGNOSE="dom15.by" \
    "$APP/Contents/MacOS/MacOSRoute" | grep "screenshot:" || true

for name in rules logs; do
    for theme in light dark; do
        [ -f "$WORK/raw/$name-$theme.png" ] && cp "$WORK/raw/$name-$theme.png" "$OUT/ru-$name-$theme.png"
    done
done
ls -1 "$OUT"/ru-*.png
