import Foundation
import Testing
@testable import Tally

struct PartsTests {
    let mib: Int64 = 1024 * 1024

    @Test func slicesIntoFiftyMiBParts() {
        let parts = Parts.ranges(size: 120 * mib + 7, partSize: 50 * mib)
        #expect(parts.map(\.part) == [1, 2, 3])
        #expect(parts.map(\.offset) == [0, 50 * mib, 100 * mib])
        #expect(parts.map(\.length) == [Int(50 * mib), Int(50 * mib), Int(20 * mib + 7)])
    }

    @Test func exactMultipleHasNoEmptyTail() {
        let parts = Parts.ranges(size: 100 * mib, partSize: 50 * mib)
        #expect(parts.count == 2 && parts.last!.length == Int(50 * mib))
    }

    @Test func smallAndEmptyFiles() {
        #expect(Parts.ranges(size: 10, partSize: 50 * mib).map(\.length) == [10])
        #expect(Parts.ranges(size: 0, partSize: 50 * mib).isEmpty)
    }

    @Test func readsOnlyTheSlice() async throws {
        let url = URL.temporaryDirectory.appending(path: "slice-\(UUID().uuidString).bin")
        try Data((0..<100).map { UInt8($0) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let parts = Parts.ranges(size: 100, partSize: 40)
        var joined = Data()
        for p in parts { joined += try await Parts.read(url, offset: p.offset, length: p.length) }
        #expect(parts.map(\.length) == [40, 40, 20])
        #expect(joined == Data((0..<100).map { UInt8($0) }))
    }

    @Test func backoffGrowsAndCaps() {
        #expect(Parts.backoff(attempt: 1) == 5)
        #expect(Parts.backoff(attempt: 3) == 20)
        #expect(Parts.backoff(attempt: 30) == 600)
    }
}

struct AccessTests {
    @Test func accessLoginRedirectNeedsLogin() {
        let loc = "https://3mi.cloudflareaccess.com/cdn-cgi/access/login/records.3mi.ai?kid=abc&redirect_url=%2Fapi%2Ftemplates"
        #expect(Access.needsLogin(status: 302, location: loc))
        #expect(Access.needsLogin(status: 302, location: "/cdn-cgi/access/login/records.3mi.ai"))
    }

    @Test func unauthorizedStatuses() {
        #expect(Access.needsLogin(status: 401, location: nil))
        #expect(Access.needsLogin(status: 403, location: nil))
    }

    @Test func ordinaryResponsesDoNot() {
        #expect(!Access.needsLogin(status: 200, location: nil))
        #expect(!Access.needsLogin(status: 404, location: nil))
        #expect(!Access.needsLogin(status: 302, location: "https://records.3mi.ai/other"))
        #expect(!Access.needsLogin(status: 302, location: "https://evilcloudflareaccess.com/x"))
    }

    @Test func tokenFromCookies() {
        func cookie(_ name: String, _ domain: String, expires: Date? = nil) -> HTTPCookie {
            var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "jwt-\(domain)", .domain: domain, .path: "/"]
            if let expires { p[.expires] = expires }
            return HTTPCookie(properties: p)!
        }
        let host = "records.3mi.ai"
        #expect(LoginWebView.token(in: [cookie("other", host), cookie("CF_Authorization", host)], host: host) == "jwt-records.3mi.ai")
        #expect(LoginWebView.token(in: [cookie("CF_Authorization", "3mi.cloudflareaccess.com")], host: host) == nil)
        #expect(LoginWebView.token(in: [cookie("CF_Authorization", host, expires: .now.addingTimeInterval(-60))], host: host) == nil)
    }

    @Test func normalizesBackendAddress() {
        #expect(AppModel.normalize(" records.3mi.ai/ ")?.absoluteString == "https://records.3mi.ai")
        #expect(AppModel.normalize("http://127.0.0.1:8790")?.absoluteString == "http://127.0.0.1:8790")
        #expect(AppModel.normalize("ftp://x") == nil)
    }
}
