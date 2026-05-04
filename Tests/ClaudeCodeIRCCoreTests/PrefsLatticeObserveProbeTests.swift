import Foundation
import Testing
import Lattice
import ClaudeCodeIRCCore

/// Probe for the "/newgroup doesn't refresh the sidebar" investigation
/// (plan §G). Verifies the directly-observable contract: when
/// `RoomsModel.createGroup` writes a `LocalGroup` to `prefsLattice`,
/// `prefsLattice.observe(LocalGroup.self)` fires. If this test passes,
/// the bug is **not** at the Lattice level — it lives in the @Query →
/// @Observable → NCursesUI render pipeline. If it fails, the bug is
/// in the write path itself.
@MainActor
@Suite(.serialized) struct PrefsLatticeObserveProbeTests {

    private func withTempDataDir<T>(_ body: () async throws -> T) async rethrows -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "ccirc-probe-\(UUID().uuidString)")
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

    @Test func observerFiresAfterCreateGroup() async throws {
        try await withTempDataDir {
            let model = RoomsModel()
            // Track observer fires via an actor-isolated counter so the
            // observer block can write safely from whatever isolation
            // Lattice dispatches on.
            final class Counter: @unchecked Sendable {
                var fires = 0
                let lock = NSLock()
                func bump() { lock.lock(); defer { lock.unlock() }; fires += 1 }
                func read() -> Int { lock.lock(); defer { lock.unlock() }; return fires }
            }
            let counter = Counter()

            let token = model.prefsLattice.observe(LocalGroup.self) { _ in
                counter.bump()
            }
            defer { token.cancel() }

            _ = try model.createGroup(name: "probe")

            // Lattice dispatches the observer through Task.detached →
            // isolation hop. Give the runloop a chance to drain.
            for _ in 0..<20 {
                if counter.read() > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(counter.read() > 0,
                "prefsLattice.observe(LocalGroup.self) should fire after createGroup")
        }
    }

    /// Probe #2 — simulates exactly what `@Query<LocalGroup>` in
    /// `GroupsSidebarSection` does. Drives a `NCursesUI.Query` Wrapper
    /// directly: bind it to `prefsLattice`, register an observation
    /// tracker that reads `wrappedValue`, then mutate the lattice via
    /// `createGroup` and check whether the tracker's `onChange` fires
    /// (i.e. whether the live render path would mark dirty and
    /// re-evaluate the body).
    ///
    /// If this fails, the @Query→withObservationTracking chain is
    /// broken (the rebuild bug from memory id 49C95C7C). If it passes,
    /// the failure is elsewhere (e.g. a parent body decision that
    /// skips re-eval despite markDirty).
    @Test func queryWrapperFiresOnChangeAfterCreateGroup() async throws {
        try await withTempDataDir {
            let model = RoomsModel()

            let wrapper = ClaudeCodeIRCCore.Query<LocalGroup>.Wrapper(
                predicate: { _ in true }, sort: SortDescriptor<LocalGroup>?.none)
            wrapper.bind(model.prefsLattice)

            // Mirror NCursesUI's reconcile loop: read inside
            // withObservationTracking, expect onChange when value
            // mutates.
            final class Sentinel: @unchecked Sendable {
                var fired = 0
                let lock = NSLock()
                func bump() { lock.lock(); defer { lock.unlock() }; fired += 1 }
                func read() -> Int { lock.lock(); defer { lock.unlock() }; return fired }
            }
            let sentinel = Sentinel()

            // The block must READ wrapper.value so the tracker
            // registers a dependency on it.
            withObservationTracking {
                _ = wrapper.value
            } onChange: {
                sentinel.bump()
            }

            _ = try model.createGroup(name: "probe2")

            // Allow async observer dispatch + fetch to land.
            for _ in 0..<40 {
                if sentinel.read() > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }

            #expect(sentinel.read() > 0,
                "Query.Wrapper.value mutation should trigger withObservationTracking onChange — if this fails, NCursesUI's @Query reactivity is the bug")

            // Also confirm the wrapper's value reflects the new row,
            // proving Lattice observer → Wrapper.fetch path works
            // end-to-end on a single (long-lived) Wrapper.
            let count = Array(wrapper.value).count
            #expect(count == 1,
                "Wrapper.value should reflect the inserted row after fetch")
        }
    }

}
