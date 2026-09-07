import DiskReportCore
import DiskReportUI
import SwiftUI

struct SummaryBar: View {
    @ObservedObject var model: AppModel

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                volume
                ForEach(model.summary.roots, id: \.rootPath) { root in
                    VStack(alignment: .leading) {
                        Text(root.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(ByteFormatter.string(root.totalBytes)).font(.headline).monospacedDigit()
                            if let d = root.deltaDay { deltaText(d) }
                        }
                    }
                }
                Spacer()
                scanInfo
            }
            if let banner = bannerText {
                Text(banner)
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
    }

    private var volume: some View {
        VStack(alignment: .leading) {
            Text("Free on volume").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(model.summary.volumeFreeBytes.map(ByteFormatter.string) ?? "—").font(.headline).monospacedDigit()
                if let d = model.summary.volumeFreeDeltaDay { deltaText(d) }
            }
        }
    }

    private var scanInfo: some View {
        VStack(alignment: .trailing) {
            if model.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Scanning…") }
            } else if model.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Loading…") }
            } else if let current = model.reports.compactMap(\.current).first, let f = current.finishedAt {
                Text("Scanned \(DateFormatting.relative(mtime: f, now: now)), \(Int(f - current.startedAt))s")
                    .font(.caption).foregroundStyle(.secondary)
                if let skipped = current.skippedCount, skipped > 0 {
                    Text("\(skipped) entries skipped (see log)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var bannerText: String? {
        if let e = model.scanRunnerError { return e }
        return BannerState.message(reports: model.reports, now: now)
    }

    private func deltaText(_ d: Int64) -> some View {
        Text(DeltaFormatter.string(.changed(d)))
            .font(.subheadline).monospacedDigit()
            .foregroundStyle(d > 0 ? Color.red : (d < 0 ? Color.green : Color.secondary))
    }
}
