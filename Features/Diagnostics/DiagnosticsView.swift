//
//  DiagnosticsView.swift
//  Hoshi Reader
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct DiagnosticsView: View {
    @State private var sections: [String]?
    @State private var file: URL?

    var body: some View {
        Group {
            if let sections {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            Text(section)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("diagnostics-report")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let file {
                ShareLink(item: file) { Label("Share Diagnostics", systemImage: "square.and.arrow.up") }
            }
        }
        .task {
            let report = await DiagnosticsReport.current()
            sections = report.sections
            // The share sheet saves or sends a file, so the report keeps its name and line breaks.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(DiagnosticsReport.fileName())
            if (try? Data(report.text.utf8).write(to: url, options: .atomic)) != nil { file = url }
        }
    }
}
