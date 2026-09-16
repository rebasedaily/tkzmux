// HookSocketTests — the per-instance socket name both the pty environment and the hook server
// derive from a pid.
import Foundation
import Testing

@testable import TkzCore

@Suite struct HookSocketTests {
    @Test func nameIsPrefixPidSuffix() {
        #expect(HookSocket.fileName(pid: 4242) == "tkzmux-4242.sock")
        #expect(HookSocket.fileName(pid: 1) == "tkzmux-1.sock")
        let dir = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        #expect(HookSocket.url(in: dir, pid: 4242).path == "/tmp/support/tkzmux-4242.sock")
        #expect(!HookSocket.url(in: dir, pid: 4242).hasDirectoryPath)
    }

    /// Only `tkzmux-<digits>.sock` is an instance socket. The legacy per-install `tkzmux.sock`
    /// is not, so a file left by a pre-upgrade build is never swept, nor is anything else in the
    /// support directory.
    @Test func recognisesOnlyInstanceSockets() {
        for name in ["tkzmux-1.sock", "tkzmux-4242.sock", "tkzmux-99999.sock"] {
            #expect(HookSocket.isInstanceSocket(name), "\(name)")
        }
        for name in [
            "tkzmux.sock", "tkzmux-.sock", "tkzmux-1.sock.tmp", "tkzmux-1.sock.bak", "tkzmux-x1.sock",
            "tkzmux-1x.sock", "tkzmux-１.sock", "state.json", "sessions", "", "tkzmux-1",
        ] {
            #expect(!HookSocket.isInstanceSocket(name), "\(name)")
        }
    }

    /// `sun_path` holds 104 bytes including the NUL. The support directory is under the user's
    /// home, so the budget is the user name's; a 43-character one still fits with a 5-digit pid.
    @Test func pathFitsSunPathForALongUserName() {
        let user = String(repeating: "u", count: 43)
        let dir = URL(filePath: "/Users/\(user)/Library/Application Support/tkzmux", directoryHint: .isDirectory)
        #expect(HookSocket.url(in: dir, pid: 99999).path.utf8.count < 104)
    }
}
