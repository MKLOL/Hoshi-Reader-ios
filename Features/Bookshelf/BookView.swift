//
//  BookView.swift
//  Hoshi Reader
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct BookView: View {
    let book: BookMetadata
    let progress: Double
    /// When set (mokuro books), shown in place of the percentage label.
    var pageLabel: String? = nil
    var isSelected: Bool = false
    var hasPretranslations: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            BookCover(
                book: book,
                progress: progress,
                pageLabel: pageLabel,
                isSelected: isSelected,
                hasPretranslations: hasPretranslations
            )
            
            Text(book.title ?? "")
                .font(.system(size: 16))
                .lineLimit(2)
                .frame(height: 40, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BookCover: View {
    let book: BookMetadata
    var progress: Double? = nil
    /// When set (mokuro books), shown in place of the percentage label.
    var pageLabel: String? = nil
    var isSelected: Bool = false
    var hasPretranslations: Bool = false
    
    private let coverAspectRatio: CGFloat = 0.709
    private let innerCornerRadius: CGFloat = 6
    private let outerCornerRadius: CGFloat = 7
    
    var body: some View {
        if #available(iOS 26, *) {
            cover
                .padding(3)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous))
        } else {
            cover
                .padding(3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                        .stroke(.primary.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 2)
        }
    }
    
    private var cover: some View {
        VStack(spacing: progress == nil ? 0 : 3) {
            CoverImage(url: book.coverURL, maxPixelSize: 768) { image in
                // Fill the book shape instead of stretching an image of another shape, centred
                // as on Android; taps stay inside the shape, not on the cropped overflow.
                Color.clear
                    .aspectRatio(coverAspectRatio, contentMode: .fit)
                    .overlay { image.resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous))
            } placeholder: {
                RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(coverAspectRatio, contentMode: .fit)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    checkmark(color: .blue)
                        .padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if hasPretranslations {
                    Image(systemName: "translate")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(5)
                        .background(.regularMaterial, in: Circle())
                        .padding(6)
                        .accessibilityLabel("Offline translations available")
                        .accessibilityIdentifier("book-pretranslation-badge")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isSelected, let progress, progress >= 0.999 {
                    checkmark(color: .gray)
                        .padding(6)
                }
            }
            
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress.isFinite ? min(1, max(0, progress)) : 0)
                        .tint(.secondary.opacity(0.4))
                    Text(pageLabel ?? String(format: "%.1f%%", progress * 100))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
        }
    }
    
    private func checkmark(color: Color) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(.white, color)
    }
}
