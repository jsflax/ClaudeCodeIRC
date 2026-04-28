import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Helper: open a Lattice instance with the full ClaudeCodeIRC schema at a
/// random temp path. Each test gets an isolated DB file.
private func makeTempLattice() throws -> Lattice {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "ClaudeCodeIRC-tests-\(UUID().uuidString).lattice")
    return try Lattice(
        for: RoomStore.schema,
        configuration: .init(fileURL: tmp))
}

@Suite struct SchemaTests {
    @Test func schemaOpens() throws {
        _ = try makeTempLattice()
    }

    @Test func roundTripsSessionMemberChatMessage() throws {
        let lattice = try makeTempLattice()

        let session = Session()
        session.code = "river-lamp-piano-tea"
        session.name = "test room"
        session.cwd = "/tmp"
        lattice.add(session)

        let alice = Member()
        alice.nick = "alice"
        alice.isHost = true
        alice.session = session
        lattice.add(alice)

        let msg = ChatMessage()
        msg.text = "hello"
        msg.author = alice
        msg.session = session
        lattice.add(msg)

        // Back-reads via the inverse @Relation accessors.
        #expect(session.members.count == 1)
        #expect(session.members.first?.nick == "alice")
        #expect(session.messages.count == 1)
        #expect(session.messages.first?.text == "hello")
        #expect(alice.authored.count == 1)
    }

    @Test func turnAccumulatesAssistantChunks() throws {
        let lattice = try makeTempLattice()

        let session = Session()
        session.code = "abcd-efgh"
        lattice.add(session)

        let turn = Turn()
        turn.status = .streaming
        turn.session = session
        lattice.add(turn)

        for i in 0..<5 {
            let chunk = AssistantChunk()
            chunk.chunkIndex = i
            chunk.text = "chunk\(i) "
            chunk.turn = turn
            lattice.add(chunk)
        }

        #expect(turn.chunks.count == 5)
        let joined = turn.chunks
            .sorted { $0.chunkIndex < $1.chunkIndex }
            .map(\.text)
            .joined()
        #expect(joined == "chunk0 chunk1 chunk2 chunk3 chunk4 ")
    }

    @Test func approvalRequestLinkedToToolEvent() throws {
        let lattice = try makeTempLattice()

        let tool = ToolEvent()
        tool.name = "Bash"
        tool.input = #"{"command":"ls"}"#
        tool.status = .pending
        lattice.add(tool)

        let approval = ApprovalRequest()
        approval.summary = "Bash: ls"
        approval.toolEvent = tool
        lattice.add(approval)

        tool.approval = approval

        #expect(tool.approval != nil)
        #expect(approval.toolEvent?.name == "Bash")
    }

}
