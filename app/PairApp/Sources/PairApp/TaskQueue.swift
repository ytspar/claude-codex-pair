import Foundation

/// Persistent task queue. Users add tasks; when Claude goes idle after
/// Codex approves, the next pending task is automatically injected.
class TaskQueue: ObservableObject {
    static let shared = TaskQueue()

    @Published var items: [TaskItem] = []
    @Published var isRunning = false {
        didSet { saveRunningState() }
    }

    enum TaskStatus: String, Codable {
        case pending, active, completed, failed
    }

    struct TaskItem: Identifiable, Codable {
        let id: UUID
        var title: String
        var prompt: String
        var status: TaskStatus
        let createdAt: Date
        var completedAt: Date?

        init(title: String, prompt: String) {
            self.id = UUID()
            self.title = title.isEmpty ? String(prompt.prefix(60)) : title
            self.prompt = prompt
            self.status = .pending
            self.createdAt = Date()
        }
    }

    struct Snapshot {
        let isRunning: Bool
        let pendingCount: Int
        let activeTitle: String?
        let items: [TaskItem]
    }

    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var hasPending: Bool { items.contains { $0.status == .pending } }
    var activeTask: TaskItem? { items.first { $0.status == .active } }

    /// Current project directory — set when active session changes.
    /// Queue loads/saves to `{projectDir}/.codex-pair/task-queue.json`.
    private(set) var projectDir: String? {
        didSet {
            if projectDir != oldValue { load() }
        }
    }

    private var filePath: String {
        Self.queueFilePath(for: projectDir)
    }

    private var runningFlagPath: String {
        Self.runningFlagPath(for: projectDir)
    }

    private init() {
        load()
        isRunning = FileManager.default.fileExists(atPath: runningFlagPath)
    }

    /// Switch to a project's queue. Called when active session changes.
    func setProject(_ cwd: String?) {
        onMain {
            if self.projectDir != cwd {
                PairLog.info("TaskQueue switching to project: \(cwd ?? "global")")
                self.projectDir = cwd
                self.isRunning = FileManager.default.fileExists(atPath: self.runningFlagPath)
            }
        }
    }

    // MARK: - Mutations
    // All mutations dispatch to main thread to protect @Published items.
    // Safe to call from any thread.

    func addTask(title: String = "", prompt: String) {
        onMain {
            let displayTitle = title.isEmpty ? String(prompt.prefix(60)) : title
            // Dedup: skip if a pending/active task with the same title or prompt already exists
            let isDuplicate = self.items.contains { item in
                (item.status == .pending || item.status == .active) &&
                (item.prompt.prefix(80) == prompt.prefix(80) || (!title.isEmpty && item.title == title))
            }
            if isDuplicate {
                PairLog.info("Task queue dedup: skipping duplicate '\(displayTitle.prefix(50))'")
                return
            }
            PairLog.action("queue", action: "TASK_ADDED", detail: displayTitle)
            self.items.append(TaskItem(title: title, prompt: prompt))
            self.save()
        }
    }

    func removeTask(id: UUID) {
        onMain {
            self.items.removeAll { $0.id == id }
            self.save()
        }
    }

    func moveTask(from source: IndexSet, to destination: Int) {
        onMain {
            var mutable = self.items
            mutable.move(fromOffsets: source, toOffset: destination)
            self.items = mutable
            self.save()
        }
    }

    func moveToTop(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            let item = self.items.remove(at: idx)
            let insertAt = self.items.firstIndex(where: { $0.status != .active }) ?? 0
            self.items.insert(item, at: insertAt)
            self.save()
        }
    }

    func updateTask(id: UUID, title: String? = nil, prompt: String? = nil) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            if let title = title { self.items[idx].title = title }
            if let prompt = prompt { self.items[idx].prompt = prompt }
            self.save()
        }
    }

    func nextPending() -> TaskItem? {
        onMainValue {
            guard self.isRunning else { return nil }
            return self.items.first { $0.status == .pending }
        }
    }

    func start() {
        onMain {
            PairLog.action("queue", action: "QUEUE_START", detail: "pending=\(self.pendingCount)")
            self.isRunning = true
        }
    }

    func stop() {
        onMain {
            PairLog.action("queue", action: "QUEUE_STOP", detail: "pending=\(self.pendingCount)")
            self.isRunning = false
        }
    }

    func markActive(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            PairLog.action("queue", action: "TASK_ACTIVE", detail: self.items[idx].title)
            self.items[idx].status = .active
            self.save()
        }
    }

    func markCompleted(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            PairLog.action("queue", action: "TASK_COMPLETED", detail: "\(self.items[idx].title) remaining=\(self.items.filter { $0.status == .pending }.count - 1)")
            self.items[idx].status = .completed
            self.items[idx].completedAt = Date()
            // Auto-stop when no more pending tasks
            if self.items.filter({ $0.status == .pending }).isEmpty {
                PairLog.action("queue", action: "QUEUE_AUTO_STOP", detail: "no more pending tasks")
                self.isRunning = false
            }
            self.save()
        }
    }

    func markFailed(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            PairLog.action("queue", action: "TASK_FAILED", detail: self.items[idx].title)
            self.items[idx].status = .failed
            self.save()
        }
    }

    func retry(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[idx].status = .pending
            self.items[idx].completedAt = nil
            self.save()
        }
    }

    func retryActiveTask() -> TaskItem? {
        onMainValue {
            guard let idx = self.items.firstIndex(where: { $0.status == .active }) else { return nil }
            let task = self.items[idx]
            self.items[idx].status = .pending
            self.items[idx].completedAt = nil
            self.save()
            return task
        }
    }

    func completeActiveTask() -> (completed: TaskItem?, hasPending: Bool) {
        onMainValue {
            guard let idx = self.items.firstIndex(where: { $0.status == .active }) else {
                return (nil, self.items.contains { $0.status == .pending })
            }
            let task = self.items[idx]
            PairLog.action("queue", action: "TASK_COMPLETED", detail: "\(task.title) remaining=\(max(self.items.filter { $0.status == .pending }.count, 0))")
            self.items[idx].status = .completed
            self.items[idx].completedAt = Date()
            let hasPending = self.items.contains { $0.status == .pending }
            if !hasPending {
                PairLog.action("queue", action: "QUEUE_AUTO_STOP", detail: "no more pending tasks")
                self.isRunning = false
            }
            self.save()
            return (task, hasPending)
        }
    }

    func advanceAfterPrompt(madeProgress: Bool) -> (completed: TaskItem?, next: TaskItem?) {
        onMainValue {
            guard self.isRunning else { return (nil, nil) }

            var completed: TaskItem?
            var next: TaskItem?

            if let activeIdx = self.items.firstIndex(where: { $0.status == .active }) {
                guard madeProgress else { return (nil, nil) }
                completed = self.items[activeIdx]
                PairLog.action("queue", action: "TASK_COMPLETED", detail: "\(self.items[activeIdx].title) remaining=\(max(self.items.filter { $0.status == .pending }.count - 1, 0))")
                self.items[activeIdx].status = .completed
                self.items[activeIdx].completedAt = Date()
            }

            if let pendingIdx = self.items.firstIndex(where: { $0.status == .pending }) {
                PairLog.action("queue", action: "TASK_ACTIVE", detail: self.items[pendingIdx].title)
                self.items[pendingIdx].status = .active
                next = self.items[pendingIdx]
            } else if completed != nil {
                PairLog.action("queue", action: "QUEUE_AUTO_STOP", detail: "no more pending tasks")
                self.isRunning = false
            }

            if completed != nil || next != nil {
                self.save()
            }
            return (completed, next)
        }
    }

    func snapshot() -> Snapshot {
        onMainValue {
            Snapshot(
                isRunning: self.isRunning,
                pendingCount: self.pendingCount,
                activeTitle: self.activeTask?.title,
                items: self.items
            )
        }
    }

    static func snapshot(forProject cwd: String?) -> Snapshot {
        let path = queueFilePath(for: cwd)
        let runningPath = runningFlagPath(for: cwd)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded: [TaskItem]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? decoder.decode([TaskItem].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        let running = FileManager.default.fileExists(atPath: runningPath)
        return Snapshot(
            isRunning: running,
            pendingCount: loaded.filter { $0.status == .pending }.count,
            activeTitle: loaded.first { $0.status == .active }?.title,
            items: loaded
        )
    }

    func clearCompleted() {
        onMain {
            self.items.removeAll { $0.status == .completed }
            self.save()
        }
    }

    func clearDone() {
        onMain {
            self.items.removeAll { $0.status == .completed || $0.status == .failed }
            self.save()
        }
    }

    func clearAll() {
        onMain {
            self.items.removeAll()
            self.save()
        }
    }

    /// Dispatch to main thread; run synchronously if already on main to avoid deadlocks.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func onMainValue<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    // MARK: - Persistence

    private static func queueFilePath(for cwd: String?) -> String {
        if let dir = cwd {
            return "\(dir)/.codex-pair/task-queue.json"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/task-queue.json"
    }

    private static func runningFlagPath(for cwd: String?) -> String {
        if let dir = cwd {
            return "\(dir)/.codex-pair/task-queue-running"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/task-queue-running"
    }

    private func saveRunningState() {
        let path = runningFlagPath
        let running = isRunning
        DispatchQueue.global(qos: .utility).async {
            if running {
                FileManager.default.createFile(atPath: path, contents: nil)
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        let path = filePath
        DispatchQueue.global(qos: .utility).async {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let loaded = try? decoder.decode([TaskItem].self, from: data) else { return }
        // Reset any active tasks to pending on load (app was restarted)
        items = loaded.map { item in
            var item = item
            if item.status == .active { item.status = .pending }
            return item
        }
    }
}
