import Foundation
import Network

/// Shared service-type constant used by both the publisher and browser.
/// Form is `_<service>._<proto>.` per RFC 6335.
public let claudeCodeIRCServiceType = "_claudecodeirc._tcp"

// MARK: - Publisher

/// Advertises a hosted room on the LAN.
///
/// Uses `NetService` rather than `NWListener` because NIO already owns
/// the WebSocket listening socket — we only need to advertise the port
/// NIO picked, not bind another. TXT record carries the room code and
/// host nick; the join code is deliberately NOT in the TXT (shared
/// out-of-band for bearer auth).
public final class BonjourPublisher: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService

    public init(
        name: String,
        port: Int32,
        roomCode: String,
        hostNick: String,
        cwd: String,
        requiresJoinCode: Bool
    ) {
        self.service = NetService(
            domain: "", type: claudeCodeIRCServiceType + ".",
            name: name, port: port)
        super.init()
        service.delegate = self
        // Carry the host machine's mDNS name and port in the TXT record
        // so a browser can build the WS URL without needing to open a
        // transient NWConnection just to resolve the endpoint. The `auth`
        // flag ("1"/"0") tells the lobby whether to prompt for a join
        // code or connect straight through.
        let hostname = ProcessInfo.processInfo.hostName   // "foo.local"
        let txt: [String: Data] = [
            "code": Data(roomCode.utf8),
            "host": Data(hostNick.utf8),
            "cwd": Data(cwd.utf8),
            "hostname": Data(hostname.utf8),
            "port": Data(String(port).utf8),
            "auth": Data((requiresJoinCode ? "1" : "0").utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
    }

    public func publish() { service.publish() }
    public func stop() { service.stop() }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        FileHandle.standardError.write(Data("[bonjour] publish failed: \(errorDict)\n".utf8))
    }
}

// MARK: - Discovered room (view model)

/// A room seen on the network by the browser. `Identifiable` so `List`
/// can render + track it.
public struct DiscoveredRoom: Identifiable, Hashable, Sendable {
    public let id: String       // Bonjour service name (unique on LAN)
    public let name: String     // same as id, kept separate for clarity
    public let roomCode: String
    public let hostNick: String
    public let cwd: String
    public let hostname: String // e.g. "foos-mbp.local"
    public let port: Int
    /// `true` when the host's Bonjour TXT advertised `auth=1`. Older
    /// hosts that pre-date the flag default to `true` (safer assumption —
    /// lobby prompts for a code rather than silently joining).
    public let requiresJoinCode: Bool

    /// WS URL to pass into `Lattice.Configuration.wssEndpoint`. The
    /// `last-event-id` query param is appended by the Lattice sync
    /// client itself; we just provide the base URL.
    public var wsURL: URL {
        URL(string: "ws://\(hostname):\(port)/room/\(roomCode)")!
    }
}

// MARK: - Browser

/// Discovers ClaudeCodeIRC rooms on the LAN. `@Observable` so the TUI
/// can drive a `List` off `.rooms` and auto-redraw when peers come and
/// go.
///
/// Thread-safety: NWBrowser callbacks are dispatched on the queue we
/// hand it (`.main`), so all writes to `rooms` serialize there. Views
/// read from MainActor during their body evaluation — no isolation
/// annotations needed on this class.
@Observable
public final class BonjourBrowser: @unchecked Sendable {
    public private(set) var rooms: [DiscoveredRoom] = []

    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: claudeCodeIRCServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.rooms = results
                .compactMap(Self.decode(result:))
                .sorted { $0.name < $1.name }
        }
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        rooms = []
    }

    /// Decode a browse result into a `DiscoveredRoom`. Only results with
    /// a TXT record carrying `code` qualify — strays from misconfigured
    /// peers just get skipped.
    private static func decode(result: NWBrowser.Result) -> DiscoveredRoom? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        guard let code = txt["code"], !code.isEmpty,
              let hostname = txt["hostname"], !hostname.isEmpty,
              let portStr = txt["port"], let port = Int(portStr) else {
            return nil
        }
        // auth flag: "1" = required, "0" = open, missing = assume required
        let requiresJoinCode = (txt["auth"] ?? "1") != "0"
        return DiscoveredRoom(
            id: name,
            name: name,
            roomCode: code,
            hostNick: txt["host"] ?? "?",
            cwd: txt["cwd"] ?? "",
            hostname: hostname,
            port: port,
            requiresJoinCode: requiresJoinCode)
    }
}
