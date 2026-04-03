import Foundation

/// Persistent task queue. Users add tasks; when Claude goes idle after
/// Codex approves, the next pending task is automatically injected.
class TaskQueue: ObservableObject {
    static let shared = TaskQueue()

    @Published var items: [TaskItem] = []

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

    var pendingCount: Int { items.filter { $0.status == .pending }.count }
    var activeTask: TaskItem? { items.first { $0.status == .active } }

    private let filePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/task-queue.json"
    }()

    private init() { load() }

    // MARK: - Mutations
    // All mutations dispatch to main thread to protect @Published items.
    // Safe to call from any thread.

    func addTask(title: String = "", prompt: String) {
        onMain {
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
        items.first { $0.status == .pending }
    }

    func markActive(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[idx].status = .active
            self.save()
        }
    }

    func markCompleted(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[idx].status = .completed
            self.items[idx].completedAt = Date()
            self.save()
        }
    }

    func markFailed(id: UUID) {
        onMain {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
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

    func clearCompleted() {
        onMain {
            self.items.removeAll { $0.status == .completed }
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
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        DispatchQueue.global(qos: .utility).async { [filePath] in
            try? data.write(to: URL(fileURLWithPath: filePath))
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
