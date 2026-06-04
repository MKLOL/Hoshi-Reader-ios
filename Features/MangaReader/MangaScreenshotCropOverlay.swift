//
//  MangaScreenshotCropOverlay.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Ported from Android `features/mangareader/MangaScreenshotCropOverlay.kt`. A full-screen
//  dim + drag-rectangle overlay used for screenshot translation: the user drags a box over the
//  page, then confirms to send the crop (mapped to image pixels by the page script) on for
//  translation, or cancels.
//

import SwiftUI

struct MangaScreenshotCropOverlay: View {
    let containerSize: CGSize
    let darkInterface: Bool
    let onCancel: () -> Void
    let onConfirm: (MangaScreenshotCropRect) -> Void

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?

    private var containerWidth: Int { max(0, Int(containerSize.width.rounded())) }
    private var containerHeight: Int { max(0, Int(containerSize.height.rounded())) }

    /// The visible preview rectangle (any non-empty drag, minSize 1).
    private var previewRect: MangaScreenshotCropRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        return normalizedMangaScreenshotCropRect(
            startX: start.x, startY: start.y, endX: end.x, endY: end.y,
            containerWidth: containerWidth, containerHeight: containerHeight, minSize: 1
        )
    }

    /// The confirmable rectangle (must clear the real minimum size).
    private var currentRect: MangaScreenshotCropRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        return normalizedMangaScreenshotCropRect(
            startX: start.x, startY: start.y, endX: end.x, endY: end.y,
            containerWidth: containerWidth, containerHeight: containerHeight
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .contentShape(Rectangle())

            if let rect = previewRect {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: CGFloat(rect.width), height: CGFloat(rect.height))
                    .overlay(
                        Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 5)
                    )
                    .overlay(
                        Rectangle().stroke(Color.white, lineWidth: 2)
                    )
                    .position(
                        x: CGFloat(rect.left) + CGFloat(rect.width) / 2,
                        y: CGFloat(rect.top) + CGFloat(rect.height) / 2
                    )
                    .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)

                    Button("Translate") {
                        if let rect = currentRect { onConfirm(rect) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(currentRect == nil)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        darkInterface ? Color.black.opacity(0.72) : Color.white.opacity(0.92)
                    )
                )
                .padding(.bottom, 28)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = value.startLocation
                    }
                    dragEnd = value.location
                }
        )
    }
}
