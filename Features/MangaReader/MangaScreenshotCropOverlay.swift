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
//  The action bar (Cancel / Translate) is pinned to the top safe area on a solid contrasting
//  pill so both buttons stay legible over the dimmed page and never collide with the bottom
//  page indicator.
//

import SwiftUI

struct MangaScreenshotCropOverlay: View {
    let containerSize: CGSize
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
        ZStack(alignment: .top) {
            // The drag-to-crop gesture lives on the dimmed backdrop only, so taps on the action
            // bar buttons aren't swallowed by it (a whole-overlay gesture would start a drag
            // instead of activating Cancel/Translate).
            Color.black.opacity(0.36)
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

            actionBar
        }
        .ignoresSafeArea()
    }

    /// Cancel (left) + Translate (right) on a solid pill, pinned just below the status bar.
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                if let rect = currentRect { onConfirm(rect) }
            } label: {
                Text("Translate")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(currentRect == nil ? Color.white.opacity(0.4) : Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(currentRect == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.black.opacity(0.82))
        )
        .padding(.top, max(UIApplication.topSafeArea, 8) + 8)
        // Sits above the drag layer so the buttons stay tappable.
        .zIndex(10)
    }
}
