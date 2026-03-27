import SwiftUI

/// Built-in project picker with recent projects list and directory browser.
struct ProjectPickerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var store = RecentProjectsStore()
    @State private var searchText = ""
    @State private var browsePath: String = NSHomeDirectory() + "/git"
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18))
                    .foregroundColor(themeManager.accent)
                Text("SELECT PROJECT")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(themeManager.accent)
                    .tracking(1.5)
                Spacer()
                Button(action: openFinderPicker) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Browse...")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(themeManager.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(themeManager.textMuted)
                TextField("Search projects...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(themeManager.bg.opacity(0.5))
            .cornerRadius(6)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider().background(themeManager.border)

            // Recent projects list
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredProjects.isEmpty && !store.recentProjects.isEmpty {
                        Text("No matching projects")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.textMuted)
                            .padding(20)
                    } else if store.recentProjects.isEmpty {
                        VStack(spacing: 12) {
                            Text("No recent projects")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(themeManager.textMuted)
                            Text("Use Browse or scan ~/git to get started")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(themeManager.textMuted)
                        }
                        .padding(20)
                    }

                    ForEach(filteredProjects) { project in
                        ProjectRow(project: project) {
                            store.recordOpen(project.path)
                            onSelect(project.path)
                        }
                    }
                }
            }

            Divider().background(themeManager.border)

            // Footer: scan for projects
            HStack {
                Button("Scan ~/git") {
                    store.scanDirectory(NSHomeDirectory() + "/git")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(themeManager.accent)

                Spacer()

                Text("\(store.recentProjects.count) projects")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(themeManager.bgElevated)
        .onAppear {
            if store.recentProjects.isEmpty {
                store.scanDirectory(NSHomeDirectory() + "/git")
            }
        }
    }

    private var filteredProjects: [RecentProject] {
        if searchText.isEmpty { return store.recentProjects }
        let lower = searchText.lowercased()
        return store.recentProjects.filter {
            $0.name.lowercased().contains(lower) || $0.path.lowercased().contains(lower)
        }
    }

    private func openFinderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/git")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                store.recordOpen(url.path)
                onSelect(url.path)
            }
        }
    }
}

struct ProjectRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let project: RecentProject
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.hasGit ? "chevron.left.forwardslash.chevron.right" : "folder")
                .font(.system(size: 14))
                .foregroundColor(project.hasGit ? themeManager.accent : themeManager.textMuted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(themeManager.text)
                Text(project.shortPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
            }

            Spacer()

            if let lastOpened = project.lastOpened {
                Text(timeAgo(lastOpened))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(themeManager.textMuted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isHovered ? themeManager.accent.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Data

struct RecentProject: Identifiable, Codable {
    var id: String { path }
    let name: String
    let path: String
    let hasGit: Bool
    var lastOpened: Date?

    var shortPath: String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

class RecentProjectsStore: ObservableObject {
    @Published var recentProjects: [RecentProject] = []

    private let storePath: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        storePath = "\(home)/.claude-codex-pair/recent-projects.json"
        load()
    }

    func load() {
        guard let data = FileManager.default.contents(atPath: storePath),
              let projects = try? JSONDecoder().decode([RecentProject].self, from: data) else { return }
        recentProjects = projects.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(recentProjects) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
    }

    func recordOpen(_ path: String) {
        if let idx = recentProjects.firstIndex(where: { $0.path == path }) {
            recentProjects[idx].lastOpened = Date()
        } else {
            let name = String(path.split(separator: "/").last ?? "project")
            let hasGit = FileManager.default.fileExists(atPath: "\(path)/.git")
            recentProjects.insert(RecentProject(name: name, path: path, hasGit: hasGit, lastOpened: Date()), at: 0)
        }
        save()
    }

    func scanDirectory(_ dir: String, depth: Int = 2) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [RecentProject] = []
            self?.scanRecursive(dir, depth: depth, found: &found)

            DispatchQueue.main.async {
                // Merge with existing (keep lastOpened dates)
                let existing = Dictionary(uniqueKeysWithValues: (self?.recentProjects ?? []).map { ($0.path, $0) })
                for project in found {
                    if existing[project.path] == nil {
                        self?.recentProjects.append(project)
                    }
                }
                self?.recentProjects.sort { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
                self?.save()
            }
        }
    }

    private func scanRecursive(_ dir: String, depth: Int, found: inout [RecentProject]) {
        guard depth > 0 else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }

        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let fullPath = "\(dir)/\(entry)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let hasGit = FileManager.default.fileExists(atPath: "\(fullPath)/.git")
            if hasGit {
                found.append(RecentProject(name: entry, path: fullPath, hasGit: true, lastOpened: nil))
            } else {
                scanRecursive(fullPath, depth: depth - 1, found: &found)
            }
        }
    }
}
