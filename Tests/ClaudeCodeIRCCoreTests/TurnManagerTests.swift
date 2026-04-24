import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Covers `TurnManager`'s buffering + flushing without a real
/// subprocess. A `FakeDriver` records every `send()` and lets the
/// test manipulate whether a Turn is considered complete by
/// updating the Lattice `Turn.status` directly.
@Suite struct TurnManagerTests {

    /// Minimal `ClaudeDriver` stand-in. Records `send` invocations so
    /// tests can assert on prompt content and call count without any
    /// real `claude -p` subprocess.
    actor FakeDriver: ClaudeDriver {
        struct Call: Sendable {
            let prompt: String
            let hasRef: Bool
        }
        private(set) var calls: [Call] = []

        func send(
            prompt: String,
            promptMessageRef: ModelThreadSafeReference<ChatMessage>?
        ) throws {
            calls.append(Call(prompt: prompt, hasRef: promptMessageRef != nil))
        }

        func stop() async {}
    }

    /// File-backed temp lattice. In-memory lattices don't support
    /// `SendableReference.resolve(on:)` the way file-backed ones do;
    /// use a throwaway temp file per test so the manager's
    /// `sessionRef.resolve(...)` succeeds.
    private func freshLattice() throws -> Lattice {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-turn-mgr-\(UUID().uuidString).lattice")
        return try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: url))
    }

    private func seedSessionAndMember(
        _ lattice: Lattice,
        code: String = "test",
        nick: String = "alice"
    ) -> (Session, Member) {
        let session = Session()
        session.code = code
        lattice.add(session)

        let member = Member()
        member.nick = nick
        member.session = session
        lattice.add(member)

        return (session, member)
    }

    private func insert(
        _ text: String,
        kind: MessageKind,
        side: Bool,
        session: Session,
        author: Member?,
        on lattice: Lattice
    ) -> ChatMessage {
        let msg = ChatMessage()
        msg.text = text
        msg.kind = kind
        msg.side = side
        msg.author = author
        msg.session = session
        lattice.add(msg)
        return msg
    }

    // MARK: - Mention triggers fire

    @Test func mentionFiresDriver() async throws {
        let lattice = try freshLattice()
        let (session, alice) = seedSessionAndMember(lattice)
        let driver = FakeDriver()
        let mgr = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)

        let msg = insert("@claude hello",
            kind: .user, side: false, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: msg.globalId!)

        let calls = await driver.calls
        #expect(calls.count == 1)
        #expect(calls[0].prompt == "alice: @claude hello")
        #expect(calls[0].hasRef)
    }

    // MARK: - Context accumulates

    @Test func intraTurnContextPrepended() async throws {
        let lattice = try freshLattice()
        let (session, alice) = seedSessionAndMember(lattice)
        let bob = Member()
        bob.nick = "bob"
        bob.session = session
        lattice.add(bob)

        let driver = FakeDriver()
        let mgr = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)

        let m1 = insert("morning folks",
            kind: .user, side: false, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: m1.globalId!)

        let m2 = insert("did the build break?",
            kind: .user, side: false, session: session, author: bob, on: lattice)
        await mgr.ingest(globalId: m2.globalId!)

        let m3 = insert("@claude any idea?",
            kind: .user, side: false, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: m3.globalId!)

        let calls = await driver.calls
        #expect(calls.count == 1)
        #expect(calls[0].prompt == """
            alice: morning folks
            bob: did the build break?
            alice: @claude any idea?
            """)
    }

    // MARK: - Side + system + assistant messages skipped

    @Test func sideMessagesDoNotBufferOrTrigger() async throws {
        let lattice = try freshLattice()
        let (session, alice) = seedSessionAndMember(lattice)
        let driver = FakeDriver()
        let mgr = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)

        // `/side` message — should NOT buffer.
        let side = insert("lmao",
            kind: .user, side: true, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: side.globalId!)

        // Even mentioning @claude in a side message must not fire.
        let sideMention = insert("@claude irrelevant",
            kind: .user, side: true, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: sideMention.globalId!)

        // A real mention after: prompt should contain only THIS
        // message — the side ones above were skipped.
        let real = insert("@claude real one",
            kind: .user, side: false, session: session, author: alice, on: lattice)
        await mgr.ingest(globalId: real.globalId!)

        let calls = await driver.calls
        #expect(calls.count == 1)
        #expect(calls[0].prompt == "alice: @claude real one")
    }

    @Test func systemMessagesSkipped() async throws {
        let lattice = try freshLattice()
        let (session, alice) = seedSessionAndMember(lattice)
        let driver = FakeDriver()
        let mgr = try await TurnManager(
            driver: driver,
            latticeRef: lattice.sendableReference,
            sessionRef: session.sendableReference)

        // `/help` output etc. is a system message — skip entirely.
        let sys = insert("help text",
            kind: .system, side: true, session: session, author: nil, on: lattice)
        await mgr.ingest(globalId: sys.globalId!)

        let calls = await driver.calls
        #expect(calls.isEmpty)
    }

    // MARK: - Assembly helper

    @Test func assemblePromptShape() throws {
        let lattice = try freshLattice()
        let (session, alice) = seedSessionAndMember(lattice)

        let m1 = insert("line 1",
            kind: .user, side: false, session: session, author: alice, on: lattice)
        let m2 = insert("line 2",
            kind: .user, side: false, session: session, author: alice, on: lattice)

        let prompt = TurnManager.assemblePrompt([m1, m2])
        #expect(prompt == "alice: line 1\nalice: line 2")
    }

    @Test func assemblePromptHandlesMissingNick() throws {
        let lattice = try freshLattice()
        let (session, _) = seedSessionAndMember(lattice)
        // Message without an author — should fall back to "?" rather
        // than crashing on force-unwrap.
        let m = insert("ghost",
            kind: .user, side: false, session: session, author: nil, on: lattice)
        let prompt = TurnManager.assemblePrompt([m])
        #expect(prompt == "?: ghost")
    }
}
