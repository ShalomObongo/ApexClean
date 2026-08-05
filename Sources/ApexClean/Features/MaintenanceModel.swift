@preconcurrency import ApexCore
import SwiftUI

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published var selection: Set<String> = []
    @Published private(set) var results: [String: MaintenanceResult] = [:]
    @Published private(set) var running: String?
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var queuedCount = 0

    let tasks = MaintenanceCatalog.all
    private let runner = MaintenanceRunner()
    private let history: OperationLog

    /// Maintenance tasks shell out to system tools and block for seconds at a
    /// time. Keep that off the Swift concurrency cooperative pool.
    private let workQueue = DispatchQueue(label: "fit.apexclean.maintenance", qos: .userInitiated)

    init(history: OperationLog) {
        self.history = history
        // Preselect the low-impact, high-confidence repairs. Anything that
        // restarts a process or takes minutes stays opt-in.
        selection = ["quicklook", "icons", "savedstate", "spotlight"]
    }

    var selectedTasks: [MaintenanceTask] { tasks.filter { selection.contains($0.id) } }

    var estimatedSeconds: Int { selectedTasks.reduce(0) { $0 + $1.estimatedSeconds } }

    var totalFreed: Int64 { results.values.reduce(0) { $0 + $1.bytesFreed } }
    var hasFailures: Bool { results.values.contains { !$0.succeeded } }

    func toggle(_ task: MaintenanceTask) {
        guard !isRunning else { return }
        if selection.contains(task.id) { selection.remove(task.id) } else { selection.insert(task.id) }
    }

    func run() {
        guard !isRunning, !selection.isEmpty else { return }
        isRunning = true
        completedCount = 0
        results = [:]
        let pending = selectedTasks
        queuedCount = pending.count
        let history = history
        let model = self

        workQueue.async { [runner] in
            for task in pending {
                DispatchQueue.main.async {
                    withAnimation(Motion.enter) { model.running = task.id }
                }
                let result = runner.run(task)
                _ = history.commitSession(
                    title: "Maintenance: \(task.title)",
                    entries: result.historyEntries
                )
                DispatchQueue.main.async {
                    withAnimation(Motion.enter) {
                        model.results[task.id] = result
                        model.completedCount += 1
                    }
                }
            }
            DispatchQueue.main.async {
                withAnimation(Motion.stage) {
                    model.running = nil
                    model.isRunning = false
                }
            }
        }
    }

    func reset() {
        guard !isRunning else { return }
        withAnimation(Motion.enter) {
            results = [:]
            completedCount = 0
        }
    }
}
