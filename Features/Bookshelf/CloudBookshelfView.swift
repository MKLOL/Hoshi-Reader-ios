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
                            } label: { cover(record) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand not downloaded manga")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom)
        }
    }

    private func cloudCell(_ record: HttpSyncCloudBookRecord) -> some View {
        let waiting = record.downloadRequestedAt != nil
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                HttpSyncManager.shared.requestCloudBookDownload(syncId: record.syncId)
            } label: {
                cover(record)
                    .opacity(waiting ? 0.45 : 1)
                    .overlay {
                        if waiting {
                            ZStack {
                                Circle().fill(.regularMaterial)
                                if let fraction = cloud.downloads[record.syncId], fraction > 0 {
                                    ProgressView(value: fraction).progressViewStyle(.circular)
                                    Circle().trim(from: 0, to: fraction)
                                        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90)).padding(5)
                                } else { ProgressView() }
                            }.frame(width: 54, height: 54)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(waiting)
            .accessibilityLabel(waiting ? "Downloading \(record.title)" : "Download \(record.title)")
            .accessibilityIdentifier("cloud-manga-\(record.syncId)")

            Text(record.title).font(.system(size: 16)).lineLimit(2)
                .frame(height: 40, alignment: .top)
            if waiting {
                HStack {
                    Text(record.awaitingBookmarkMap ? "Finishing sync…" : "Downloading…")
                    Spacer(minLength: 2)
                    Button("Cancel") {
                        cloud.cancelRequest(syncId: record.syncId)
                        HttpSyncManager.shared.cancelSync()
                    }
                }.font(.caption)
            } else if let error = record.downloadError {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry download") {
                    HttpSyncManager.shared.requestCloudBookDownload(syncId: record.syncId)
                }.font(.caption)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cover(_ record: HttpSyncCloudBookRecord) -> some View {
        CoverImage(url: cloud.coverURL(record), maxPixelSize: 768) { image in
            image.resizable().aspectRatio(0.709, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
