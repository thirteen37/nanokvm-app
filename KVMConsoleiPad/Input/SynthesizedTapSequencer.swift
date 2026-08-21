import Foundation

/// Gives a synthesized press — a tap-to-click, an on-screen key — a duration.
///
/// A tap has no dwell of its own, so the down and up reports would otherwise be emitted in the
/// same instant. HID reports carry *state*, not events: the KVM holds the most recent report and
/// the attached host only samples it when it polls, every few milliseconds. A press and release
/// that land inside one polling window collapse into the released state, so the host sees
/// nothing happen at all. Holding for `pressDuration` guarantees at least one poll observes the
/// press.
///
/// Taps arriving while one is still held are queued rather than merged — `insertText` synthesizes
/// a whole string's keystrokes in one pass, and each of them needs its own hold. The first `down`
/// is emitted synchronously so a tap never pays a run-loop hop before the host sees it.
///
/// Real presses need none of this: a held finger, a physical key, and a drag all supply their own
/// duration.
@MainActor
final class SynthesizedTapSequencer {
    nonisolated static let defaultPressDuration = Duration.milliseconds(50)

    private typealias Tap = (down: @MainActor () -> Void, up: @MainActor () -> Void)

    private let pressDuration: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var queue: [Tap] = []
    private var pendingRelease: (@MainActor () -> Void)?
    private var holdTask: Task<Void, Never>?

    init(
        pressDuration: Duration = SynthesizedTapSequencer.defaultPressDuration,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.pressDuration = pressDuration
        self.sleep = sleep
    }

    /// Emits `down` now and `up` once the press has been held long enough to be observed.
    func tap(down: @escaping @MainActor () -> Void, up: @escaping @MainActor () -> Void) {
        queue.append((down, up))
        guard holdTask == nil else { return }
        startNextTap()
    }

    /// Emits a still-held release immediately and drops anything queued behind it — used when a
    /// drag takes the button over, and when capture is turned off.
    func flushPendingRelease() {
        holdTask?.cancel()
        holdTask = nil
        queue.removeAll()
        releasePendingIfNeeded()
    }

    private func startNextTap() {
        guard !queue.isEmpty else { return }
        let tap = queue.removeFirst()
        tap.down()
        pendingRelease = tap.up
        holdTask = Task { [weak self, pressDuration, sleep] in
            await sleep(pressDuration)
            // A flush already emitted this release and cleared the queue.
            guard !Task.isCancelled else { return }
            self?.finishTap()
        }
    }

    private func finishTap() {
        holdTask = nil
        releasePendingIfNeeded()
        startNextTap()
    }

    private func releasePendingIfNeeded() {
        guard let pendingRelease else { return }
        self.pendingRelease = nil
        pendingRelease()
    }
}
