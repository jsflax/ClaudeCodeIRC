import Foundation
import Testing
import ClaudeCodeIRCCore

/// Exercises `DirectoryPublisher` and `DirectoryClient` against a
/// stub `URLProtocol` that intercepts every `URLSession` request and
/// hands back a scripted response. No real Worker / network involved.
///
/// The stub stores requests in a shared array so tests can assert on
/// them after the fact (verifying payload shape, method, URL). One
/// stub state per test — each test sets `StubURLProtocol.script`
/// before exercising the actor.
@MainActor
@Suite(.serialized) struct DirectoryHTTPTests {

    // MARK: - Stub URL protocol

    /// Records every request and replies according to a scripted
    /// response. Routes by method + path so a single test can
    /// configure publish + delete + list responses simultaneously.
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Response { let status: Int; let body: Data }

        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var responses: [String: Response] = [:]
        nonisolated(unsafe) private static let lock = NSLock()

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            requests = []
            responses = [:]
        }

        static func record(_ req: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            requests.append(req)
        }

        static func response(for req: URLRequest) -> Response? {
            lock.lock(); defer { lock.unlock() }
            let key = "\(req.httpMethod ?? "GET") \(req.url?.path ?? "")"
            return responses[key]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // Capture the body — `URLProtocol` strips it from the
            // request for streamed bodies, but our publisher uses
            // `httpBody` directly.
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                var data = Data()
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { buf.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buf, maxLength: 4096)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                }
                stream.close()
                captured.httpBody = data
            }
            Self.record(captured)

            let resp = Self.response(for: request)
                ?? Response(status: 200, body: "{\"ok\":true}".data(using: .utf8)!)
            let httpResp = HTTPURLResponse(
                url: request.url!,
                statusCode: resp.status,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: httpResp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: resp.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeStubbedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private let endpoint = URL(string: "https://stub.test")!

    /// Tiny Sendable counter for `publishVersion` round-trips. Plain
    /// captured `var Int` from a `@Sendable` closure crosses the
    /// actor boundary into `DirectoryPublisher`, which the strict-
    /// concurrency checker rejects. An actor-isolated wrapper is the
    /// minimal Sendable shape.
    actor VersionCounter {
        private var value: Int
        init(_ initial: Int) { self.value = initial }
        func get() -> Int { value }
        func set(_ v: Int) { value = v }
    }

    // MARK: - DirectoryPublisher

    @Test func publishSendsExpectedPayloadShape() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["POST /publish"] = .init(
            status: 200,
            body: #"{"ok":true,"ttlRemaining":180,"knownVersions":[1]}"#.data(using: .utf8)!)

        let testURL = URL(string: "wss://abc.trycloudflare.com/room/swap42")!
        let counter = VersionCounter(0)
        let pub = DirectoryPublisher(
            endpoint: endpoint,
            roomId: "swap42",
            roomName: "test-room",
            hostHandle: "alice",
            groupId: "public",
            requireJoinCode: false,
            wssURLProvider: { testURL },
            publishVersionProvider: { await counter.get() },
            publishVersionConsumer: { await counter.set($0) },
            urlSession: makeStubbedSession())

        // Drive a single publish via `nudge()` instead of starting the
        // 30s heartbeat.
        await pub.nudge()

        // Verify exactly one POST /publish landed with the expected
        // payload shape.
        let posts = StubURLProtocol.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path == "/publish"
        }
        #expect(posts.count == 1)
        guard let body = posts.first?.httpBody else { Issue.record("missing body"); return }
        let payload = try JSONDecoder().decode(
            DirectoryAPI.PublishRequest.self, from: body)
        #expect(payload.version == 1)
        #expect(payload.roomId == "swap42")
        #expect(payload.name == "test-room")
        #expect(payload.hostHandle == "alice")
        #expect(payload.wssURL == testURL.absoluteString)
        #expect(payload.groupId == "public")
        #expect(payload.publishVersion == 1)
        let savedVersion = await counter.get()
        #expect(savedVersion == 1, "consumer must be invoked on success")
    }

    @Test func publishSkipsWhenWssURLNil() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["POST /publish"] = .init(status: 200, body: Data("{}".utf8))

        let pub = DirectoryPublisher(
            endpoint: endpoint,
            roomId: "rm",
            roomName: "n",
            hostHandle: "h",
            groupId: "public",
            requireJoinCode: false,
            wssURLProvider: { nil },        // tunnel hasn't resolved
            publishVersionProvider: { 0 },
            publishVersionConsumer: { _ in },
            urlSession: makeStubbedSession())

        await pub.nudge()

        #expect(StubURLProtocol.requests.isEmpty,
            "publisher must skip when wssURL provider returns nil")
    }

    @Test func publish409JumpsVersionAhead() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["POST /publish"] = .init(
            status: 409,
            body: #"{"error":"stale_publish_version","current":42}"#.data(using: .utf8)!)

        let counter = VersionCounter(5)
        let pub = DirectoryPublisher(
            endpoint: endpoint,
            roomId: "rm",
            roomName: "n",
            hostHandle: "h",
            groupId: "public",
            requireJoinCode: false,
            wssURLProvider: { URL(string: "wss://x/room/rm")! },
            publishVersionProvider: { await counter.get() },
            publishVersionConsumer: { await counter.set($0) },
            urlSession: makeStubbedSession())

        await pub.nudge()

        // Implementation: nextVersion = 6, sends 6, 409 → bumps to 6+100=106.
        let savedVersion = await counter.get()
        #expect(savedVersion >= 100,
            "stale-version response must fast-forward the counter; got \(savedVersion)")
    }

    @Test func stopSendsDeleteAndCancelsHeartbeat() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["POST /publish"] = .init(status: 200, body: Data("{}".utf8))
        StubURLProtocol.responses["DELETE /publish/rm99"] = .init(status: 200, body: Data("{}".utf8))

        let pub = DirectoryPublisher(
            endpoint: endpoint,
            roomId: "rm99",
            roomName: "n",
            hostHandle: "h",
            groupId: "public",
            requireJoinCode: false,
            wssURLProvider: { URL(string: "wss://x/room/rm99")! },
            publishVersionProvider: { 0 },
            publishVersionConsumer: { _ in },
            urlSession: makeStubbedSession())

        await pub.start()
        try await Task.sleep(for: .milliseconds(50))   // let first publish fire
        await pub.stop()

        let deletes = StubURLProtocol.requests.filter {
            $0.httpMethod == "DELETE" && $0.url?.path == "/publish/rm99"
        }
        #expect(deletes.count == 1, "stop must send a DELETE")
    }

    // MARK: - DirectoryClient

    @Test func listYieldsSnapshotOnStream() async throws {
        StubURLProtocol.reset()
        let listBody = """
            {"version":1,"rooms":[
              {"roomId":"r1","name":"alpha","hostHandle":"alice","wssURL":"wss://a/room/r1","lastSeenAge":3,"requireJoinCode":false}
            ]}
            """
        StubURLProtocol.responses["GET /list"] = .init(
            status: 200,
            body: Data(listBody.utf8))

        let client = DirectoryClient(
            endpointProvider: { self.endpoint },
            groupIdsProvider: { ["public"] },
            urlSession: makeStubbedSession())

        let stream = client.roomsByGroupStream
        await client.start()

        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        await client.stop()

        #expect(snapshot != nil)
        #expect(snapshot?["public"]?.count == 1)
        #expect(snapshot?["public"]?.first?.name == "alpha")
        #expect(snapshot?["public"]?.first?.wssURL == "wss://a/room/r1")
    }

    @Test func listAccumulatesMultipleGroupBuckets() async throws {
        StubURLProtocol.reset()
        // The stub keys responses by method+path, so both `/list?group=public`
        // and `/list?group=k7Lp` hit the same `GET /list` slot. Use a
        // single response that the test asserts is fetched twice.
        StubURLProtocol.responses["GET /list"] = .init(
            status: 200,
            body: Data(#"{"version":1,"rooms":[]}"#.utf8))

        let client = DirectoryClient(
            endpointProvider: { self.endpoint },
            groupIdsProvider: { ["public", "k7Lp"] },
            urlSession: makeStubbedSession())

        await client.start()
        // Wait for the first cycle to complete (yields one snapshot).
        var iterator = client.roomsByGroupStream.makeAsyncIterator()
        _ = await iterator.next()
        await client.stop()

        let lists = StubURLProtocol.requests.filter {
            $0.httpMethod == "GET" && $0.url?.path == "/list"
        }
        #expect(lists.count >= 2,
            "client must hit /list once per groupId per cycle")
        let queryStrings = lists.compactMap { $0.url?.query }
        #expect(queryStrings.contains { $0.contains("group=public") })
        #expect(queryStrings.contains { $0.contains("group=k7Lp") })
    }

    @Test func listGracefullyHandlesNon200() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.responses["GET /list"] = .init(
            status: 500, body: Data("server error".utf8))

        let client = DirectoryClient(
            endpointProvider: { self.endpoint },
            groupIdsProvider: { ["public"] },
            urlSession: makeStubbedSession())

        await client.start()
        var iterator = client.roomsByGroupStream.makeAsyncIterator()
        let snapshot = await iterator.next()
        await client.stop()

        #expect(snapshot?["public"] == [],
            "non-200 must surface as an empty bucket, not a missing one")
    }
}
