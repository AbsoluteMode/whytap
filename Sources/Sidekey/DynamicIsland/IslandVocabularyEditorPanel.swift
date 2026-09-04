import AppKit
import SwiftUI

private enum IslandVocabularyEditorStyle {
    static let horizontalPadding: CGFloat = 12
    static let topPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let inputHeight: CGFloat = 30
    static let inputFontSize: CGFloat = 11
    static let inputTextVerticalInset: CGFloat = 7
    static let inputCursorWidth: CGFloat = 1.2
    static let inputCursorHeight: CGFloat = 16
    static let chipHeight: CGFloat = 24
    static let chipMaxWidth: CGFloat = 132
}

struct IslandVocabularyEditorPanel: View {
    @ObservedObject var viewModel: IslandVocabularyViewModel

    @State private var inputFocused = false

    var body: some View {
        VStack(spacing: IslandVocabularyEditorStyle.rowSpacing) {
            vocabularyInput
                .frame(maxWidth: .infinity)
                .padding(.horizontal, IslandVocabularyEditorStyle.horizontalPadding)
                .padding(.top, IslandVocabularyEditorStyle.topPadding)

            ZStack(alignment: .topLeading) {
                if viewModel.state == .loading && viewModel.visibleTerms.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.74))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        IslandVocabularyFlowLayout(spacing: 6) {
                            ForEach(viewModel.visibleTerms, id: \.self) { term in
                                IslandVocabularyChip(term: term) {
                                    Task { await viewModel.removeTerm(term) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, IslandVocabularyEditorStyle.horizontalPadding)
            .padding(.bottom, 8)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }

    private var vocabularyInput: some View {
        ZStack(alignment: .leading) {
            if viewModel.query.isEmpty {
                Text("Search or add, press Enter")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }

            IslandVocabularyInputField(
                text: $viewModel.query,
                isFocused: inputFocused,
                onSubmit: {
                    Task { await viewModel.submitCurrentQuery() }
                }
            )
            .padding(.horizontal, 10)
        }
        .frame(height: IslandVocabularyEditorStyle.inputHeight)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.13))
        )
        .overlay(
            Capsule()
                .stroke(inputBorderColor, lineWidth: 0.8)
        )
    }

    private var inputBorderColor: Color {
        if viewModel.lastRejection != nil {
            return Color.red.opacity(0.62)
        }
        if viewModel.state == .saving {
            return Color.white.opacity(0.28)
        }
        return Color.white.opacity(0.18)
    }
}

private struct IslandVocabularyChip: View {
    let term: String
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(term)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.90))
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.58))
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(maxWidth: IslandVocabularyEditorStyle.chipMaxWidth)
        .frame(height: IslandVocabularyEditorStyle.chipHeight)
        .background(
            Capsule()
                .fill(Color.white.opacity(hovering ? 0.18 : 0.11))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(hovering ? 0.24 : 0.10), lineWidth: 0.7)
        )
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(term)
    }
}

private struct IslandVocabularyFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = max(proposal.width ?? 1, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, availableWidth)
            if x > 0, x + width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(
            width: availableWidth,
            height: subviews.isEmpty ? 0 : y + rowHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let availableWidth = max(bounds.width, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, availableWidth)
            if x > 0, x + width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: size.height)
            )

            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

@MainActor
private struct IslandVocabularyInputField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> IslandVocabularyTextView {
        let textView = IslandVocabularyTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)
        return textView
    }

    func updateNSView(_ textView: IslandVocabularyTextView, context: Context) {
        context.coordinator.parent = self
        textView.delegate = context.coordinator
        textView.shouldAutoFocusOnWindowAttach = isFocused
        Self.configure(textView)

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            let location = min(selectedRange.location, text.utf16.count)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }

        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func configure(_ textView: IslandVocabularyTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.insertionPointColor = textView.vocabularyCursorColor
        textView.font = NSFont.systemFont(
            ofSize: IslandVocabularyEditorStyle.inputFontSize,
            weight: .medium
        )
        textView.alignment = .left
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: textView.font as Any,
            .foregroundColor: textView.textColor as Any,
            .paragraphStyle: paragraphStyle,
        ]
        textView.textContainerInset = NSSize(
            width: 0,
            height: IslandVocabularyEditorStyle.inputTextVerticalInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IslandVocabularyInputField

        init(parent: IslandVocabularyInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string.replacingOccurrences(of: "\n", with: "")
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

@MainActor
private final class IslandVocabularyTextView: NSTextView {
    var shouldAutoFocusOnWindowAttach = false

    var vocabularyCursorColor: NSColor {
        NSColor(white: 1, alpha: 0.86)
    }

    override var acceptsFirstResponder: Bool { true }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard flag else { return }

        var cursorRect = rect
        cursorRect.size.width = IslandVocabularyEditorStyle.inputCursorWidth
        cursorRect.size.height = min(
            IslandVocabularyEditorStyle.inputCursorHeight,
            bounds.height
        )
        cursorRect.origin.y = bounds.midY - cursorRect.height / 2

        super.drawInsertionPoint(
            in: cursorRect,
            color: vocabularyCursorColor,
            turnedOn: flag
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldAutoFocusOnWindowAttach, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }
}
