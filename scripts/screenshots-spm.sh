#!/bin/bash
# README screenshots without Xcode.
#   scripts/screenshots-spm.sh
# Debug build → a demo service in the user launchd domain (not root, dry-run mode:
# system routes are NOT changed) → rules from Design/Screenshots/demo-config.<language>.json →
# the app captures its own main window (no screen recording permission needed) → en-* and ru-* PNGs in Design/Screenshots.
# The app window is visible on screen for about a minute (half a minute per language).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d)"
OUT="$ROOT/Design/Screenshots"
LABEL="io.github.kirillkarmanov.Tunnelside.helper"
APP="$WORK/Tunnelside.app"

cleanup() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -rf "$WORK" "${TMPDIR:-/tmp}/TunnelsideHelperDev"
}
trap cleanup EXIT

echo "→ Debug build"
CONFIG=debug APP="$APP" scripts/build-spm.sh >/dev/null

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

# For each language: a clean demo service with its own rules, and the app launched in that language
for lang in en ru; do
    echo "→ Capturing ($lang)"
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -rf "${TMPDIR:-/tmp}/TunnelsideHelperDev"
    launchctl bootstrap "gui/$(id -u)" "$WORK/helper.plist"
    sleep 2
    "$WORK/seed" "$LABEL" "$OUT/demo-config.$lang.json"
    # Restart so the log in the screenshot starts in the right language
    launchctl bootout "gui/$(id -u)/$LABEL"
    launchctl bootstrap "gui/$(id -u)" "$WORK/helper.plist"
    sleep 4   # let the service resolve the domains

    mkdir -p "$WORK/raw-$lang"
    TUNNELSIDE_DEV_AGENT=1 TUNNELSIDE_SCREENSHOT_DIR="$WORK/raw-$lang" TUNNELSIDE_SCREENSHOT_DIAGNOSE="dom15.by" \
        "$APP/Contents/MacOS/Tunnelside" -AppleLanguages "($lang)" | grep "screenshot:" || true

    for name in rules logs; do
        for theme in light dark; do
            [ -f "$WORK/raw-$lang/$name-$theme.png" ] && cp "$WORK/raw-$lang/$name-$theme.png" "$OUT/$lang-$name-$theme.png"
        done
    done
done
ls -1 "$OUT"/*.png
