// ABOUTME: Tests for tailscale interface discovery and bind host resolution.
// ABOUTME: Pure functions get injected interface lists; no live network dependency.

import Foundation
import Testing
@testable import RemindersServer

@Suite("Tailscale interface discovery")
struct TailscaleInterfaceTests {

    @Test func findsFirstCGNATAddress() {
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1"),
            NetworkInterface(name: "en0", address: "192.168.1.20"),
            NetworkInterface(name: "utun4", address: "100.101.102.103"),
            NetworkInterface(name: "utun5", address: "100.99.1.2"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == "100.101.102.103")
    }

    @Test func matchesByAddressRangeNotInterfaceName() {
        // A utun interface outside the CGNAT range (another VPN) must not match.
        let interfaces = [
            NetworkInterface(name: "utun0", address: "10.8.0.2"),
            NetworkInterface(name: "weird0", address: "100.64.0.1"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == "100.64.0.1")
    }

    @Test func cgnatRangeEdges() {
        #expect(isTailscaleAddress("100.64.0.1"))
        #expect(isTailscaleAddress("100.127.255.254"))
        #expect(!isTailscaleAddress("100.63.255.255"))
        #expect(!isTailscaleAddress("100.128.0.1"))
        #expect(!isTailscaleAddress("10.0.0.1"))
        #expect(!isTailscaleAddress("not-an-ip"))
        #expect(!isTailscaleAddress("100.64.0"))
        #expect(!isTailscaleAddress("100.300.0.1"))
    }

    @Test func noTailscaleInterfaceReturnsNil() {
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1"),
            NetworkInterface(name: "en0", address: "192.168.1.20"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == nil)
    }

    @Test func bindOverrideWins() throws {
        #expect(try resolveBindHost(override: "127.0.0.1", interfaces: []) == "127.0.0.1")
    }

    @Test func missingTailscaleThrowsActionableError() {
        let interfaces = [NetworkInterface(name: "en0", address: "192.168.0.5")]
        #expect(throws: BindResolutionError.noTailscaleInterface) {
            try resolveBindHost(override: nil, interfaces: interfaces)
        }
        #expect(
            BindResolutionError.noTailscaleInterface.localizedDescription.contains("--bind")
        )
    }

    @Test func systemInterfacesIncludesLoopback() {
        // getifaddrs smoke test: every macOS machine has lo0 at 127.0.0.1.
        let interfaces = systemInterfaces()
        #expect(interfaces.contains { $0.name == "lo0" && $0.address == "127.0.0.1" })
    }
}
