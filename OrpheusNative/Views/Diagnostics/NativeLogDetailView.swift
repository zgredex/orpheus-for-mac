import NativeQobuzCore
import SwiftUI

struct NativeLogDetailView: View {
    let entry: QobuzLogEntry?
    let onCopy: (QobuzLogEntry) -> Void

    @ViewBuilder
    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(alignment: .firstTextBaseline) {
                        LogLevelLabel(level: entry.level)
                        Text(entry.message).font(.headline).textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { onCopy(entry) }
                    }
                    errorDetails(entry)
                    executionDetails(entry)
                    metadata(entry)
                    callStack(entry)
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

    @ViewBuilder
    private func errorDetails(_ entry: QobuzLogEntry) -> some View {
        if let error = entry.errorDescription {
            LabeledContent("Error") {
                Text("\(entry.errorType ?? "Error"): \(error)")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        if let domain = entry.errorDomain, let code = entry.errorCode {
            LabeledContent("Error identity") {
                Text("\(domain) [\(code)]")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        if let reason = entry.errorFailureReason {
            LabeledContent("Failure reason") { Text(reason).textSelection(.enabled) }
        }
        if let suggestion = entry.errorRecoverySuggestion {
            LabeledContent("Recovery suggestion") { Text(suggestion).textSelection(.enabled) }
        }
        if let underlying = entry.underlyingErrors, !underlying.isEmpty {
            LabeledContent("Underlying errors") {
                Text(underlying.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func executionDetails(_ entry: QobuzLogEntry) -> some View {
        LabeledContent("Timestamp") {
            Text(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(entry.timestamp))
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
        LabeledContent("Source") {
            Text("\(entry.sourceFile):\(entry.sourceLine) · \(entry.sourceFunction)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        LabeledContent("Execution") {
            Text("session \(entry.sessionID.uuidString) · \(entry.thread) · uptime \(entry.uptime.formatted(.number.precision(.fractionLength(3))))s")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func metadata(_ entry: QobuzLogEntry) -> some View {
        if !entry.metadata.isEmpty {
            Divider()
            Grid(alignment: .leading, horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.xs) {
                ForEach(entry.metadata.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(entry.metadata[key] ?? "")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func callStack(_ entry: QobuzLogEntry) -> some View {
        if let callStack = entry.callStack, !callStack.isEmpty {
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
}

struct LogLevelLabel: View {
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

extension QobuzLogLevel {
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
