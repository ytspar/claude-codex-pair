import SwiftUI

/// Task queue UI — dispatch board style. Tight rows with status dots,
/// inline add, drag-to-reorder, context menus. Matches the instrumentation aesthetic.
struct TaskQueueView: View {
    @ObservedObject private var queue = TaskQueue.shared
    @ObservedObject private var tm = ThemeManager.shared
    @State private var newTaskText = ""
    @State private var editingId: UUID? = nil
    @State private var editText = ""
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("QUEUE")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted)
                    .tracking(1.0)

                if queue.pendingCount > 0 {
                    Text("\(queue.pendingCount)")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tm.accent.opacity(0.1))
                }

                Spacer()

                if !queue.items.isEmpty {
                    Button(action: { queue.clearAll() }) {
                        Text("Clear")
                            .font(Theme.monoTiny)
                            .foregroundColor(tm.textMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)

            // Task list
            if !queue.items.isEmpty {
                taskList
            }

            // Add task input — directly below header when empty
            addTaskField
                .padding(.top, queue.items.isEmpty ? 0 : 4)
        }
        .padding(.top, 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text("Queue tasks for Claude to work through")
            .font(Theme.monoTiny)
            .foregroundColor(tm.textMuted.opacity(0.4))
            .padding(.vertical, 2)
    }

    // MARK: - Task list

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(queue.items) { item in
                if editingId == item.id {
                    editRow(item: item)
                } else {
                    taskRow(item: item)
                }
            }
            .onMove { source, dest in
                queue.moveTask(from: source, to: dest)
            }
        }
    }

    private func taskRow(item: TaskQueue.TaskItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Status dot — vertically centered with first line of text
            statusDot(item.status)
                .padding(.top, 4)

            // Title — wrap to two lines
            Text(item.title)
                .font(Theme.monoTiny)
                .foregroundColor(textColor(item.status))
                .lineLimit(2)
                .strikethrough(item.status == .completed, color: tm.textMuted.opacity(0.4))

            Spacer()

            // Active indicator
            if item.status == .active {
                Text("RUNNING")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.warning)
                    .tracking(0.5)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .contextMenu { contextMenu(item: item) }
        .onTapGesture(count: 2) {
            editingId = item.id
            editText = item.prompt
        }
    }

    private func editRow(item: TaskQueue.TaskItem) -> some View {
        HStack(spacing: 8) {
            statusDot(item.status)

            TextField("Task prompt", text: $editText)
                .font(Theme.monoTiny)
                .textFieldStyle(.plain)
                .foregroundColor(tm.text)
                .onSubmit {
                    queue.updateTask(id: item.id, title: String(editText.prefix(60)), prompt: editText)
                    editingId = nil
                }

            Button(action: { editingId = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(tm.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .background(tm.accent.opacity(0.05))
    }

    // MARK: - Add task

    private var addTaskField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 9))
                .foregroundColor(tm.textMuted.opacity(0.5))
                .frame(width: 5, alignment: .center)

            TextField("Add task\u{2026}", text: $newTaskText)
                .font(Theme.monoTiny)
                .textFieldStyle(.plain)
                .foregroundColor(tm.text)
                .focused($addFieldFocused)
                .onSubmit { addTask() }

            if !newTaskText.isEmpty {
                Button(action: addTask) {
                    Text("Add")
                        .font(Theme.monoTiny)
                        .foregroundColor(tm.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(item: TaskQueue.TaskItem) -> some View {
        if item.status == .pending {
            Button("Move to top") { queue.moveToTop(id: item.id) }
            Button("Edit") {
                editingId = item.id
                editText = item.prompt
            }
        }
        if item.status == .failed {
            Button("Retry") { queue.retry(id: item.id) }
        }
        Button("Copy prompt") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.prompt, forType: .string)
        }
        Divider()
        Button("Remove", role: .destructive) { queue.removeTask(id: item.id) }
    }

    // MARK: - Helpers

    private func addTask() {
        let text = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.addTask(prompt: text)
        newTaskText = ""
    }

    private func statusDot(_ status: TaskQueue.TaskStatus) -> some View {
        Circle()
            .fill(dotColor(status))
            .frame(width: 5, height: 5)
    }

    private func dotColor(_ status: TaskQueue.TaskStatus) -> Color {
        switch status {
        case .pending: return tm.textMuted
        case .active: return tm.warning
        case .completed: return tm.accent
        case .failed: return tm.error
        }
    }

    private func textColor(_ status: TaskQueue.TaskStatus) -> Color {
        switch status {
        case .pending: return tm.textSecondary
        case .active: return tm.text
        case .completed: return tm.textMuted
        case .failed: return tm.error.opacity(0.8)
        }
    }
}
