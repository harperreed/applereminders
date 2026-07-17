// ABOUTME: Tailscale interface discovery: finds the machine's CGNAT-range IPv4 address.
// ABOUTME: The server binds to this address by default so only the tailnet reaches it (spec R3).

import Darwin
import Foundation

/// One IPv4 interface address from the system interface list.
public struct NetworkInterface: Sendable, Equatable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// True when `address` sits in tailscale's CGNAT range, 100.64.0.0/10 (first
/// octet 100, second octet 64 through 127). Matching by address range rather
/// than interface name survives utun renumbering and other VPNs.
func isTailscaleAddress(_ address: String) -> Bool {
    let octets = address.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    return octets[0] == 100 && (64...127).contains(octets[1])
}

/// Returns the first tailscale address in `interfaces`, or nil when the
/// machine has none.
public func firstTailscaleAddress(in interfaces: [NetworkInterface]) -> String? {
    interfaces.first { isTailscaleAddress($0.address) }?.address
}

/// The failure when no tailscale interface exists and no override was given.
public enum BindResolutionError: LocalizedError, Equatable {
    case noTailscaleInterface

    public var errorDescription: String? {
        "No tailscale interface found (no IPv4 address in 100.64.0.0/10). "
            + "Start tailscale, or pass --bind to listen on another interface."
    }
}

/// Resolves the bind host: an explicit override wins; otherwise the first
/// tailscale address; otherwise a descriptive error (spec R3).
public func resolveBindHost(override: String?, interfaces: [NetworkInterface]) throws -> String {
    if let override {
        return override
    }
    guard let tailscale = firstTailscaleAddress(in: interfaces) else {
        throw BindResolutionError.noTailscaleInterface
    }
    return tailscale
}

/// Enumerates the system's IPv4 interface addresses via getifaddrs.
public func systemInterfaces() -> [NetworkInterface] {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0 else { return [] }
    defer { freeifaddrs(addresses) }

    var result: [NetworkInterface] = []
    var cursor = addresses
    while let entry = cursor?.pointee {
        defer { cursor = entry.ifa_next }
        guard let socketAddress = entry.ifa_addr,
              socketAddress.pointee.sa_family == sa_family_t(AF_INET) else {
            continue
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { continue }
        result.append(
            NetworkInterface(
                name: String(cString: entry.ifa_name),
                address: String(cString: host)
            )
        )
    }
    return result
}
