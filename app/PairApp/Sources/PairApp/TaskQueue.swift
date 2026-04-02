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

    func addTask(title: String = "", prompt: String) {
        items.append(TaskItem(title: title, prompt: prompt))
        save()
    }

    func removeTask(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func moveTask(from source: IndexSet, to destination: Int) {
        var mutable = items
        mutable.move(fromOffsets: source, toOffset: destination)
        items = mutable
        save()
    }

    func moveToTop(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: idx)
        // Insert after any active task
        let insertAt = items.firstIndex(where: { $0.status != .active }) ?? 0
        items.insert(item, at: insertAt)
        save()
    }

    func updateTask(id: UUID, title: String? = nil, prompt: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let title = title { items[idx].title = title }
        if let prompt = prompt { items[idx].prompt = prompt }
        save()
    }

    func nextPending() -> TaskItem? {
        items.first { $0.status == .pending }
    }

    func markActive(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .active
        save()
    }

    func markCompleted(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .completed
        items[idx].completedAt = Date()
        save()
    }

    func markFailed(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .failed
        save()
    }

    func retry(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .pending
        items[idx].completedAt = nil
        save()
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed }
        save()
    }

    func clearAll() {
        items.removeAll()
        save()
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
