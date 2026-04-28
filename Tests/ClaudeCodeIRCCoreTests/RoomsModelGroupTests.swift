import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Exercises `RoomsModel.addGroup(invitePaste:)` end-to-end:
/// invite parses → SHA-256 hash computed → `LocalGroup` row inserted
/// in `prefs.lattice`. Idempotency: pasting the same invite twice
/// returns the existing row (matched by `hashHex`), not a duplicate.
///
/// `.serialized` because every test sets the global
/// `RoomPaths.dataDirOverride` and constructs a `RoomsModel` against
/// it. Parallel tests would race on the override.
@MainActor
@Suite(.serialized) struct RoomsModelGroupTests {

    private func withTempDataDir<T>(_ body: () async throws -> T) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-rooms-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp.appending(path: "rooms"),
            withIntermediateDirectories: true)
        let prior = RoomPaths.dataDirOverride
        RoomPaths.dataDirOverride = tmp
        defer {
            RoomPaths.dataDirOverride = prior
            try? FileManager.default.removeItem(at: tmp)
        }
        return try await body()
    }

    @Test func addGroupParsesAndInsertsLocalGroupRow() async throws {
        try await withTempDataDir {
            let model = RoomsModel()
            let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let invite = GroupInviteCode.encode(name: "Canary", secret: secret)

            let g = try model.addGroup(invitePaste: invite)

            #expect(g.name == "Canary")
            #expect(g.hashHex == GroupID.compute(secret: secret))
            #expect(!g.secretBase64.isEmpty)

            // Stored in prefs lattice.
            let stored = model.prefsLattice.objects(LocalGroup.self)
            #expect(stored.count == 1)
            #expect(stored.first?.name == "Canary")
        }
    }

    @Test func addGroupIsIdempotentOnDuplicatePaste() async throws {
        try await withTempDataDir {
            let model = RoomsModel()
            let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let invite = GroupInviteCode.encode(name: "Canary", secret: secret)

            let first = try model.addGroup(invitePaste: invite)
            let second = try model.addGroup(invitePaste: invite)

            #expect(first.hashHex == second.hashHex)
            #expect(model.prefsLattice.objects(LocalGroup.self).count == 1,
                "duplicate paste must not create a second row")
        }
    }

    @Test func addGroupAllowsTwoDistinctGroupsWithSameName() async throws {
        try await withTempDataDir {
            let model = RoomsModel()
            let s1 = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let s2 = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let invite1 = GroupInviteCode.encode(name: "Canary", secret: s1)
            let invite2 = GroupInviteCode.encode(name: "Canary", secret: s2)

            let g1 = try model.addGroup(invitePaste: invite1)
            let g2 = try model.addGroup(invitePaste: invite2)

            #expect(g1.hashHex != g2.hashHex)
            #expect(model.prefsLattice.objects(LocalGroup.self).count == 2,
                "different secrets with same name must coexist")
        }
    }

    @Test func addGroupRejectsMalformedInvite() async throws {
        try await withTempDataDir {
            let model = RoomsModel()
            // Pasting random text (no `:` separators) → invalidStructure.
            #expect(throws: GroupInviteCode.DecodeError.invalidStructure) {
                try model.addGroup(invitePaste: "not-a-valid-invite")
            }
            // Wrong scheme but correct structure → unsupportedScheme.
            #expect(throws: GroupInviteCode.DecodeError.unsupportedScheme) {
                try model.addGroup(invitePaste: "ccirc-foo:v1:bmFtZQ:c2VjcmV0")
            }
            #expect(model.prefsLattice.objects(LocalGroup.self).count == 0,
                "no row should be inserted on malformed invite")
        }
    }
}
