import Foundation
import Testing
import Lattice
import MCP
import System
import ClaudeCodeIRCCore

/// Integration test for the `claudecodeirc --mcp-approve` flow: spawns
/// the real shim binary as a subprocess, drives it with the MCP Swift
/// SDK's `Client` pointed at the subprocess's stdio pipes, observes
/// the resulting `ApprovalRequest` row through a sibling Lattice
/// handle on the same temp file via `changeStream`, flips the row to
/// `.approved`, and asserts the shim's MCP reply round-trips back
/// with the correct decision.
///
/// Covers the app-layer xproc flow: `shim writes → TUI observes →
/// decision written → shim wakes`. LatticeCore's own xproc tests
/// cover the notifier primitive underneath.
@Suite(.serialized) struct ApprovalMcpShimXProcTests {

    @Test func approvalRoundTripsCrossProcess() async throws {
        let binPath = try locateCCIRCBinary()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-shim-xproc-\(UUID().uuidString).lattice")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Test-side handle on the same file the shim will open. Changes
        // the shim writes show up here via LatticeCore's xproc notifier.
        let testLattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))

        // Wire stdio pipes ourselves so we can hand the raw fds to
        // the MCP SDK's StdioTransport. The client's `input` is what
        // it reads from (= shim's stdout); its `output` is what it
        // writes to (= shim's stdin).
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        process.arguments = [
            "--mcp-approve",
            "--room-code", "xproc-test",
            "--lattice-path", tmp.path,
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Drain the shim's stderr so it can't fill and block the shim.
        // We don't read it in the test — Log.line output is only useful
        // for debugging a failed run, so just dump to our own stderr.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            FileHandle.standardError.write(data)
        }

        // StdioTransport takes SystemPackage FileDescriptors. Build
        // them from the Pipe's integer file descriptors. `closeOnDeinit`
        // is false because the Pipe owns the fds.
        let clientInput = FileDescriptor(
            rawValue: stdout.fileHandleForReading.fileDescriptor)
        let clientOutput = FileDescriptor(
            rawValue: stdin.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: clientInput, output: clientOutput)

        let client = Client(name: "ccirc-xproc-test", version: "1")
        // `connect(transport:)` performs the MCP initialize +
        // initialized handshake internally — no hand-rolled JSON-RPC.
        _ = try await client.connect(transport: transport)
        defer { Task { await client.disconnect() } }

        // Subscribe BEFORE calling the tool so we can't miss the
        // insert. The observer yields the ApprovalRequest's globalId
        // (Sendable UUID); we re-resolve on the test actor.
        let latticeRef = testLattice.sendableReference
        let pendingGidStream = AsyncStream<UUID> { continuation in
            Task.detached {
                guard let lt = latticeRef.resolve() else {
                    continuation.finish()
                    return
                }
                for await refs in lt.changeStream {
                    for ref in refs {
                        guard let entry = ref.resolve(on: lt) else { continue }
                        if entry.tableName == "ApprovalRequest",
                           entry.operation == .insert,
                           let gid = entry.globalRowId,
                           let req = lt.object(ApprovalRequest.self, globalId: gid),
                           req.status == ApprovalStatus.pending {
                            continuation.yield(gid)
                            continuation.finish()
                            return
                        }
                    }
                }
                continuation.finish()
            }
        }

        // Kick off the tool call and the row-flip in parallel. The
        // shim blocks inside its handler on `changeStream` until our
        // flip lands, then returns the decision back through MCP.
        async let callResult = client.callTool(
            name: "approve",
            arguments: [
                "tool_name": .string("Bash"),
                "input": .object(["command": .string("touch /tmp/ccirc-xproc-test")]),
            ])

        // Wait for the shim's row, flip it, with a timeout to keep
        // CI from hanging on a regression.
        let gid = try await withTimeout(seconds: 10) { () -> UUID in
            var it = pendingGidStream.makeAsyncIterator()
            guard let g = await it.next() else {
                throw TestError.observeFailed
            }
            return g
        }
        guard let req = testLattice.object(ApprovalRequest.self, globalId: gid)
        else { throw TestError.observeFailed }
        #expect(req.toolName == "Bash")
        #expect(req.status == ApprovalStatus.pending)
        req.status = ApprovalStatus.approved
        req.decidedAt = Date()

        let (content, isError) = try await callResult
        #expect(isError != true)
        guard case .text(let decisionJson, _, _) = content.first else {
            throw TestError.badShape
        }
        let decision = try JSONSerialization.jsonObject(
            with: Data(decisionJson.utf8)) as! [String: Any]
        #expect(decision["behavior"] as? String == "allow")
    }

    // MARK: - Helpers

    private func locateCCIRCBinary() throws -> String {
        // Walk up from #file until we find the SPM package root (the
        // directory containing `Package.swift`), then look for
        // `.build/*/debug/claudecodeirc`. Avoids hardcoding an arch
        // folder so the test works on both Apple Silicon and Intel.
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

    private func withTimeout<T: Sendable>(
        seconds: Int,
        _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TestError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    enum TestError: Error, CustomStringConvertible {
        case binaryNotFound
        case observeFailed
        case timeout
        case badShape

        var description: String {
            switch self {
            case .binaryNotFound: return "could not find claudecodeirc binary"
            case .observeFailed:  return "ApprovalRequest never observed"
            case .timeout:        return "timed out waiting for shim"
            case .badShape:       return "unexpected MCP reply shape"
            }
        }
    }
}
