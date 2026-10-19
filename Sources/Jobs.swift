import AppKit
import UserNotifications

/// A batch of image work: one drop on the wheel, or one Save in the crop window.
@MainActor
final class Job: ObservableObject, Identifiable {
    enum State { case queued, running, finished, cancelled }

    let id = UUID()
    let title: String
    /// One action on one file, or on several for "combine into PDF".
    struct Unit {
        let action: ImageAction
        let urls: [URL]
    }

    let units: [Unit]
    var inputs: [URL] { units.flatMap(\.urls) }
    /// Where results go, from Settings when the job was made; nil means next to each original.
    let outputFolder: URL?

    @Published fileprivate(set) var state: State = .queued
    @Published fileprivate(set) var completed = 0
    @Published fileprivate(set) var outputs: [URL] = []
    @Published fileprivate(set) var failures: [(name: String, reason: String)] = []
    /// Sizes of the inputs and outputs of files Compress has finished, for showing the saving.
    @Published fileprivate(set) var bytesIn = 0
    @Published fileprivate(set) var bytesOut = 0
    /// The outputs were moved to the Trash from the menu.
    @Published private(set) var trashed = false

    /// Set once the wheel has handed the job to the menu bar; only those jobs notify.
    var handedOff = false
    /// Extra observer for whoever started the job (the wheel).
    var onChange: (() -> Void)?

    fileprivate let operations = OperationQueue()
    fileprivate var cancelRequested = false

    var total: Int { units.count }
    var isActive: Bool { state == .queued || state == .running }
    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }

    init(title: String, units: [Unit]) {
        self.title = title
        self.units = units
        self.outputFolder = Settings.shared.outputFolder
    }

    /// The same action on every file.
    convenience init(title: String, action: ImageAction, inputs: [URL]) {
        self.init(title: title, units: action == .pdf ? [Unit(action: .pdf, urls: inputs)]
                                                      : inputs.map { Unit(action: action, urls: [$0]) })
    }

    func cancel() {
        guard isActive else { return }
        cancelRequested = true
        if state == .queued {
            JobCenter.shared.finish(self)
            return
        }
        // cancelAllOperations also cancels the barrier that finishes the job, so add a new one;
        // it runs once the files already in progress are done.
        operations.cancelAllOperations()
        operations.addBarrierBlock {
            DispatchQueue.main.async { JobCenter.shared.finish(self) }
        }
    }

    func revealOutputs() { Self.reveal(outputs) }

    func trashOutputs() {
        Self.trash(outputs)
        trashed = true
    }

    /// Moves whichever of these files still exist to the Trash. Never deletes anything outright.
    static func trash(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Size change from Compress, e.g. -75, once it has finished at least one file.
    var savingPercent: Int? {
        guard bytesIn > 0 else { return nil }
        return Int((Double(bytesOut - bytesIn) / Double(bytesIn) * 100).rounded())
    }

    /// "2.4 MB → 610 KB (-75%)".
    var savingText: String? {
        guard let percent = savingPercent else { return nil }
        let f = ByteCountFormatter()
        return "\(f.string(fromByteCount: Int64(bytesIn))) → \(f.string(fromByteCount: Int64(bytesOut))) (\(percent)%)"
    }

    /// Selects whichever of these files still exist in Finder.
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
    }

    static func title(for item: WheelItem) -> String {
        switch item.action {
        case .convert: return "Convert to \(item.title)"
        case .pdf: return "Make PDF"
        case .scale, .fit: return "Resize to \(item.title)"
        case .compress: return "Compress"
        case .strip: return "Strip metadata"
        case .trim: return "Trim borders"
        case .crop, .cropInteractive: return "Crop"
        }
    }
}

/// Runs jobs one after another; files within a job run in parallel.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    private static let keepFinished = 5

    /// Oldest first: running/queued jobs plus the last few finished ones.
    @Published private(set) var jobs: [Job] = []
    var onChange: (() -> Void)?

    var activeJobs: [Job] { jobs.filter(\.isActive) }

    /// Progress across all active jobs, or nil when idle.
    var overallFraction: Double? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.total }
        return total == 0 ? 0 : Double(active.reduce(0) { $0 + $1.completed }) / Double(total)
    }

    @discardableResult
    func submit(_ item: WheelItem, on urls: [URL]) -> Job {
        submit(Job(title: Job.title(for: item), action: item.action, inputs: urls))
    }

    @discardableResult
    func submit(_ job: Job) -> Job {
        jobs.append(job)
        startNextIfIdle()
        changed(job)
        return job
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
        onChange?()
    }

    private func startNextIfIdle() {
        guard !jobs.contains(where: { $0.state == .running }),
              let job = jobs.first(where: { $0.state == .queued }) else { return }
        job.state = .running

        // A few at a time: full-size photos decode to hundreds of MB each.
        job.operations.maxConcurrentOperationCount = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        job.operations.qualityOfService = .userInitiated
        let folder = job.outputFolder
        for unit in job.units {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak operation] in
                let result = Result {
                    try ImageOps.run(unit.action, on: unit.urls, outputFolder: folder,
                                     isCancelled: { operation?.isCancelled ?? true })
                }
                DispatchQueue.main.async { self.record(result, for: unit, in: job) }
            }
            job.operations.addOperation(operation)
        }
        // Runs after every operation has finished or been cancelled.
        job.operations.addBarrierBlock {
            DispatchQueue.main.async { self.finish(job) }
        }
    }

    private func record(_ result: Result<ImageOps.Outcome, Error>, for unit: Job.Unit, in job: Job) {
        // Stopped by Cancel: neither done nor failed.
        if case .failure(let error) = result, error as? ImageOpsError == .cancelled { return }
        job.completed += 1
        switch result {
        case .success(let outcome):
            job.outputs += outcome.outputs
            job.failures += outcome.failures
            if unit.action == .compress, let input = unit.urls.first, let output = outcome.outputs.first {
                job.bytesIn += ImageOps.fileSize(input)
                job.bytesOut += ImageOps.fileSize(output)
            }
        case .failure(let error):
            job.failures.append((unit.urls.count == 1 ? unit.urls[0].lastPathComponent : "PDF", error.localizedDescription))
        }
        changed(job)
    }

    fileprivate func finish(_ job: Job) {
        guard job.isActive else { return }
        // A Cancel that came after the last file finished doesn't count.
        job.state = job.cancelRequested && job.completed < job.total ? .cancelled : .finished
        if job.handedOff { Notifier.post(for: job) }

        let finished = jobs.filter { !$0.isActive }
        if finished.count > Self.keepFinished {
            let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
            jobs.removeAll { drop.contains($0.id) }
        }
        changed(job)
        startNextIfIdle()
    }

    private func changed(_ job: Job) {
        job.onChange?()
        onChange?()
    }
}

/// Completion notifications for jobs that ran long enough to leave the wheel.
@MainActor
enum Notifier {
    nonisolated static let revealAction = "reveal"
    nonisolated static let trashAction = "trash"
    nonisolated static let category = "jobDone"
    /// userInfo key for the output paths, so "Show in Finder" works after the job is gone.
    nonisolated static let outputsKey = "outputs"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let reveal = UNNotificationAction(identifier: revealAction, title: "Show in Finder")
        let trash = UNNotificationAction(identifier: trashAction, title: "Move to Trash", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [reveal, trash],
                                                                 intentIdentifiers: [])])
    }

    /// Asked the first time a job is handed off, rather than at launch.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(for job: Job) {
        let content = UNMutableNotificationContent()
        content.title = job.title
        content.body = summary(for: job)
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = [outputsKey: job.outputs.prefix(500).map(\.path)]
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func summary(for job: Job) -> String {
        let saved = job.outputs.count
        var parts = ["\(saved) \(saved == 1 ? "file" : "files") saved"]
        if !job.failures.isEmpty { parts.append("\(job.failures.count) failed") }
        if let saving = job.savingText { parts.append(saving) }
        if job.state == .cancelled { parts.insert("Cancelled", at: 0) }
        return parts.joined(separator: " · ")
    }
}
