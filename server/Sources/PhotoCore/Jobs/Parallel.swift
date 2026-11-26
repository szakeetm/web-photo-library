import Foundation

/// Runs `body` for every index in 0..<count on at most `workers` threads.
public func parallelFor(_ count: Int, workers: Int, _ body: (Int) -> Void) {
    guard count > 0 else { return }
    let next = Counter()
    DispatchQueue.concurrentPerform(iterations: max(1, min(workers, count))) { _ in
        while true {
            let i = next.increment() - 1
            if i >= count { break }
            // Each worker loops over many items inside one GCD block, so the thread's own pool only
            // drains when the whole job ends. Image I/O and Core Image autorelease their buffers;
            // without a pool per item, every decoded image stayed alive until then.
            autoreleasepool { body(i) }
        }
    }
}

public enum Workers {
    /// Default worker count: up to 8, never more than the machine's cores.
    public static var defaultCount: Int { min(8, ProcessInfo.processInfo.activeProcessorCount) }
}
