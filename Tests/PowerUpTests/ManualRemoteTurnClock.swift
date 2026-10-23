import Foundation
@testable import PowerUp

/// A `RemoteTurnClock` that only moves when a test says so (#118).
///
/// `now` starts at a fixed instant. `advance(by:)` walks time forward and runs
/// every scheduled action that falls due on the way, in due order, with `now`
/// set to that action's due time while it runs, so an expiry check sees
/// exactly the time it was scheduled for. Nothing ever sleeps.
@MainActor
final class ManualRemoteTurnClock: RemoteTurnClock {

    private(set) var now: Date

    private struct Timer {
        let due: Date
        let order: Int
        let action: @MainActor () -> Void
    }

    private var timers: [Timer] = []
    private var nextOrder = 0

    init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        now = start
    }

    /// Scheduled actions that have not run yet.
    var pendingActionCount: Int { timers.count }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timers.append(Timer(due: now.addingTimeInterval(max(0, delay)), order: nextOrder, action: action))
        nextOrder += 1
    }

    /// Moves time forward by `seconds`, running each action that falls due.
    /// An action scheduled while advancing runs too if it falls due in range.
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(max(0, seconds))
        while let index = nextDueIndex(by: target) {
            let timer = timers.remove(at: index)
            now = timer.due
            timer.action()
        }
        now = target
    }

    private func nextDueIndex(by target: Date) -> Int? {
        timers.indices
            .filter { timers[$0].due <= target }
            .min { lhs, rhs in
                (timers[lhs].due, timers[lhs].order) < (timers[rhs].due, timers[rhs].order)
            }
    }
}
