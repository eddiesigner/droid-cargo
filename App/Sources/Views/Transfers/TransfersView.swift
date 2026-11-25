import CargoServices
import SwiftUI

/// Toolbar button with a progress ring; opens the transfer list.
struct TransfersButton: View {
    @Bindable var app: AppModel

    private var transfers: TransferService { app.transfers }

    var body: some View {
        Button {
            app.isTransfersPopoverShown.toggle()
        } label: {
            if let fraction = transfers.overallFraction {
                ProgressRing(fraction: fraction)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .help("Transfers")
        .accessibilityLabel("Transfers")
        .accessibilityValue(transfers.overallFraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("Idle"))
        .popover(isPresented: $app.isTransfersPopoverShown, arrowEdge: .bottom) {
            TransfersPopover(transfers: transfers)
        }
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
    }
}

struct TransfersPopover: View {
    let transfers: TransferService
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear") { transfers.clearFinished() }
                    .disabled(!transfers.jobs.contains { $0.phase.isFinished })
                    .buttonStyle(.hoverIcon)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if transfers.jobs.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down", description: Text("Downloads and uploads show up here."))
                    .frame(height: 160)
            } else {
                // A bare ScrollView has no natural height, so the popover cut it off.
                // Measure the rows and show them all, scrolling only past the limit.
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            }
        }
        .frame(width: 380)
    }

    private static let maxListHeight: CGFloat = 420

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(transfers.jobs) { job in
                TransferRow(job: job, transfers: transfers)
                if job.id != transfers.jobs.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
    }
}

private struct TransferRow: View {
    let job: TransferJob
    let transfers: TransferService

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: job.direction == .toMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(iconStyle)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !job.phase.isFinished {
                    ProgressView(value: job.fractionCompleted)
                        .progressViewStyle(.linear)
                        .tint(job.phase == .paused ? .secondary : .accentColor)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                if let current = job.currentItemName, job.phase == .running {
                    Text(current)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch job.phase {
            case .running, .preparing:
                iconButton("Pause", "pause.circle") { transfers.pause(job) }
                iconButton("Cancel", "xmark.circle") { transfers.cancel(job) }
            case .paused:
                iconButton("Resume", "play.circle") { transfers.resume(job) }
                iconButton("Cancel", "xmark.circle") { transfers.cancel(job) }
            case .completed:
                if let folder = job.localFolder {
                    iconButton("Show in Finder", "magnifyingglass.circle") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
            case .failed, .cancelled:
                EmptyView()
            }
        }
    }

    private func iconButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title3)
        }
        .buttonStyle(.hoverIcon)
        .help(title)
        .accessibilityLabel(title)
    }

    private var iconStyle: some ShapeStyle {
        switch job.phase {
        case .failed: AnyShapeStyle(.red)
        case .cancelled: AnyShapeStyle(.secondary)
        default: AnyShapeStyle(.tint)
        }
    }

    private var statusIsError: Bool {
        if case .failed = job.phase {
            return true
        }
        return false
    }

    /// e.g. "1.2 GB of 4.8 GB — 38 MB/s — About 2 minutes left"
    private var statusLine: String {
        let done = Int64(job.transferredBytes).formatted(.byteCount(style: .file))
        let total = Int64(job.totalBytes).formatted(.byteCount(style: .file))
        let files = String(localized: "\(job.completedFiles) of \(job.totalFiles) files")

        switch job.phase {
        case .preparing:
            return job.totalFiles == 0
                ? String(localized: "Preparing…")
                : String(localized: "Preparing… found \(job.totalFiles) files (\(total))")
        case .running:
            var parts = ["\(done) of \(total)"]
            if job.bytesPerSecond > 0 {
                parts.append("\(Int64(job.bytesPerSecond).formatted(.byteCount(style: .file)))/s")
            }
            if let eta = job.estimatedTimeRemaining {
                parts.append(Self.remaining(eta))
            }
            return parts.joined(separator: " — ")
        case .paused:
            return String(localized: "Paused — \(done) of \(total)")
        case .completed:
            var summary = String(localized: "\(files) · \(total) · \(job.deviceName)")
            if job.skippedFiles > 0 {
                summary += String(localized: " · \(job.skippedFiles) skipped")
            }
            if !job.failures.isEmpty {
                summary += String(localized: " · \(job.failures.count) failed")
            }
            return summary
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Cancelled — \(files)")
        }
    }

    private static func remaining(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        formatter.includesApproximationPhrase = true
        formatter.includesTimeRemainingPhrase = true
        return formatter.string(from: max(1, seconds)) ?? ""
    }
}
