import AppKit
import CargoServices

/// One icon-view cell: thumbnail over a two-line name, styled like Finder.
final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileCollectionItem")
    private static let labelFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)

    private let thumbnail = ThumbnailCanvas()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let labelBackground = NSView()
    private var loadTask: Task<Void, Never>?
    private var iconSize: CGFloat = 0

    override func loadView() {
        view = NSView()

        labelBackground.wantsLayer = true
        labelBackground.layer?.cornerRadius = 4

        label.font = Self.labelFont
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true

        view.addSubview(thumbnail)
        view.addSubview(labelBackground)
        view.addSubview(label)
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { applySelection() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let padding = GridMetrics.padding
        thumbnail.frame = NSRect(x: (bounds.width - iconSize) / 2 - padding, y: bounds.height - iconSize - padding * 2, width: iconSize + padding * 2, height: iconSize + padding * 2)

        let available = bounds.width - padding
        let fitted = label.sizeThatFits(NSSize(width: available, height: GridMetrics.labelHeight))
        let labelWidth = min(available, ceil(fitted.width) + 2)
        let labelHeight = min(GridMetrics.labelHeight, ceil(fitted.height))
        label.frame = NSRect(x: (bounds.width - labelWidth) / 2, y: thumbnail.frame.minY - labelHeight - 2, width: labelWidth, height: labelHeight)
        labelBackground.frame = label.frame.insetBy(dx: -3, dy: -1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        thumbnail.image = nil
    }

    func configure(_ item: RemoteItem, iconSize: CGFloat, browser: BrowserModel) {
        self.iconSize = iconSize
        label.stringValue = item.name
        thumbnail.icon = FileIcons.icon(for: item)
        thumbnail.isVideo = FileCategory(item) == .video
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.cell)
        view.setAccessibilityLabel(item.name)
        applySelection()
        view.needsLayout = true

        loadTask?.cancel()
        guard ThumbnailService.canPreview(item), let deviceID = browser.deviceID else {
            return
        }
        let pixels = Int(iconSize * (view.window?.backingScaleFactor ?? 2))
        loadTask = Task { [weak self, thumbnails = browser.app.thumbnails] in
            let image = await thumbnails.thumbnail(for: item, deviceID: deviceID, maxPixelSize: pixels)
            guard !Task.isCancelled else {
                return
            }
            self?.thumbnail.image = image
        }
    }

    /// Finder's look: grey rounded backdrop behind the icon, accent pill behind the name.
    private func applySelection() {
        let selected = isSelected || highlightState == .forSelection || highlightState == .asDropTarget
        let isKey = view.window?.isKeyWindow ?? true
        thumbnail.isHighlighted = selected
        labelBackground.layer?.backgroundColor = selected
            ? (isKey ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).cgColor
            : nil
        label.textColor = selected && isKey ? .alternateSelectedControlTextColor : .labelColor
    }
}

/// Draws a thumbnail aspect-fit with rounded corners, or the file-type icon.
final class ThumbnailCanvas: NSView {
    private static let cornerRadius: CGFloat = 4
    private static let highlightRadius: CGFloat = 6

    var image: CGImage? { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var isVideo = false { didSet { needsDisplay = true } }
    var isHighlighted = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Self.highlightRadius, yRadius: Self.highlightRadius).fill()
        }
        let content = bounds.insetBy(dx: GridMetrics.padding, dy: GridMetrics.padding)

        guard let image else {
            icon?.draw(in: content)
            return
        }

        let scale = min(content.width / CGFloat(image.width), content.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = NSRect(x: content.midX - size.width / 2, y: content.maxY - size.height, width: size.width, height: size.height)

        // Hairline border, like Finder's photo thumbnails.
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSImage(cgImage: image, size: size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        if isVideo {
            drawVideoBadge(in: rect)
        }
    }

    private func drawVideoBadge(in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: max(10, rect.width * 0.12), weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return
        }
        let origin = NSPoint(x: rect.minX + 5, y: rect.maxY - symbol.size.height - 5)
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 2
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        symbol.draw(in: NSRect(origin: origin, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Context menu for AppKit views, mirroring the SwiftUI list menu.
struct ItemMenuBuilder {
    let browser: BrowserModel
    let items: [RemoteItem]

    func build() -> NSMenu {
        let menu = NSMenu()
        if items.count == 1, let item = items.first, item.isDirectory {
            menu.addItem(ClosureMenuItem.make(String(localized: "Open")) { browser.open(item) })
            menu.addItem(.separator())
        }
        let downloadTitle = items.count == 1 ? String(localized: "Download") : String(localized: "Download \(items.count) Items")
        menu.addItem(ClosureMenuItem.make(downloadTitle) { browser.download(items) })
        menu.addItem(ClosureMenuItem.make(String(localized: "Download To…")) { browser.requestDownload(items) })
        if items.contains(where: { !$0.isDirectory }) {
            menu.addItem(ClosureMenuItem.make(String(localized: "Quick Look")) { Task { await browser.toggleQuickLook() } })
        }
        menu.addItem(.separator())

        if items.count == 1, let item = items.first {
            menu.addItem(ClosureMenuItem.make(String(localized: "Rename…")) { browser.renameTarget = item })
            if item.isDirectory, let deviceID = browser.deviceID {
                let settings = browser.app.settings
                let title = settings.isFavorite(item.path, deviceID: deviceID)
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites")
                menu.addItem(ClosureMenuItem.make(title) { settings.toggleFavorite(item.path, deviceID: deviceID) })
            }
            menu.addItem(ClosureMenuItem.make(String(localized: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem.make(String(localized: "Cut")) { browser.putSelectionOnClipboard(.move) })
        menu.addItem(ClosureMenuItem.make(String(localized: "Copy")) { browser.putSelectionOnClipboard(.copy) })
        menu.addItem(ClosureMenuItem.make(String(localized: "Delete…")) { browser.pendingDeletion = items })
        return menu
    }
}

/// Menu item that runs a closure. NSMenuItem is not subclassed because its
/// initializers are nonisolated while this app defaults to the main actor.
enum ClosureMenuItem {
    static func make(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
        item.target = MenuActionTarget.shared
        item.representedObject = MenuAction(handler)
        return item
    }
}

private final class MenuAction {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}

private final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.handler()
    }
}
