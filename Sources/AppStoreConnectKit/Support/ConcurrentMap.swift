import Foundation

/// How many App Store Connect requests one aggregating helper keeps in flight at once.
///
/// Apple's limit is a count of requests per rolling hour, not a concurrency cap, so a
/// fan-out spends exactly the same budget as the sequential loop it replaces; it only
/// stops the latency of each request from adding up. Kept small so a burst stays polite
/// and a throttled ``RateLimiter`` still paces every request through its own queue.
let ascFanOutLimit = 4

extension Sequence where Element: Sendable {
    /// Maps every element through `transform` with at most `maxConcurrency` calls in
    /// flight, returning the results in the sequence's original order.
    ///
    /// The first error thrown cancels the remaining work and is rethrown, matching the
    /// behaviour of the sequential `for … try await` loop this replaces.
    func concurrentMap<T: Sendable>(
        maxConcurrency: Int = ascFanOutLimit,
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        let items = Array(self)
        guard !items.isEmpty else { return [] }
        let width = Swift.max(1, Swift.min(maxConcurrency, items.count))

        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: items.count)
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                let item = items[index]
                nextIndex += 1
                group.addTask { (index, try await transform(item)) }
            }

            for _ in 0..<width { enqueueNext() }
            while let finished = try await group.next() {
                results[finished.0] = finished.1
                enqueueNext()
            }
            return results.compactMap { $0 }
        }
    }
}
