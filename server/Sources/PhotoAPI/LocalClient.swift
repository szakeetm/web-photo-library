import Foundation
import Hummingbird
import HTTPTypes

/// Whether a request comes from a browser on this Mac. The server listens on 127.0.0.1 only, so a
/// request without X-Forwarded-For was made on this Mac; one proxied by Tailscale is local when it
/// was sent from one of this Mac's own addresses. Only used to adapt the app (local mode, Reveal in
/// Finder), never to grant access.
enum LocalClient {
    static func isLocal(_ request: Request) -> Bool {
        guard let forwarded = request.headers[HTTPField.Name("X-Forwarded-For")!] else { return true }
        let first = forwarded.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return ownAddresses().contains(first.lowercased())
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, addresses: Set<String>)?

    /// This Mac's interface addresses (refreshed every minute: Tailscale may reconnect).
    static func ownAddresses() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, Date().timeIntervalSince(c.at) < 60 { return c.addresses }
        var out: Set<String> = ["127.0.0.1", "::1"]
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = p {
                if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let len = socklen_t(sa.pointee.sa_family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
                        out.insert(s.lowercased())
                    }
                }
                p = ifa.pointee.ifa_next
            }
            freeifaddrs(list)
        }
        cached = (Date(), out)
        return out
    }

    /// Shows a file (selected) or opens a folder in the Finder.
    static func reveal(_ url: URL, select: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = select ? ["-R", url.path] : [url.path]
        try p.run()
    }
}
