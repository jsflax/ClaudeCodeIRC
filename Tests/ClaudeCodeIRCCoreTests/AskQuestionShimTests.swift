import Foundation
import Testing
import Lattice
import MCP
import System
import ClaudeCodeIRCCore

/// Integration tests for the AskUserQuestion branch of
/// `claudecodeirc --mcp-approve`. Spawns the real shim binary, drives
/// it with the MCP Swift SDK pointed at its stdio pipes, and observes
/// the resulting `AskQuestion` rows through a sibling Lattice handle.
///
/// Each test acts as the `AskVoteCoordinator` stand-in (writes the
/// terminal status directly rather than running a real coordinator).
/// Plumbing is inlined per-test rather than extracted into a helper:
/// `Lattice` isn't `Sendable`, so factoring spawn into an async
/// helper produces "sending 'env' risks causing data races" once we
/// `await` its return. Mirrors `ApprovalMcpShimXProcTests`'s style.
@Suite(.serialized) struct AskQuestionShimTests {

    @Test func singleSelectAnsweredRoundTrip() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-ask-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-ask-xproc-1", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("AskUserQuestion"),
                "input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Which framework?"),
                            "options":  .array([
                                .object(["label": .string("XCTest")]),
                                .object(["label": .string("swift-testing")]),
                            ]),
                            "multiSelect": .bool(false),
                        ]),
                    ]),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 1, timeoutSeconds: 10)
        let q = qs[0]
        #expect(q.header == "Which framework?")
        #expect(q.options.count == 2)
        #expect(q.multiSelect == false)
        #expect(q.status == AskStatus.pending)

        q.status = .answered
        q.chosenLabels = ["swift-testing"]
        q.answeredAt = Date()

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "deny")
        #expect((decision["message"] as? String) == "User responded: swift-testing")
    }

    @Test func multiQuestionGroupReply() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-ask-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-ask-xproc-2", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("AskUserQuestion"),
                "input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Dir?"),
                            "options": .array([.object(["label": .string("~/Projects")])]),
                            "multiSelect": .bool(false),
                        ]),
                        .object([
                            "question": .string("Test framework?"),
                            "options": .array([.object(["label": .string("XCTest")])]),
                            "multiSelect": .bool(false),
                        ]),
                    ]),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 2, timeoutSeconds: 10)
        #expect(qs.count == 2)
        qs[0].status = .answered
        qs[0].chosenLabels = ["~/Projects"]
        qs[1].status = .answered
        qs[1].chosenLabels = ["XCTest"]

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "deny")
        let message = decision["message"] as? String ?? ""
        #expect(message.hasPrefix("User responded:"))
        #expect(message.contains("~/Projects"))
        #expect(message.contains("XCTest"))
    }

    @Test func multiSelectReplyShape() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-ask-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-ask-xproc-3", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("AskUserQuestion"),
                "input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("Features?"),
                            "options": .array([
                                .object(["label": .string("oauth")]),
                                .object(["label": .string("ratelimit")]),
                                .object(["label": .string("metrics")]),
                            ]),
                            "multiSelect": .bool(true),
                        ]),
                    ]),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 1, timeoutSeconds: 10)
        let q = qs[0]
        #expect(q.multiSelect == true)
        q.status = .answered
        q.chosenLabels = ["oauth", "ratelimit"]

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        let message = decision["message"] as? String ?? ""
        #expect(message.contains("\"oauth\""))
        #expect(message.contains("\"ratelimit\""))
        #expect(!message.contains("metrics"))
    }

    @Test func exitPlanModeApprovedAutoMode() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-plan-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))

        // Seed a Session so the shim's setSessionMode has a row to
        // mutate. Without this, the mode write silently no-ops and
        // the test can't observe the flip. permissionMode starts at
        // .default to make the .auto flip detectable.
        let seeded = Session()
        seeded.code = "ask-xproc-test"
        seeded.name = "test"
        seeded.cwd = "/tmp"
        seeded.permissionMode = .default
        testLattice.add(seeded)

        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-plan-xproc-1", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("ExitPlanMode"),
                "input": .object([
                    "plan": .string("# my plan\n\nstep 1\nstep 2"),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 1, timeoutSeconds: 10)
        let q = qs[0]
        #expect(q.options.count == 4)
        #expect(q.header == "# my plan\n\nstep 1\nstep 2")

        q.status = .answered
        q.chosenLabels = ["Yes — auto mode"]
        q.answeredAt = Date()

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "allow")

        // Side-effect: session.permissionMode should now be .auto.
        // Refetch from the same testLattice — the shim writes via
        // its own handle on the same SQLite file.
        guard let session = testLattice.objects(Session.self).first
        else { Issue.record("session row vanished"); return }
        #expect(session.permissionMode == .auto)
    }

    @Test func exitPlanModeDeclinedWithReason() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-plan-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))

        let seeded = Session()
        seeded.code = "ask-xproc-test"
        seeded.permissionMode = .default
        testLattice.add(seeded)

        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-plan-xproc-2", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("ExitPlanMode"),
                "input": .object([
                    "plan": .string("rewrite the auth flow"),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 1, timeoutSeconds: 10)
        let q = qs[0]
        // Free-text answer via Other… would land here as a custom
        // label. Test the shim's "any label not in the canonical 4"
        // path by setting chosenLabels directly.
        q.status = .answered
        q.chosenLabels = ["too risky"]
        q.answeredAt = Date()

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "deny")
        let message = decision["message"] as? String ?? ""
        #expect(message == "User declined the plan: too risky")

        // Side-effect: mode stays at .default — decline shouldn't
        // touch session.permissionMode.
        guard let session = testLattice.objects(Session.self).first
        else { Issue.record("session row vanished"); return }
        #expect(session.permissionMode == .default)
    }

    @Test func cancelledReturnsDeclineMessage() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-ask-shim-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
        let process = try spawnShim(binPath: binPath, latticePath: tmp.path)
        defer { if process.process.isRunning { process.process.terminate() } }
        let client = Client(name: "ccirc-ask-xproc-4", version: "1")
        _ = try await client.connect(transport: process.transport)
        defer { Task { await client.disconnect() } }

        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("AskUserQuestion"),
                "input": .object([
                    "questions": .array([
                        .object([
                            "question": .string("?"),
                            "options": .array([.object(["label": .string("a")])]),
                            "multiSelect": .bool(false),
                        ]),
                    ]),
                ]),
            ])

        let qs = try await waitForAskQuestions(
            testLattice: testLattice, expecting: 1, timeoutSeconds: 10)
        let q = qs[0]
        q.status = .cancelled
        q.cancelReason = "claude subprocess exited"
        q.answeredAt = Date()

        let json = try await decisionJson(callResult)
        let decision = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "deny")
        let message = decision["message"] as? String ?? ""
        #expect(message == "User declined to answer: claude subprocess exited")
    }

    // MARK: - Helpers (sync only — no awaits → no actor crossings)

    private struct ShimProcess {
        let process: Process
        let transport: StdioTransport
    }

    private func spawnShim(binPath: String, latticePath: String) throws -> ShimProcess {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = [
            "--mcp-approve",
            "--room-code", "ask-xproc-test",
            "--lattice-path", latticePath,
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            FileHandle.standardError.write(data)
        }
        let clientInput = FileDescriptor(
            rawValue: stdout.fileHandleForReading.fileDescriptor)
        let clientOutput = FileDescriptor(
            rawValue: stdin.fileHandleForWriting.fileDescriptor)
        return ShimProcess(
            process: process,
            transport: StdioTransport(input: clientInput, output: clientOutput))
    }

    /// Poll the test-side lattice for inserted `AskQuestion` rows
    /// until at least `count` exist, or the timeout fires. Avoids
    /// the AsyncStream + Task.detached + lattice.changeStream
    /// pattern, which was hanging indefinitely in this test
    /// (cooperative cancellation via `withTaskGroup` failed to
    /// unblock `it.next()` on a 10s timeout).
    private func waitForAskQuestions(
        testLattice: Lattice,
        expecting count: Int,
        timeoutSeconds: Int
    ) async throws -> [AskQuestion] {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            let rows = Array(testLattice.objects(AskQuestion.self))
            if rows.count >= count {
                return rows.sorted { $0.groupIndex < $1.groupIndex }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestError.timeout
    }

    private func decisionJson(
        _ result: (content: [Tool.Content], isError: Bool?)
    ) async throws -> String {
        #expect(result.isError != true)
        guard case .text(let json, _, _) = result.content.first else {
            throw TestError.badShape
        }
        return json
    }

    enum TestError: Error, CustomStringConvertible {
        case binaryNotFound
        case timeout
        case badShape

        var description: String {
            switch self {
            case .binaryNotFound: return "could not find claudecodeirc binary"
            case .timeout:        return "timed out waiting for shim row"
            case .badShape:       return "unexpected MCP reply shape"
            }
        }
    }

    private func locateCCIRCBinary() throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appending(path: "Package.swift").path) {
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let buildDir = dir.appending(path: ".build")
        guard let arch = try? FileManager.default
            .contentsOfDirectory(atPath: buildDir.path)
            .first(where: { $0.contains("apple-macosx") })
        else { throw TestError.binaryNotFound }
        let candidate = buildDir
            .appending(path: arch)
            .appending(path: "debug")
            .appending(path: "claudecodeirc")
        guard FileManager.default.isExecutableFile(atPath: candidate.path)
        else { throw TestError.binaryNotFound }
        return candidate.path
    }

}
