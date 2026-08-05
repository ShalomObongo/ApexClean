import Combine
import Foundation

/// Coordinates all samplers behind one observable object.
///
/// Sampling cadence is adaptive: the expensive parts (processes, storage, power)
/// run far less often than the cheap counters, and everything stops when nothing
/// is observing. Low idle overhead is a product requirement, not a nicety.
@MainActor
public final class VitalsMonitor: ObservableObject {
    public struct Snapshot: Equatable, Sendable {
        public var cpu = CPUVitals()
        public var memory = MemoryVitals()
        public var storage = StorageVitals()
        public var network = NetworkVitals()
        public var power = PowerVitals()
        public var thermal = ThermalVitals()
        public var health = HealthScore()
        public var uptime: TimeInterval = 0
        public var topCPU: [ProcessVitals] = []
        public var topMemory: [ProcessVitals] = []
    }

    @Published public private(set) var snapshot = Snapshot()
    @Published public private(set) var cpuHistory: [Double] = []
    @Published public private(set) var memoryHistory: [Double] = []
    @Published public private(set) var downloadHistory: [Double] = []
    @Published public private(set) var uploadHistory: [Double] = []

    public static let historyLength = 60

    private var engine = SamplingEngine()
    private var timer: Timer?
    private var tick = 0
    private var subscribers = 0
    private var sampleInFlight = false
    private var sampleGeneration = 0
    private var abandonedEngines = 0
    private var isOnScreen = true

    public init() {
        // Sampling starts immediately and runs for the life of the process. The
        // menu bar HUD is a first-class surface, so metrics must be warm whether
        // or not the main window has ever been opened. Cadence — not existence —
        // is what adapts to whether anything is watching.
        start()
    }

    /// Reference-counted so the window and the menu bar can both ask for the
    /// faster cadence without either one slowing the other down.
    public func addSubscriber() {
        subscribers += 1
        applyCadence()
    }

    public func removeSubscriber() {
        subscribers = max(0, subscribers - 1)
        applyCadence()
    }

    /// Set false when no ApexClean window is actually on screen — minimised,
    /// hidden, or fully covered. Sampling twice a second-and-a-half to feed
    /// charts nobody can see is exactly the kind of background cost this app
    /// exists to remove from other people's Macs.
    public func setLiveUpdates(_ live: Bool) {
        guard live != isOnScreen else { return }
        isOnScreen = live
        applyCadence()
        if live { sample(force: true) }
    }

    private var interval: TimeInterval { (subscribers > 0 && isOnScreen) ? 2.0 : 10.0 }

    private func applyCadence() {
        guard let timer else {
            start()
            return
        }
        guard timer.timeInterval != interval else { return }
        start(restart: true)
    }

    private func start(restart: Bool = false) {
        if restart { stop() }
        guard timer == nil else { return }
        sample(force: true)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Bind strongly before the Task. Capturing the weak `self` binding
            // itself in concurrently-executing code is rejected by Swift 5.9 and
            // 5.10, which is what ships with macOS 14.
            guard let self else { return }
            Task { @MainActor in self.sample() }
        }
        // Common mode keeps the graphs live while a menu or scroll is tracking.
        RunLoop.main.add(timer, forMode: .common)
        // A generous tolerance lets the system coalesce our wake-ups with other
        // timers rather than forcing a dedicated interrupt.
        timer.tolerance = interval * 0.25
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func sampleOnce() { sample(force: true) }

    private func sample(force: Bool = false) {
        // Sampling must never run on the main thread. `ProcessSampler` shells out
        // to `ps`, and waiting on a child process from the main thread pumps the
        // run loop — which re-enters SwiftUI's transaction flush from inside the
        // very layout pass that triggered the sample, and recurses until the app
        // is pinned at 100% CPU with no window ever reaching the screen.
        guard !sampleInFlight else { return }
        sampleInFlight = true
        sampleGeneration &+= 1
        let generation = sampleGeneration
        let engine = engine

        tick &+= 1
        engine.sample(
            previous: snapshot,
            includeSlowMetrics: force || tick % 10 == 1,
            includeProcesses: force || tick % 5 == 1
        ) { [weak self] next in
            guard let self else { return }
            guard self.sampleGeneration == generation else { return }
            self.sampleInFlight = false
            self.abandonedEngines = 0
            self.snapshot = next
            self.append(&self.cpuHistory, next.cpu.usage / 100)
            self.append(&self.memoryHistory, next.memory.pressure)
            self.append(&self.downloadHistory, next.network.downloadBytesPerSecond)
            self.append(&self.uploadHistory, next.network.uploadBytesPerSecond)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self,
                self.sampleInFlight,
                self.sampleGeneration == generation
            else { return }

            self.sampleInFlight = false
            self.sampleGeneration &+= 1
            self.abandonedEngines += 1
            self.engine = SamplingEngine()
            Log.vitals.error("Sampling exceeded its deadline; replaced the sampling engine")
            if self.abandonedEngines < 3 {
                self.sample(force: true)
            } else {
                self.stop()
            }
        }
    }

    private func append(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }
}

/// Owns the stateful samplers and runs every reading on one serial background
/// queue. Nothing here touches the main thread; results are handed back on it.
private final class SamplingEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fit.apexclean.vitals", qos: .utility)
    private let cpuSampler = CPUSampler()
    private let networkSampler = NetworkSampler()

    func sample(
        previous: VitalsMonitor.Snapshot,
        includeSlowMetrics: Bool,
        includeProcesses: Bool,
        completion: @escaping @MainActor @Sendable (VitalsMonitor.Snapshot) -> Void
    ) {
        queue.async { [self] in
            var next = previous
            let cpu = cpuSampler.sample()
            if cpu.logicalCores > 0 { next.cpu = cpu }

            let memory = MemorySampler.sample()
            if memory.total > 0,
                memory.active + memory.wired + memory.compressed + memory.free > 0
            {
                next.memory = memory
            }
            next.network = networkSampler.sample()

            // Storage, power and the process table are comparatively expensive,
            // so they run on a slower cadence than the cheap counters.
            if includeSlowMetrics {
                let storage = StorageSampler.sample()
                if storage.total > 0 { next.storage = storage }
                next.power = PowerSampler.sample()
                next.thermal = ThermalSampler.sample()
                next.uptime = HealthEvaluator.uptime()
            }
            if includeProcesses {
                next.topCPU = ProcessSampler.topByCPU()
                next.topMemory = ProcessSampler.topByMemory()
            }

            next.health = HealthEvaluator.evaluate(
                cpu: next.cpu,
                memory: next.memory,
                storage: next.storage,
                thermal: next.thermal,
                power: next.power,
                uptime: next.uptime
            )

            let result = next
            DispatchQueue.main.async { completion(result) }
        }
    }
}
