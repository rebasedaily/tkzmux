// The read-only file viewer that a file tab puts in place of the pane tree.
//
// A header naming the file with a READ-ONLY tag, over a non-editable `NSTextView`. Markdown is
// rendered (`MarkdownRenderer`); anything else is shown verbatim in the terminal's mono face.

import AppKit
import TkzCore

final class FileViewerView: NSView, NSTextViewDelegate {
    /// A relative link in a rendered Markdown file that names another local file.
    var onOpenFile: ((URL) -> Void)?

    private(set) var url: URL?
    private(set) var content: FileViewerContent?

    let textView: NSTextView
    private let scrollView: NSScrollView
    private let header = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let readOnlyLabel = NSTextField(labelWithString: "READ-ONLY")
    private let headerBorder = NSView()
    private var theme: Theme
    private var home: String = NSHomeDirectory()

    static let headerHeight: CGFloat = 28

    init(theme: Theme) {
        self.theme = theme
        scrollView = NSTextView.scrollableTextView()
        // swiftlint:disable:next force_cast
        textView = scrollView.documentView as! NSTextView
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 24, height: 18)
        textView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.font = Theme.Fonts.mono(Theme.Fonts.mono.statusBar)
        readOnlyLabel.font = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.wantsLayer = true
        headerBorder.wantsLayer = true

        for view in [header, scrollView, pathLabel, readOnlyLabel, headerBorder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(header)
        addSubview(scrollView)
        header.addSubview(pathLabel)
        header.addSubview(readOnlyLabel)
        header.addSubview(headerBorder)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            pathLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            pathLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: readOnlyLabel.leadingAnchor, constant: -12),
            readOnlyLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            readOnlyLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerBorder.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerBorder.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `url` in `theme`. Re-reads only when the file changed; re-renders only when either did.
    func show(_ url: URL, theme: Theme, home: String) {
        let fileChanged = url != self.url
        let themeChanged = theme != self.theme
        guard fileChanged || themeChanged else { return }
        self.url = url
        self.theme = theme
        self.home = home
        if fileChanged { content = FileViewerLoader.load(url) }
        applyChrome()
        render()
        if fileChanged { textView.scrollToBeginningOfDocument(nil) }
    }

    private func applyChrome() {
        layer?.backgroundColor = theme.terminalBackground.cgColor
        header.layer?.backgroundColor = theme.paneHeaderBackground.cgColor
        headerBorder.layer?.backgroundColor = theme.border.cgColor
        pathLabel.textColor = theme.paneHeaderPath.nsColor
        readOnlyLabel.textColor = theme.foregroundDim.nsColor
        scrollView.backgroundColor = theme.terminalBackground.nsColor
        textView.backgroundColor = theme.terminalBackground.nsColor
        textView.insertionPointColor = theme.foreground.nsColor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        textView.linkTextAttributes = [
            .foregroundColor: theme.accent.nsColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if let url {
            let path = url.path
            pathLabel.stringValue = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }

    private func render() {
        let rendered: NSAttributedString
        switch content {
        case .markdown(let source):
            rendered = MarkdownRenderer.render(source, theme: theme)
        case .text(let text):
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.1
            rendered = NSAttributedString(
                string: text,
                attributes: [
                    .font: Theme.Fonts.mono(13),
                    .foregroundColor: theme.terminalForeground.nsColor,
                    .paragraphStyle: style,
                ])
        case .notice(let message):
            rendered = NSAttributedString(
                string: message,
                attributes: [
                    .font: Theme.Fonts.ui(Theme.Fonts.ui.title),
                    .foregroundColor: theme.foregroundMuted.nsColor,
                ])
        case nil:
            rendered = NSAttributedString()
        }
        textView.textStorage?.setAttributedString(rendered)
    }

    // MARK: NSTextViewDelegate

    /// Web links open in the browser; a relative link to a file next to this one opens in the
    /// viewer. Anything else is refused rather than handed to `NSWorkspace`, for the same reason
    /// `terminalLinkAction` refuses unknown schemes.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let string = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if let url = URL(string: string), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        {
            NSWorkspace.shared.open(url)
            return true
        }
        guard let base = self.url?.deletingLastPathComponent() else { return true }
        let path = string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let decoded = path.removingPercentEncoding ?? path
        if !decoded.isEmpty,
            let target = FilePathResolver.resolve(decoded, bases: [base.path], home: home)
        {
            onOpenFile?(target)
        }
        return true
    }
}
