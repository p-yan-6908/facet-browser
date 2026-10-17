import AppKit
import Foundation

/// Small adaptive model for the amount of process footprint a hibernated renderer
/// actually gives back. WebKit pages vary wildly, so the controller learns from
/// observed before/after deltas instead of pretending every tab costs the same.
struct MemoryReclaimEstimator {
    private(set) var learnedBytes: UInt64 = 160 * 1_048_576
    private(set) var observations = 0

    mutating func observe(before: UInt64, after: UInt64) {
        guard before > after else { return }
        let delta = before - after
        // Ignore scheduler/process noise and absurd values caused by unrelated app activity.
        guard delta >= 8 * 1_048_576, delta <= 1_024 * 1_048_576 else { return }
        if observations == 0 { learnedBytes = delta }
        else {
            // 25% EWMA: responsive enough to a changing workload without one huge page
            // making the next several evictions too optimistic.
            learnedBytes = UInt64(Double(learnedBytes) * 0.75 + Double(delta) * 0.25)
        }
        observations += 1
    }

    var conservativeReclaimBytes: UInt64 {
        min(512 * 1_048_576, max(32 * 1_048_576, UInt64(Double(learnedBytes) * 0.75)))
    }

    var predictedWakeBytes: UInt64 {
        min(640 * 1_048_576, max(96 * 1_048_576, UInt64(Double(learnedBytes) * 1.20)))
    }
}

/// Enforces one RAM budget across every Facet window. The budget is a target rather
/// than a kill-limit: a single foreground page can legitimately exceed it, but
/// background renderers are reclaimed before Facet competes with the rest of macOS.
final class MemoryBudgetController {
    static let shared = MemoryBudgetController()

    private let windows = NSHashTable<BrowserWindowController>.weakObjects()
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var started = false
    private var lastSample: MemorySample?
    private var lastSampleAt = Date.distantPast
    private var estimator = MemoryReclaimEstimator()
    private var isReclaiming = false
    private var pendingEnforcement = false

    var budgetBytes: UInt64 { UInt64(max(0, Config.shared.memoryBudgetMB)) * 1_048_576 }
    var isEnabled: Bool { Config.shared.memoryBudgetMB > 0 }
    var softLimit: UInt64 { UInt64(Double(budgetBytes) * 0.90) }
    var targetBytes: UInt64 { UInt64(Double(budgetBytes) * 0.72) }
    var learnedReclaimBytes: UInt64 { estimator.learnedBytes }
    var reclaimObservations: Int { estimator.observations }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.enforceBudget(reason: "periodic")
        }
        timer?.tolerance = 1
        installMemoryPressureHandling()
    }

    func settingsDidChange() {
        pressureSource?.cancel(); pressureSource = nil
        installMemoryPressureHandling()
    }

    func register(_ window: BrowserWindowController) { windows.add(window) }
    func unregister(_ window: BrowserWindowController) { windows.remove(window) }

    /// Process enumeration is relatively expensive. Share a short-lived sample across
    /// the budget loop and every visible window's status pill.
    func sample(maxAge: TimeInterval = 1.0) -> MemorySample {
        let now = Date()
        if let lastSample, now.timeIntervalSince(lastSampleAt) <= maxAge { return lastSample }
        let fresh = MemoryMonitor.sample()
        lastSample = fresh; lastSampleAt = now
        return fresh
    }

    private func invalidateSample() { lastSampleAt = .distantPast }

    /// Called immediately before a sleeping tab is made live. We cannot know the new
    /// renderer's exact cost in advance, so use the learned wake estimate to make room.
    /// Unlike the steady-state loop below, this path is synchronous so tab switching
    /// does not gain a visible half-second delay.
    func prepareToActivate(_ tab: Tab) {
        guard isEnabled, tab.isHibernated else { return }
        let current = sample(maxAge: 0.5)
        let predicted = current.totalBytes &+ estimator.predictedWakeBytes
        guard predicted > softLimit else { return }
        let need = predicted > targetBytes ? predicted - targetBytes : estimator.conservativeReclaimBytes
        let perTab = max(1, estimator.conservativeReclaimBytes)
        let count = max(1, Int((need + perTab - 1) / perTab))
        let victims = evictionCandidates(excluding: tab)
        for victim in victims.prefix(min(count, victims.count)) { victim.hibernate() }
        if !victims.isEmpty { invalidateSample(); refreshAllWindows() }
    }

    func enforceBudget(reason: String) {
        guard isEnabled else { return }
        guard !isReclaiming else { pendingEnforcement = true; return }
        // Listing every process costs CPU. Far under the budget, the periodic check reuses a
        // recent sample (the status pill takes one every few seconds) rather than its own.
        let farUnder = reason == "periodic" && (lastSample.map { $0.totalBytes < softLimit / 2 } ?? false)
        let before = sample(maxAge: farUnder ? 20 : 0)
        guard before.totalBytes > softLimit else { return }
        let candidates = evictionCandidates(excluding: nil)
        guard !candidates.isEmpty else { return }
        isReclaiming = true
        reclaimOneByOne(candidates, index: 0, before: before.totalBytes, reason: reason)
    }

    /// Hibernates one LRU tab, waits for WebKit/XPC teardown, measures the real drop,
    /// learns from it, and only then decides whether another victim is necessary.
    private func reclaimOneByOne(_ candidates: [Tab], index: Int, before: UInt64, reason: String) {
        guard isEnabled, index < candidates.count else { finishReclaim(reason: reason); return }
        let tab = candidates[index]
        guard tab.canHibernateForBudget else {
            reclaimOneByOne(candidates, index: index + 1, before: before, reason: reason); return
        }
        tab.hibernate()
        invalidateSample(); refreshAllWindows()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            let after = self.sample(maxAge: 0).totalBytes
            self.estimator.observe(before: before, after: after)
            let reclaimed = before > after ? before - after : 0
            NSLog("Facet: adaptive RAM %@ slept 1 tab; observed %.0f MB reclaimed; learned %.0f MB",
                  reason, Double(reclaimed) / 1_048_576, Double(self.estimator.learnedBytes) / 1_048_576)
            guard after > self.targetBytes else { self.finishReclaim(reason: reason); return }
            self.reclaimOneByOne(candidates, index: index + 1, before: after, reason: reason)
        }
    }

    private func finishReclaim(reason: String) {
        isReclaiming = false
        invalidateSample(); refreshAllWindows()
        if pendingEnforcement {
            pendingEnforcement = false
            DispatchQueue.main.async { [weak self] in self?.enforceBudget(reason: reason + " follow-up") }
        }
    }

    /// Emergency path for macOS pressure notifications. Protected/media/agent-leased
    /// tabs are preserved; everything else in the background is eligible immediately.
    func handleMemoryPressure() {
        NSLog("Facet: memory pressure, reclaiming background tabs")
        for tab in evictionCandidates(excluding: nil) { tab.hibernate() }
        URLCache.shared.removeAllCachedResponses()
        invalidateSample(); refreshAllWindows()
    }

    private func evictionCandidates(excluding: Tab?) -> [Tab] {
        var result: [Tab] = []
        for window in windows.allObjects {
            for tab in window.tabs {
                if tab === excluding { continue }
                // The page on screen is never evicted; one in a hidden window can be.
                if tab === window.activeTab && window.isContentVisible { continue }
                if tab.canHibernateForBudget { result.append(tab) }
            }
        }
        return result.sorted { $0.lastActive < $1.lastActive }
    }

    private func refreshAllWindows() {
        for window in windows.allObjects { window.memoryBudgetDidChange() }
    }

    private func installMemoryPressureHandling() {
        guard Config.shared.hibernateOnMemoryPressure else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.handleMemoryPressure() }
        src.resume(); pressureSource = src
    }

    var sleepingTabCount: Int {
        windows.allObjects.reduce(0) { $0 + $1.tabs.filter { $0.isHibernated }.count }
    }

    func budgetDisplay(sample: MemorySample) -> String {
        guard isEnabled else { return sample.display }
        let usedMB = Double(sample.totalBytes) / 1_048_576
        let budgetMB = Double(budgetBytes) / 1_048_576
        func fmt(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1fG", mb / 1024) : String(format: "%.0fM", mb) }
        return "\(fmt(usedMB))/\(fmt(budgetMB))"
    }
}
