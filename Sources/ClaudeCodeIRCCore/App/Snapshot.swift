import Combine
import Foundation
import Lattice
import NCursesUI
import struct Foundation.SortDescriptor
import enum Foundation.SortOrder

// MARK: - @Snapshot property wrapper
//
// Ported from NCursesUI's LatticeUI.swift (dead there because NCursesUI doesn't
// depend on Lattice; same arrangement as @Query in Query.swift).
//
// Why @Snapshot exists: `@Query` exposes a live `TableResults<T>` whose `count`
// and `endIndex` are SQL queries. `Collection.map` on that hits `_expectEnd`
// fatal if a row is inserted between the upfront `count` read and the loop
// finish — exactly the "claude is streaming + user scrolls" race in
// MessageListView. @Snapshot exposes a stable `[T]` that's race-free to map.
//
// Wire shape: materialiser runs on a shared `LatticeUIActor` so all wrappers
// share one isolation → one `LatticeCache` entry → one `swift_lattice` instance.
// Lattice writes fire `live.observe`, the materialiser refetches off-main, then
// hops to @MainActor to overwrite `value`.

@globalActor
public actor LatticeUIActor {
    public static let shared = LatticeUIActor()
}

@MainActor
@propertyWrapper
public struct Snapshot<T: Model>: @preconcurrency DynamicProperty {
    @Observable
    @MainActor
    public class Wrapper: @unchecked Sendable {
        @LatticeUIActor
        final class Materializer {
            // `nonisolated let` so the immutable params can be assigned from
            // the nonisolated init; Swift 6.3 otherwise rejects mutation of
            // actor-isolated stored props from a nonisolated context.
            nonisolated let predicate: Lattice.Predicate<T>
            nonisolated let sort: SortDescriptor<T>?
            nonisolated let limit: Int64?
            nonisolated let offset: Int64?
            var lattice: Lattice?
            var token: AnyCancellable?
            weak var wrapper: Wrapper?

            nonisolated init(predicate: @escaping Lattice.Predicate<T>,
                             sort: SortDescriptor<T>?,
                             limit: Int64?,
                             offset: Int64?) {
                self.predicate = predicate
                self.sort = sort
                self.limit = limit
                self.offset = offset
            }

            func bind(_ ref: LatticeThreadSafeReference, parent: Wrapper) {
                guard let resolved = ref.resolve() else {
                    Log.line("Snapshot<\(T.self)>", "bind FAILED — ref.resolve() nil")
                    return
                }
                guard self.lattice?.configuration != resolved.configuration else {
                    return
                }
                self.token?.cancel()
                self.lattice = resolved
                self.wrapper = parent
                Log.line("Snapshot<\(T.self)>", "bind → \(resolved.configuration.fileURL.lastPathComponent)")
                fetch()
                let live = resolved.objects(T.self).where(predicate)
                self.token = live.observe { [weak self] (_: Any) in
                    Task { @LatticeUIActor [weak self] in
                        self?.fetch()
                    }
                }
            }

            func fetch() {
                guard let lattice else { return }
                var results = lattice.objects(T.self).where(predicate)
                if let sort { results = results.sortedBy(sort) }
                let snapshot = results.snapshot(limit: limit, offset: offset)
                let refs = snapshot.map(\.sendableReference)
                let w = self.wrapper
                Task { @MainActor in
                    w?.set(value: refs)
                }
            }
        }

        @MainActor public var value: [T]
        public var lattice: Lattice?
        private let materializer: Materializer

        public init(predicate: @escaping Lattice.Predicate<T>,
                    sort: SortDescriptor<T>?,
                    limit: Int64?,
                    offset: Int64?) {
            self.materializer = Materializer(predicate: predicate,
                                             sort: sort,
                                             limit: limit,
                                             offset: offset)
            self.value = []
        }

        public func bind(_ lattice: Lattice) {
            guard self.lattice?.configuration != lattice.configuration else { return }
            self.lattice = lattice
            let ref = lattice.sendableReference
            let materializer = self.materializer
            Task { @LatticeUIActor [weak self] in
                guard let self else { return }
                materializer.bind(ref, parent: self)
            }
        }

        public func fetch() {
            let materializer = self.materializer
            Task { @LatticeUIActor in
                materializer.fetch()
            }
        }

        fileprivate func set(value: [ModelThreadSafeReference<T>]) {
            guard let lattice else { return }
            self.value = value.resolve(on: lattice)
        }
    }

    public let _wrapper: Wrapper

    @Environment(\.lattice) private var lattice: Lattice

    public init<V: Comparable>(
        predicate: @escaping Lattice.Predicate<T> = { _ in true },
        sort: (any KeyPath<T, V> & Sendable)? = nil,
        order: SortOrder? = nil,
        limit: Int64? = nil,
        offset: Int64? = nil
    ) {
        let sd = sort.map { SortDescriptor($0, order: order ?? .forward) }
        self._wrapper = Wrapper(predicate: predicate,
                                sort: sd,
                                limit: limit,
                                offset: offset)
    }

    public init(predicate: @escaping Lattice.Predicate<T> = { _ in true },
                limit: Int64? = nil,
                offset: Int64? = nil) {
        self._wrapper = Wrapper(predicate: predicate,
                                sort: nil,
                                limit: limit,
                                offset: offset)
    }

    public var wrappedValue: [T] { _wrapper.value }

    public func update() {
        _wrapper.bind(lattice)
    }
}
