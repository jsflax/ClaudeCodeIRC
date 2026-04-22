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
        public var lattice: Lattice?
        public var token: AnyCancellable?

        public init(predicate: @escaping Predicate<T>, sort: SortDescriptor<T>?) {
            self.predicate = predicate
            self.sort = sort
            self.value = LatticeKey.defaultValue.objects(T.self)
        }

        public func bind(_ lattice: Lattice) {
            let file = lattice.configuration.fileURL.lastPathComponent
            guard self.lattice?.configuration != lattice.configuration else {
                Log.line("Query<\(T.self)>", "bind skipped (same cfg, file=\(file))")
                return
            }
            Log.line("Query<\(T.self)>", "bind → \(file)")
            self.lattice = lattice
            fetch()
            let live = lattice.objects(T.self).where(predicate)
            self.token = live.observe { [weak self] (_: Any) in
                Log.line("Query<\(T.self)>", "observe fired")
                self?.fetch()
            }
        }

        public func fetch() {
            guard let lattice else {
                Log.line("Query<\(T.self)>", "fetch skipped (no lattice)")
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
