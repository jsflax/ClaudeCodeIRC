import Foundation
import Lattice
import ClaudeCodeIRCCore

/// Opaque handle wrapping a Lattice instance opened against a room file.
/// Keep the wrapper minimal: callers either pass it back to one of the
/// helpers in `CCIRCLatticeAccess`, or extract counts/states inline by
/// reaching into `.lattice` for ad-hoc queries.
public struct CCIRCLatticeHandle: @unchecked Sendable {
    public let lattice: Lattice
    public let path: String
}

/// Thin bridge between the test helpers and Lattice. Tests can also
/// `import Lattice` and write inline queries — these are convenience
/// accessors for the most common state checks (member count, orphan
/// detection).
public enum CCIRCLatticeAccess {
    /// Open the room file read-only. SQLite WAL allows the test process to
    /// read while the live ClaudeCodeIRC process is writing.
    public static func open(path: String) throws -> CCIRCLatticeHandle {
        let url = URL(fileURLWithPath: path)
        let lattice = try Lattice(
            for: RoomStore.schema,
            configuration: .init(fileURL: url, isReadOnly: true)
        )
        return CCIRCLatticeHandle(lattice: lattice, path: path)
    }

    public static func memberCount(in handle: CCIRCLatticeHandle) -> Int {
        handle.lattice.objects(Member.self).count
    }

    /// True iff there are no in-flight orphan rows: 0 streaming Turns AND
    /// 0 pending AskQuestions. Used by C4 after relaunch to verify
    /// `RoomsModel.terminateOrphanedInFlightRows` ran.
    public static func hasNoInFlightOrphans(in handle: CCIRCLatticeHandle) -> Bool {
        let stuckTurns = handle.lattice.objects(Turn.self)
            .where { $0.status == .streaming }
            .count
        let pendingAsks = handle.lattice.objects(AskQuestion.self)
            .where { $0.status == .pending }
            .count
        return stuckTurns == 0 && pendingAsks == 0
    }

    public static func streamingTurnCount(in handle: CCIRCLatticeHandle) -> Int {
        handle.lattice.objects(Turn.self).where { $0.status == .streaming }.count
    }

    public static func pendingAskCount(in handle: CCIRCLatticeHandle) -> Int {
        handle.lattice.objects(AskQuestion.self).where { $0.status == .pending }.count
    }
}
