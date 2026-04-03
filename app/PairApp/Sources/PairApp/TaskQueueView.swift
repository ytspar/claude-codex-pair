import SwiftUI
import UniformTypeIdentifiers

/// Task queue UI — compact list with full-text display, inline remove,
/// and drag-to-reorder. Header/controls live in the parent tab bar.
struct TaskQueueView: View {
    @ObservedObject private var queue = TaskQueue.shared
    @ObservedObject private var tm = ThemeManager.shared
    @State private var newTaskText = ""
    @State private var editingId: UUID? = nil
    @State private var editText = ""
    @State private var draggingId: UUID? = nil
    @State private var dropTargetId: UUID? = nil
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Paused indicator
            if !queue.isRunning && queue.pendingCount > 0 {
                Text("PAUSED")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.textMuted.opacity(0.5))
                    .tracking(0.5)
                    .padding(.bottom, 4)
            }

            // Task list
            if !queue.items.isEmpty {
                taskList
            }

            // Add task input
            addTaskField
                .padding(.top, queue.items.isEmpty ? 0 : 4)
        }
    }

    // MARK: - Task list

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(queue.items) { item in
                if editingId == item.id {
                    editRow(item: item)
                } else {
                    taskRow(item: item)
                        .onDrag {
                            draggingId = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: TaskDropDelegate(
                            targetId: item.id,
                            queue: queue,
                            draggingId: $draggingId,
                            dropTargetId: $dropTargetId
                        ))
                }
            }
        }
    }

    private func taskRow(item: TaskQueue.TaskItem) -> some View {
        let isDropTarget = dropTargetId == item.id && draggingId != item.id

        return HStack(alignment: .top, spacing: 8) {
            // Status dot
            statusDot(item.status)
                .padding(.top, 4)

            // Full prompt text — no truncation
            Text(item.prompt)
                .font(Theme.monoTiny)
                .foregroundColor(textColor(item.status))
                .strikethrough(item.status == .completed, color: tm.textMuted.opacity(0.4))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // Active indicator
            if item.status == .active {
                Text("RUNNING")
                    .font(Theme.monoTiny)
                    .foregroundColor(tm.warning)
                    .tracking(0.5)
            }

            // Remove button
            Button(action: { queue.removeTask(id: item.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(tm.textMuted.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .overlay(
            isDropTarget
                ? Rectangle().fill(tm.accent).frame(height: 1).offset(y: -3)
                : nil,
            alignment: .top
        )
        .contentShape(Rectangle())
        .contextMenu { contextMenu(item: item) }
    }

    private func editRow(item: TaskQueue.TaskItem) -> some View {
        HStack(spacing: 8) {
            statusDot(item.status)

            TextField("Task prompt", text: $editText, axis: .vertical)
                .font(Theme.monoTiny)
                .textFieldStyle(.plain)
                .foregroundColor(tm.text)
                .lineLimit(6)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(tm.textMuted.opacity(0.5))
                .frame(width: 5, height: 5, alignment: .center)
                .padding(.top, 4)

            TextField("Add task\u{2026}", text: $newTaskText, axis: .vertical)
                .font(Theme.monoTiny)
                .textFieldStyle(.plain)
                .foregroundColor(tm.text)
                .lineLimit(4)
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

// MARK: - Drag-to-reorder

struct TaskDropDelegate: DropDelegate {
    let targetId: UUID
    let queue: TaskQueue
    @Binding var draggingId: UUID?
    @Binding var dropTargetId: UUID?

    func dropEntered(info: DropInfo) {
        dropTargetId = targetId
    }

    func dropExited(info: DropInfo) {
        if dropTargetId == targetId { dropTargetId = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceId = draggingId else { return false }
        guard sourceId != targetId else { draggingId = nil; dropTargetId = nil; return false }

        let items = queue.items
        guard let fromIndex = items.firstIndex(where: { $0.id == sourceId }),
              let toIndex = items.firstIndex(where: { $0.id == targetId }) else {
            draggingId = nil
            dropTargetId = nil
            return false
        }

        withAnimation(.easeOut(duration: 0.15)) {
            queue.moveTask(from: IndexSet(integer: fromIndex), to: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }

        draggingId = nil
        dropTargetId = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }
}
