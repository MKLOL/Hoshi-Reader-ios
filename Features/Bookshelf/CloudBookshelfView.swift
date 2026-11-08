import SwiftUI

/// Cloud entries are intentionally outside selection, reading shelves and installed-book counts.
struct CloudBookshelfView: View {
    var installedBooks: [BookMetadata]
    var sortOption: SortOption
    private var cloud = HttpSyncCloudBooks.shared
    @State private var expanded = false

    private var items: [HttpSyncCloudBookRecord] {
        let installed = Set(installedBooks.compactMap { syncId(for: $0) })
        let visible = cloud.records.filter { !installed.contains($0.syncId) }
        switch sortOption {
        case .recent: return visible.sorted { $0.discoveredAt > $1.discoveredAt }
        case .title: return visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.default.speed(1.5)) { expanded.toggle() }
                } label: {
                    HStack {
                        Text("Not downloaded").font(.title3.bold())
                        Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cloud-manga-section")

                if expanded {
                    Text("Tap a manga to download it for offline reading.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 20) {
                        ForEach(items) { record in cloudCell(record) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 12)], spacing: 12) {
                        ForEach(items.prefix(4)) { record in
                            Button {
                                withAnimation { expanded = true }
                            } label: { cover(record, badge: 34) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand not downloaded manga")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom)
            .animation(.snappy, value: items.map(\.syncId))
        }
    }

    private func cloudCell(_ record: HttpSyncCloudBookRecord) -> some View {
        let state = cloud.downloadState(syncId: record.syncId)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                HttpSyncManager.shared.requestCloudBookDownload(syncId: record.syncId)
            } label: { cover(record, badge: 54) }
            .buttonStyle(.plain)
            .disabled(state.isActive)
            .accessibilityLabel(state.isActive ? record.title : "Download \(record.title)")
            .accessibilityValue(Self.caption(state) ?? "")
            .accessibilityIdentifier("cloud-manga-\(record.syncId)")

            Text(record.title).font(.system(size: 16)).lineLimit(2)
                .frame(height: 40, alignment: .top)
            switch state {
            case .queued, .downloading, .finishing:
                HStack {
                    Text(Self.caption(state) ?? "").monospacedDigit()
                        .accessibilityIdentifier("cloud-manga-status-\(record.syncId)")
                    Spacer(minLength: 2)
                    // An installing manga only waits for its reading position; there is nothing to cancel.
                    if state != .finishing {
                        Button("Cancel") { HttpSyncManager.shared.cancelCloudBookDownload(syncId: record.syncId) }
                    }
                }.font(.caption)
            case .failed(let error):
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry download") {
                    HttpSyncManager.shared.requestCloudBookDownload(syncId: record.syncId)
                }.font(.caption)
            case .available:
                Text(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    static func caption(_ state: HttpSyncCloudDownloadState) -> String? {
        switch state {
        case .queued: return "Waiting…"
        case .downloading(let fraction): return "Downloading… \(Int((fraction * 100).rounded(.down)))%"
        case .finishing: return "Finishing…"
        case .available, .failed: return nil
        }
    }

    /// The App Store's download badge: a filling ring while transferring, a spinner while waiting
    /// or installing. The collapsed row shows it too, so progress is never hidden.
    @ViewBuilder private func progressBadge(_ state: HttpSyncCloudDownloadState, size: CGFloat) -> some View {
        switch state {
        case .downloading(let fraction):
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(.secondary.opacity(0.3), lineWidth: size / 13).padding(size / 9)
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(.tint, style: StrokeStyle(lineWidth: size / 13, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(size / 9)
                    .animation(.linear(duration: 0.25), value: fraction)
            }.frame(width: size, height: size)
        case .queued, .finishing:
            ZStack { Circle().fill(.regularMaterial); ProgressView().controlSize(size < 40 ? .small : .regular) }
                .frame(width: size, height: size)
        case .available, .failed:
            EmptyView()
        }
    }

    private func cover(_ record: HttpSyncCloudBookRecord, badge: CGFloat) -> some View {
        let state = cloud.downloadState(syncId: record.syncId)
        return coverImage(record)
            .opacity(state.isActive ? 0.45 : 1)
            .overlay { progressBadge(state, size: badge) }
    }

    private func coverImage(_ record: HttpSyncCloudBookRecord) -> some View {
        CoverImage(url: cloud.coverURL(record), maxPixelSize: 768) { image in
            // The shelf's book shape, filled rather than stretched (see BookView).
            Color.clear.aspectRatio(0.709, contentMode: .fit)
                .overlay { image.resizable().scaledToFill() }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        } placeholder: {
            RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.25))
                .aspectRatio(0.709, contentMode: .fit)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: record.downloadError == nil ? "icloud.and.arrow.down" : "exclamationmark.icloud")
                .font(.system(size: 15, weight: .semibold))
                .padding(6).background(.regularMaterial, in: Circle()).padding(6)
        }
    }
}
