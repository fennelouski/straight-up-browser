import Synchronization

/// Only immutable lifecycle values cross the Objective-C callback boundary.
/// Draining the shared inbox also preserves an earlier background event when
/// a later main-thread notification must be handled synchronously.
nonisolated final class PageFadeLifecycleInbox: Sendable {
    enum Event: Sendable, Equatable {
        case visibility
        case suspend(String)
        case resume(String)
    }

    private let pending = Mutex<[Event]>([])

    func append(_ event: Event) {
        pending.withLock { $0.append(event) }
    }

    func takePending() -> [Event] {
        pending.withLock { events in
            let batch = events
            events.removeAll(keepingCapacity: true)
            return batch
        }
    }
}
