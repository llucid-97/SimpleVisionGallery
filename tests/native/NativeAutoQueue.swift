// Target audience: agents. Real queue, filesystem, PhotoKit and attached viewer scenes; synthetic key and delay only.
import Foundation

/// Drives the generated queue matrix through real native viewer sessions.
@MainActor final class NativeAutoQueue {
    static let shared = NativeAutoQueue()
    static let kind = "core-contracts-functional-v1"
    private var ran = false
    private let state = MeasurementState.shared
    private let proof = QueueFunctionalChecks.shared
    private func wait(_ step: String, until predicate: () -> Bool) async throws {
        try? Data(step.utf8).write(to: state.documents.appendingPathComponent("auto-progress.txt"), options: .atomic)
        let end = ContinuousClock.now + .seconds(60)
        while !predicate() && !proof.status.hasPrefix("Failed-") && ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !predicate() { throw NSError(domain: "GeneratedQueueProof", code: 1) }
    }
    /// Runs setup, mixed mutations and lock recovery in sequence so each phase has the expected state.
    func run() async {
        guard !ran else { return }; ran = true
        var passed = false
        // Abort dependent phases on failure and retain the proof status for the runner.
        do {
            state.unlock(); try await wait("unlock_fixture", until: { state.status == "Unlocked" })
            state.seedVault(1000); try await wait("seed_vault", until: { state.status == "VaultSeeded-1000" })
            state.seedPhotos(); try await wait("seed_photos", until: { state.status == "PhotosSeeded-1000" })
            proof.prepareWindows(); try await wait("two_windows", until: { proof.status == "WindowsReady" })
            proof.run(); try await wait("mixed_failure_lock", until: { proof.status == "LockedReadyForUnlock" })
            state.unlock(); try await wait("unlock_after_interrupted_batch", until: { state.status == "Unlocked" })
            proof.verifyAfterUnlock(); passed = proof.status == "Passed"
        } catch {}
        let payload: [String: Any] = ["kind": Self.kind, "passed": passed, "rows": [proof.status],
            "authentication": "synthetic fixture key", "input": "production capture APIs; two attached native windows"]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: state.documents.appendingPathComponent("auto-result.json"), options: .atomic)
        }
    }
}
