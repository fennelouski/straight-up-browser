//
//  MobilePageActions_iOS.swift
//  Browser (iOS)
//
//  Native mobile presentations for desktop page actions: printing, PDF export,
//  visible/full-page snapshots, the system activity sheet, and Reader Mode.
//

import SwiftUI
import UIKit
import WebKit

struct ActivitySheet_iOS: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

enum MobilePageActions_iOS {
    static func printPage(_ webView: WKWebView) {
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
    }

    static func exportPDF(
        _ webView: WKWebView,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            completion(result.flatMap { data in
                Result {
                    let title = sanitizedFilename(webView.title ?? "Page")
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(title)-\(UUID().uuidString).pdf")
                    try data.write(to: url, options: .atomic)
                    return url
                }
            })
        }
    }

    static func snapshot(
        _ webView: WKWebView,
        fullPage: Bool,
        completion: @escaping (Result<UIImage, Error>) -> Void
    ) {
        let configuration: WKSnapshotConfiguration? = if fullPage {
            {
                let value = WKSnapshotConfiguration()
                value.rect = CGRect(origin: .zero, size: webView.scrollView.contentSize)
                value.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
                value.afterScreenUpdates = true
                return value
            }()
        } else {
            nil
        }

        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                completion(.success(image))
            } else {
                completion(.failure(error ?? MobilePageActionError.snapshotFailed))
            }
        }
    }

    private static func sanitizedFilename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Page" : String(cleaned.prefix(80))
    }
}

private enum MobilePageActionError: LocalizedError {
    case snapshotFailed

    var errorDescription: String? { "The page could not be captured." }
}

struct ReaderPresentation_iOS: Identifiable {
    let id = UUID()
    let article: ReaderArticle
}

struct ReaderMode_iOS: View {
    @Environment(\.dismiss) private var dismiss
    let article: ReaderArticle
    let onOpen: (URL) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(.largeTitle.bold())
                        if let byline = article.byline {
                            Text(byline).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 10)

                    ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                        ReaderBlockRow_iOS(block: block)
                    }
                }
                .font(.system(size: 18, design: .serif))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Reader Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            onOpen(url)
            dismiss()
            return .handled
        })
    }
}

private struct ReaderBlockRow_iOS: View {
    let block: ReaderBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let runs):
            Text(attributedText(for: runs))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .accessibilityHeading(headingLevel(level))
                .padding(.top, level <= 2 ? 14 : 8)
        case .paragraph(let runs):
            Text(attributedText(for: runs))
        case .listItem(let ordered, let ordinal, let depth, let runs):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .fontWeight(.semibold)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs))
            }
            .padding(.leading, CGFloat(depth) * 24)
            .accessibilityElement(children: .combine)
        case .quote(let runs):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 4)
                    .accessibilityHidden(true)
                Text(attributedText(for: runs)).italic().foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .caption(let runs):
            Text(attributedText(for: runs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func attributedText(for runs: [ReaderInline]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var fragment = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isStrong { intent.insert(.stronglyEmphasized) }
            if run.isEmphasized { intent.insert(.emphasized) }
            if run.isCode { intent.insert(.code) }
            if !intent.isEmpty { fragment.inlinePresentationIntent = intent }
            fragment.link = run.link
            result.append(fragment)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        case 4: .headline
        case 5: .subheadline
        default: .caption
        }
    }

    private func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}
