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
        // mDNS-resolvable hostname for the TXT record. Peers build
        // `ws://<hostname>:<port>/room/<code>` from this and connect
        // straight through.
        //
        // `ProcessInfo.hostName` can return either the canonical mDNS
        // name (e.g. "canary-dry7t045gk.local") or the bare BSD hostname
        // (e.g. "mac") depending on whether the system has finished
        // resolving its `.local` name. The bare form is unresolvable to
        // peers, so prefer the stable `.local` answer from
        // `Host.current().names` when available, and fall back to
        // appending `.local` to whatever ProcessInfo gives us.
        let hostname: String = {
            let names = Host.current().names
            if let local = names.first(where: { $0.hasSuffix(".local") }) {
                return local
            }
            var bare = ProcessInfo.processInfo.hostName
            if !bare.hasSuffix(".local") { bare += ".local" }
            return bare
        }()
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

    public func publish() {
        Log.line("bonjour-pub", "publishing name=\(self.service.name) port=\(self.service.port)")
        self.service.publish()
    }
    public func stop() {
        Log.line("bonjour-pub", "stop name=\(self.service.name)")
        self.service.stop()
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Log.line("bonjour-pub", "publish FAILED: \(errorDict)")
    }

    public func netServiceDidPublish(_ sender: NetService) {
        Log.line("bonjour-pub", "publish succeeded: \(sender.name) port=\(sender.port)")
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

    /// Set when this room was sourced from the directory Worker
    /// rather than Bonjour. Carries the full `wss://*.trycloudflare.com/room/<code>`
    /// URL — `hostname/port` are unusable for tunnel-routed rooms
    /// (the host is not directly addressable on the LAN). When nil,
    /// `wsURL` falls back to the Bonjour-style construction below.
    public let wssURLOverride: URL?

    public init(
        id: String,
        name: String,
        roomCode: String,
        hostNick: String,
        cwd: String,
        hostname: String,
        port: Int,
        requiresJoinCode: Bool,
        wssURLOverride: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.roomCode = roomCode
        self.hostNick = hostNick
        self.cwd = cwd
        self.hostname = hostname
        self.port = port
        self.requiresJoinCode = requiresJoinCode
        self.wssURLOverride = wssURLOverride
    }

    /// WS URL to pass into `Lattice.Configuration.wssEndpoint`. The
    /// `last-event-id` query param is appended by the Lattice sync
    /// client itself; we just provide the base URL.
    public var wsURL: URL {
        if let override = wssURLOverride { return override }
        return URL(string: "ws://\(hostname):\(port)/room/\(roomCode)")!
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
        Log.line("bonjour-bro", "browser start")
        stop()
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: claudeCodeIRCServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let decoded = results
                .compactMap(Self.decode(result:))
                .sorted { $0.name < $1.name }
            Log.line("bonjour-bro", "results changed → \(decoded.count) rooms: \(decoded.map { "\($0.name)@\($0.hostname):\($0.port)" }.joined(separator: ", "))")
            self?.rooms = decoded
        }
        browser.start(queue: .main)
    }

    public func stop() {
        if browser != nil {
            Log.line("bonjour-bro", "browser stop")
        }
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
