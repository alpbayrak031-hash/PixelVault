import Dispatch
import Foundation

/// Carries a value across a concurrency boundary the compiler cannot reason about.
/// Used only where the code guarantees disjoint access (striped loops over raw buffers).
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// Data-parallel loops for the codec's hot paths.
///
/// Bodies capture raw pointers into buffers owned by the caller, and each iteration
/// writes a disjoint region, so the work is race-free without locks.
enum Parallel {
    static let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    static func forEach(_ count: Int, _ body: (Int) -> Void) {
        guard count > 0 else { return }
        if count == 1 || coreCount == 1 {
            for i in 0..<count { body(i) }
            return
        }
        withoutActuallyEscaping(body) { escapable in
            let boxed = UncheckedSendable(value: escapable)
            DispatchQueue.concurrentPerform(iterations: count) { boxed.value($0) }
        }
    }

    /// Splits `0..<total` into contiguous stripes of at least `grain` items and runs them concurrently.
    static func stripes(_ total: Int, grain: Int, _ body: (Range<Int>) -> Void) {
        guard total > 0 else { return }
        let count = max(1, min(coreCount * 3, total / max(1, grain)))
        if count == 1 {
            body(0..<total)
            return
        }
        forEach(count) { i in
            let lower = total * i / count
            let upper = total * (i + 1) / count
            if lower < upper { body(lower..<upper) }
        }
    }
}

extension Array {
    /// An array of `count` elements whose storage is left for the caller to fill.
    @inline(__always)
    static func uninitialized(_ count: Int) -> [Element] {
        [Element](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
    }
}

/// Wall-clock stopwatch in milliseconds.
struct Stopwatch {
    private var start = DispatchTime.now().uptimeNanoseconds

    var milliseconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    mutating func lap() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { start = now }
        return Double(now - start) / 1_000_000
    }
}
