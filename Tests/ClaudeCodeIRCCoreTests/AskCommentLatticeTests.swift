import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Round-trip checks for the `AskQuestion.comments: List<AskComment>`
/// relationship. The list is parent-owned via the link table (keyed by
/// globalId), so insertion order is preserved across reads and the
/// list is immune to the `@Relation` backlink rowid-mismatch bug.
@MainActor
@Suite(.serialized) struct AskCommentLatticeTests {

    private func openTempLattice() throws -> Lattice {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-askcomment-\(UUID().uuidString).lattice")
        return try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: tmp))
    }

    @Test func appendPreservesInsertionOrder() throws {
        let lattice = try openTempLattice()
        defer { lattice.close() }

        let session = Session()
        session.code = "abc"
        session.name = "test"
        session.cwd = "/tmp"
        lattice.add(session)

        let alice = Member(); alice.nick = "alice"; lattice.add(alice)
        let bob   = Member(); bob.nick   = "bob";   lattice.add(bob)

        let q = AskQuestion()
        q.header = "Pick one"
        q.options = [AskOption(label: "A"), AskOption(label: "B")]
        lattice.add(q)

        let c1 = AskComment(); c1.author = alice; c1.text = "i think A"
        let c2 = AskComment(); c2.author = bob;   c2.text = "no, B is better"
        let c3 = AskComment(); c3.author = alice; c3.text = "fine, B"
        q.comments.append(c1)
        q.comments.append(c2)
        q.comments.append(c3)

        let fetched = lattice.objects(AskQuestion.self).first { $0.header == "Pick one" }
        #expect(fetched != nil)
        #expect(fetched?.comments.count == 3)

        let texts = (fetched?.comments).map { Array($0).map(\.text) } ?? []
        #expect(texts == ["i think A", "no, B is better", "fine, B"],
                "List<T> must preserve insertion order; got \(texts)")

        let nicks = (fetched?.comments).map { Array($0).map { $0.author?.nick ?? "?" } } ?? []
        #expect(nicks == ["alice", "bob", "alice"])
    }

    @Test func emptyByDefault() throws {
        let lattice = try openTempLattice()
        defer { lattice.close() }

        let q = AskQuestion()
        q.header = "empty thread"
        lattice.add(q)

        let fetched = lattice.objects(AskQuestion.self).first { $0.header == "empty thread" }
        #expect(fetched?.comments.count == 0)
    }
}
