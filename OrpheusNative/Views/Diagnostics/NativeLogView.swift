import AppKit
import NativeQobuzCore
import SwiftUI

struct NativeLogView: View {
    @EnvironmentObject private var vm: NativeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [QobuzLogEntry] = []
    @State private var selectedID: UUID?
    @State private var minimumLevel: QobuzLogLevel = .trace
    @State private var category = "All"
    @State private var query = ""
    @State private var autoRefresh = true
    @State private var message: String?
    @State private var loadError: String?
    @State private var confirmClear = false
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(filteredEntries, selection: $selectedID) {
                TableColumn("Time") { entry in
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 82, ideal: 92, max: 110)
                TableColumn("Level") { entry in
                    LogLevelLabel(level: entry.level)
                }
                .width(min: 66, ideal: 76, max: 92)
                TableColumn("Subsystem") { entry in
                    Text(entry.category).font(.caption).lineLimit(1)
                }
                .width(min: 88, ideal: 120, max: 170)
                TableColumn("Event") { entry in
                    Text(entry.message).lineLimit(1)
                }
                TableColumn("Source") { entry in
                    Text("\(URL(fileURLWithPath: entry.sourceFile).lastPathComponent):\(entry.sourceLine)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 125, ideal: 165, max: 230)
            }
            .contextMenu(forSelectionType: UUID.self) { values in
                if let id = values.first, let entry = entries.first(where: { $0.id == id }) {
                    Button("Copy Event", systemImage: "doc.on.doc") { copy(entry) }
                }
            } primaryAction: { values in
                selectedID = values.first
            }

            Divider()
            detail
                .frame(minHeight: 150, idealHeight: 200, maxHeight: 260)
        }
        .frame(minWidth: 900, idealWidth: 1_080, minHeight: 620, idealHeight: 720)
        .searchable(text: $query, placement: .toolbar, prompt: "Search message, metadata, source, or error")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $autoRefresh) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .toggleStyle(.button)
                    .help("Refresh automatically")
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
                Button { export() } label: {
                    Image(systemName: isExporting ? "hourglass" : "square.and.arrow.up")
                }
                .disabled(isExporting)
                .help(isExporting ? "Exporting diagnostic bundle" : "Export diagnostic bundle")
                Button(action: vm.revealDiagnostics) { Image(systemName: "folder") }
                    .help("Reveal log files")
                Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    .help("Clear diagnostic history")
                Button("Done") { dismiss() }
            }
        }
        .task {
            refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if autoRefresh { refresh() }
            }
        }
        .alert("Clear all diagnostic logs?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clear() }
        } message: {
            Text("Current and rotated log files will be removed. A new log starts immediately.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Label("Diagnostics", systemImage: "waveform.path.ecg.rectangle")
                    .font(.title2.weight(.semibold))
                Text("\(filteredEntries.count) of \(entries.count) events")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                diagnosticCount(.warning, title: "Warnings")
                diagnosticCount(.error, title: "Errors")
                diagnosticCount(.critical, title: "Critical")
            }
            HStack(spacing: DS.Space.m) {
                Picker("Minimum level", selection: $minimumLevel) {
                    ForEach(QobuzLogLevel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .frame(width: 190)
                Picker("Subsystem", selection: $category) {
                    Text("All").tag("All")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 230)
                Spacer()
                Text(vm.diagnosticsDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(vm.diagnosticsDirectoryPath)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(DS.Space.l)
    }

    @ViewBuilder private var detail: some View {
        if let selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        LogLevelLabel(level: selectedEntry.level)
                        Text(selectedEntry.message).font(.headline).textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { copy(selectedEntry) }
                    }
                    if let error = selectedEntry.errorDescription {
                        LabeledContent("Error") {
                            Text("\(selectedEntry.errorType ?? "Error"): \(error)")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    if let domain = selectedEntry.errorDomain, let code = selectedEntry.errorCode {
                        LabeledContent("Error identity") {
                            Text("\(domain) [\(code)]")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let reason = selectedEntry.errorFailureReason {
                        LabeledContent("Failure reason") { Text(reason).textSelection(.enabled) }
                    }
                    if let suggestion = selectedEntry.errorRecoverySuggestion {
                        LabeledContent("Recovery suggestion") { Text(suggestion).textSelection(.enabled) }
                    }
                    if let underlying = selectedEntry.underlyingErrors, !underlying.isEmpty {
                        LabeledContent("Underlying errors") {
                            Text(underlying.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent("Timestamp") {
                        Text(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(selectedEntry.timestamp))
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Source") {
                        Text("\(selectedEntry.sourceFile):\(selectedEntry.sourceLine) · \(selectedEntry.sourceFunction)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Execution") {
                        Text("session \(selectedEntry.sessionID.uuidString) · \(selectedEntry.thread) · uptime \(selectedEntry.uptime.formatted(.number.precision(.fractionLength(3))))s")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if !selectedEntry.metadata.isEmpty {
                        Divider()
                        Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.xs) {
                            ForEach(selectedEntry.metadata.keys.sorted(), id: \.self) { key in
                                GridRow {
                                    Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(selectedEntry.metadata[key] ?? "")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let callStack = selectedEntry.callStack, !callStack.isEmpty {
                        Divider()
                        DisclosureGroup("Call stack (\(callStack.count) frames)") {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                ForEach(Array(callStack.enumerated()), id: \.offset) { index, frame in
                                    Text("\(index)  \(frame)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Space.xs)
                        }
                    }
                }
                .padding(DS.Space.l)
            }
        } else {
            ContentUnavailableView(
                "Select a diagnostic event",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Exact source location, metadata, correlation identifiers, and errors appear here.")
            )
        }
    }

    private var filteredEntries: [QobuzLogEntry] {
        entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            guard category == "All" || entry.category == category else { return false }
            guard !query.isEmpty else { return true }
            let needle = query.localizedLowercase
            return entry.message.localizedLowercase.contains(needle)
                || entry.category.localizedLowercase.contains(needle)
                || entry.sourceFile.localizedLowercase.contains(needle)
                || (entry.errorDescription?.localizedLowercase.contains(needle) ?? false)
                || (entry.errorDomain?.localizedLowercase.contains(needle) ?? false)
                || (entry.errorFailureReason?.localizedLowercase.contains(needle) ?? false)
                || (entry.errorRecoverySuggestion?.localizedLowercase.contains(needle) ?? false)
                || (entry.underlyingErrors?.joined(separator: " ").localizedLowercase.contains(needle) ?? false)
                || (entry.callStack?.joined(separator: " ").localizedLowercase.contains(needle) ?? false)
                || entry.metadata.contains { key, value in
                    key.localizedLowercase.contains(needle) || value.localizedLowercase.contains(needle)
                }
        }
    }

    private var selectedEntry: QobuzLogEntry? {
        selectedID.flatMap { id in entries.first { $0.id == id } }
    }

    private var categories: [String] {
        Set(entries.map(\.category)).sorted()
    }

    private func diagnosticCount(_ level: QobuzLogLevel, title: String) -> some View {
        let count = entries.count { $0.level == level }
        return Text("\(count) \(title)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(level.color)
    }

    private func refresh() {
        do {
            entries = try vm.diagnosticEntries()
            loadError = nil
            if let selectedID, !entries.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func clear() {
        do {
            try vm.clearDiagnostics()
            selectedID = nil
            message = "Diagnostic history cleared."
            refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func export() {
        guard let parent = FileDialog.chooseFolder(startingAt: NSHomeDirectory()) else { return }
        isExporting = true
        message = "Preparing diagnostic bundle…"
        loadError = nil
        Task {
            defer { isExporting = false }
            do {
                let url = try await vm.exportDiagnostics(to: parent)
                message = "Exported \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                loadError = error.localizedDescription
                message = nil
            }
        }
    }

    private func copy(_ entry: QobuzLogEntry) {
        var lines = [
            Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(entry.timestamp),
            "[\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)",
            "source=\(entry.sourceFile):\(entry.sourceLine) function=\(entry.sourceFunction)",
            "session=\(entry.sessionID.uuidString) thread=\(entry.thread) uptime=\(entry.uptime)"
        ]
        if let error = entry.errorDescription { lines.append("error=\(entry.errorType ?? "Error"): \(error)") }
        if let domain = entry.errorDomain, let code = entry.errorCode {
            lines.append("errorIdentity=\(domain)[\(code)]")
        }
        if let reason = entry.errorFailureReason { lines.append("failureReason=\(reason)") }
        if let suggestion = entry.errorRecoverySuggestion { lines.append("recoverySuggestion=\(suggestion)") }
        if let underlying = entry.underlyingErrors, !underlying.isEmpty {
            lines.append("underlyingErrors:\n" + underlying.joined(separator: "\n"))
        }
        lines.append(contentsOf: entry.metadata.keys.sorted().map { "\($0)=\(entry.metadata[$0]!)" })
        if let callStack = entry.callStack, !callStack.isEmpty {
            lines.append("callStack:\n" + callStack.joined(separator: "\n"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        message = "Copied diagnostic event."
    }
}

private struct LogLevelLabel: View {
    let level: QobuzLogLevel

    var body: some View {
        Text(level.rawValue.uppercased())
            .font(.caption2.weight(.bold).monospaced())
            .foregroundStyle(level.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(level.color.opacity(0.12), in: Capsule())
    }
}

private extension QobuzLogLevel {
    var color: Color {
        switch self {
        case .trace: .secondary
        case .debug: .gray
        case .info: .blue
        case .notice: .green
        case .warning: .orange
        case .error: .red
        case .critical: .purple
        }
    }
}
