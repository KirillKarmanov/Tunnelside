import Darwin
import Foundation
import SystemConfiguration

/// Watches IPv4 network changes (Wi-Fi switch, cable plugged in/out, sleep/wake, DHCP renewal, etc.)
public final class NetworkChangeMonitor {
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    public init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let store = SCDynamicStoreCreate(nil, "TunnelsideMonitor" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/DNS", "State:/Network/Interface/[^/]+/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}

/// Watches kernel routing table changes (for example, a VPN client removed or overrode our routes when connecting)
public final class RoutingTableMonitor {
    private var source: DispatchSourceRead?

    public init?(queue: DispatchQueue, onChange: @escaping () -> Void) {
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var relevant = false
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                // rt_msghdr: u_short rtm_msglen; u_char rtm_version; u_char rtm_type
                guard n >= 4 else { continue }
                switch Int32(buffer[3]) {
                case RTM_ADD, RTM_DELETE, RTM_CHANGE: relevant = true
                default: break
                }
            }
            if relevant { onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
