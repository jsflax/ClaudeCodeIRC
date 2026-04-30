import Combine
import Foundation
import Lattice
import NCursesUI
import typealias Lattice.Predicate
import struct Foundation.SortDescriptor
import enum Foundation.SortOrder

// MARK: - Lattice environment key
//
// Ported from NCursesUI's own LatticeUI.swift (dead there because NCursesUI
// doesn't depend on Lattice). Lives here in Core where both Lattice and
// NCursesUI are real deps. `#if canImport(NCursesUI)` inside Lattice would
// be non-deterministic per SPM maintainer guidance, so we keep the bridge
// in the app target instead.

public struct LatticeKey: EnvironmentKey {
    nonisolated(unsafe) public static var defaultValue: Lattice =
        try! Lattice(configuration: .init(isStoredInMemoryOnly: true))
}

extension EnvironmentValues {
    public var lattice: Lattice {
        get { self[LatticeKey.self] }
        set { self[LatticeKey.self] = newValue }
    }
}

// MARK: - @Query property wrapper
//
// Bind-on-update, observe-driven reactive query. Reads the Lattice from
// the environment, registers a change observer, refetches on change.
// `wrappedValue` is always safe to read — it's seeded with an empty
// result set until the environment provides a real Lattice.

@propertyWrapper
public struct Query<T: Model>: DynamicProperty {
    @Observable
    public final class Wrapper: @unchecked Sendable {
        public var value: TableResults<T>
        public let predicate: Predicate<T>
        public let sort: SortDescriptor<T>?
        /// Per-isolation handle. Holding `Lattice` directly here would
        /// pin the *attaching* isolation's `swift_lattice` instance —
        /// reads from any other isolation (e.g. the cooperative
        /// `Task.detached` inside `Lattice.observe`) would then go
        /// through the attaching instance, racing `swap()`/`leave()`
        /// closes on `@MainActor`. `LatticeThreadSafeReference.resolve()`
        /// keys on the *caller's* isolation — each call returns the
        /// `Lattice` whose C++ `swift_lattice` is keyed to whoever's
        /// reading right now. See `Tests/LatticeTests/ObserveCloseRaceTests`
        /// in jsflax/lattice for the bare-Lattice repro.
        public var latticeRef: LatticeThreadSafeReference?
        /// Cached config used only for the bind-skip check (we want
        /// the same `if config matches, no-op` shortcut without
        /// resolving the ref every render).
        private var lastBoundConfig: Lattice.Configuration?
        public var token: AnyCancellable?

        public init(predicate: @escaping Predicate<T>, sort: SortDescriptor<T>?) {
            self.predicate = predicate
            self.sort = sort
            self.value = LatticeKey.defaultValue.objects(T.self)
        }

        public func bind(_ lattice: Lattice) {
            let file = lattice.configuration.fileURL.lastPathComponent
            guard self.lastBoundConfig != lattice.configuration else {
                Log.line("Query<\(T.self)>", "bind skipped (same cfg, file=\(file))")
                return
            }
            Log.line("Query<\(T.self)>", "bind → \(file)")
            self.lastBoundConfig = lattice.configuration
            self.latticeRef = lattice.sendableReference
            fetch()
            let live = lattice.objects(T.self).where(predicate)
            // Hop the observer's `fetch()` onto `@MainActor`. The
            // cooperative `Task.detached` Lattice spawns for the
            // observe dispatch is fine for *reading* (sendableReference
            // gives us a per-isolation `swift_lattice` so `close()`
            // on main can't tear it down — see lattice
            // `ObserveCloseRaceTests`), but mutating `value` on a
            // non-Main thread leaves NCursesUI's render loop without
            // the @Observable invalidation it needs until some other
            // MainActor event wakes it (e.g. an arrow key). With this
            // hop, the value update lands on Main and the view
            // re-renders immediately. The close-vs-fetch race is
            // also gone: MainActor serialises both, so even if
            // `close()` lands first the latticeRef.resolve in fetch
            // returns a fresh isolation-keyed instance.
            self.token = live.observe { [weak self] (_: Any) in
                Log.line("Query<\(T.self)>", "observe fired")
                Task { @MainActor [weak self] in
                    self?.fetch()
                }
            }
        }

        /// Resolve the Lattice for the *current* isolation and read
        /// through it. `resolve()` returns a `Lattice` whose C++
        /// `swift_lattice` instance is keyed by `(file, scheduler, …)`
        /// — so a fetch on the cooperative `Task.detached` (observer
        /// fire) goes through a different `db_` than `@MainActor`'s,
        /// and an in-flight `lattice.close()` on main can't reach it.
        public func fetch() {
            guard let lattice = latticeRef?.resolve() else {
                Log.line("Query<\(T.self)>", "fetch skipped (no ref or unresolved)")
                return
            }
            var results = lattice.objects(T.self).where(predicate)
            if let sort { results = results.sortedBy(sort) }
            self.value = results
            var count = 0
            for _ in results { count += 1; if count > 20 { break } }
            Log.line("Query<\(T.self)>", "fetch → \(count)+ rows, file=\(lattice.configuration.fileURL.lastPathComponent)")
        }
    }

    public let _wrapper: Wrapper

    @Environment(\.lattice) private var lattice: Lattice

    public init<V: Comparable>(
        predicate: @escaping Predicate<T> = { _ in true },
        sort: (any KeyPath<T, V> & Sendable)? = nil,
        order: SortOrder? = nil
    ) {
        let sd = sort.map { SortDescriptor($0, order: order ?? .forward) }
        self._wrapper = Wrapper(predicate: predicate, sort: sd)
    }

    public init(predicate: @escaping Predicate<T> = { _ in true }) {
        self._wrapper = Wrapper(predicate: predicate, sort: nil)
    }

    public var wrappedValue: TableResults<T> { _wrapper.value }

    public func update() {
        _wrapper.bind(lattice)
    }
}
