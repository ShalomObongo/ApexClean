import SwiftUI
import ApexCore

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published var selection: Set<String> = []
    @Published private(set) var results: [String: MaintenanceResult] = [:]
    @Published private(set) var running: String?
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0

    let tasks = MaintenanceCatalog.all
    private let runner = MaintenanceRunner()

    /// Maintenance tasks shell out to system tools and block for seconds at a
    /// time. Keep that off the Swift concurrency cooperative pool.
    private let workQueue = DispatchQueue(label: "fit.apexclean.maintenance", qos: .userInitiated)

    init() {
        // Preselect the low-impact, high-confidence repairs. Anything that
        // restarts a process or takes minutes stays opt-in.
        selection = ["quicklook", "icons", "savedstate", "orphanagents", "spotlight"]
    }

    var selectedTasks: [MaintenanceTask] { tasks.filter { selection.contains($0.id) } }

    var estimatedSeconds: Int { selectedTasks.reduce(0) { $0 + $1.estimatedSeconds } }

    var totalFreed: Int64 { results.values.reduce(0) { $0 + $1.bytesFreed } }

    func toggle(_ task: MaintenanceTask) {
        if selection.contains(task.id) { selection.remove(task.id) }
        else { selection.insert(task.id) }
    }

    func run() {
        guard !isRunning, !selection.isEmpty else { return }
        isRunning = true
        completedCount = 0
        results = [:]
        let pending = selectedTasks

        workQueue.async { [weak self, runner] in
            for task in pending {
                DispatchQueue.main.async {
                    withAnimation(Motion.enter) { self?.running = task.id }
                }
                let result = runner.run(task)
                DispatchQueue.main.async {
                    withAnimation(Motion.enter) {
                        self?.results[task.id] = result
                        self?.completedCount += 1
                    }
                }
            }
            DispatchQueue.main.async {
                withAnimation(Motion.stage) {
                    self?.running = nil
                    self?.isRunning = false
                }
            }
        }
    }

    func reset() {
        withAnimation(Motion.enter) {
            results = [:]
            completedCount = 0
        }
    }
}
