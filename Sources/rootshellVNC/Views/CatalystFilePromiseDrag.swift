#if targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers

/// Turns a UIKit mouse drag into an AppKit drag of file promises, so files
/// can land in Finder. AppKit's drag classes are unavailable to Catalyst at
/// compile time; the objects exist at runtime and are reached by name.
@MainActor
final class CatalystFilePromiseDrag: NSObject {
    struct Item {
        let name: String
        /// Writes the item at the URL the destination chose, then calls back.
        let write: (URL, @escaping (Error?) -> Void) -> Void
    }

    private let items: [Item]
    private var pendingWrites: Int
    private var ended = false
    /// AppKit keeps the source and promise delegate weakly.
    private static var active: [CatalystFilePromiseDrag] = []
    private static let leftMouseDragged: UInt = 6
    private static let dragOperationCopy: UInt = 1

    private init(items: [Item]) {
        self.items = items
        pendingWrites = items.count
    }

    /// Must run while AppKit is handling a left-mouse-dragged event.
    static func begin(_ items: [Item]) -> Bool {
        guard !items.isEmpty,
              let app = (NSClassFromString("NSApplication") as? NSObject.Type)?
                .value(forKey: "sharedApplication") as? NSObject,
              let event = app.value(forKey: "currentEvent") as? NSObject,
              event.value(forKey: "type") as? UInt == leftMouseDragged,
              let window = event.value(forKey: "window") as? NSObject,
              let view = window.value(forKey: "contentView") as? NSObject,
              let locationValue = event.value(forKey: "locationInWindow") as? NSValue,
              let providerClass = NSClassFromString("NSFilePromiseProvider") as? NSObject.Type,
              let itemClass = NSClassFromString("NSDraggingItem") as? NSObject.Type,
              let workspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?
                .value(forKey: "sharedWorkspace") as? NSObject
        else { return false }
        addProtocols()

        var location = CGPoint.zero
        locationValue.getValue(&location, size: MemoryLayout<CGPoint>.size)
        let convert = NSSelectorFromString("convertPoint:fromView:")
        let setFrame = NSSelectorFromString("setDraggingFrame:contents:")
        let beginSession = NSSelectorFromString("beginDraggingSessionWithItems:event:source:")
        guard view.responds(to: convert), view.responds(to: beginSession),
              itemClass.instancesRespond(to: setFrame) else { return false }
        typealias Convert = @convention(c) (AnyObject, Selector, CGPoint, AnyObject?) -> CGPoint
        let point = unsafeBitCast(view.method(for: convert), to: Convert.self)(
            view, convert, location, nil)

        let drag = CatalystFilePromiseDrag(items: items)
        var draggingItems: [NSObject] = []
        for (index, item) in items.enumerated() {
            let provider = providerClass.init()
            let ext = (item.name as NSString).pathExtension
            let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
            provider.setValue((type ?? .data).identifier, forKey: "fileType")
            provider.setValue(drag, forKey: "delegate")
            provider.setValue(index, forKey: "userInfo")
            guard let draggingItem = make(itemClass, "initWithPasteboardWriter:", provider) else {
                return false
            }
            let icon = workspace.perform(
                NSSelectorFromString("iconForFileType:"), with: ext.isEmpty ? "public.data" : ext)?
                .takeUnretainedValue()
            let size: CGFloat = 64
            let offset = CGFloat(min(index, 4)) * 6
            let frame = CGRect(
                x: point.x - size / 2 + offset, y: point.y - size / 2 - offset,
                width: size, height: size)
            typealias SetFrame = @convention(c) (AnyObject, Selector, CGRect, AnyObject?) -> Void
            unsafeBitCast(draggingItem.method(for: setFrame), to: SetFrame.self)(
                draggingItem, setFrame, frame, icon)
            draggingItems.append(draggingItem)
        }

        typealias Begin = @convention(c) (
            AnyObject, Selector, NSArray, AnyObject, AnyObject
        ) -> Unmanaged<AnyObject>?
        active.append(drag)
        let session = unsafeBitCast(view.method(for: beginSession), to: Begin.self)(
            view, beginSession, draggingItems as NSArray, event, drag)
        guard session != nil else {
            active.removeAll { $0 === drag }
            return false
        }
        return true
    }

    /// alloc + init through `perform`: init consumes the alloc reference and
    /// returns a retained object.
    private static func make(_ cls: NSObject.Type, _ initializer: String, _ argument: AnyObject) -> NSObject? {
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? NSObject else { return nil }
        return allocated.perform(NSSelectorFromString(initializer), with: argument)?
            .takeRetainedValue() as? NSObject
    }

    private static var protocolsAdded = false
    private static func addProtocols() {
        guard !protocolsAdded else { return }
        protocolsAdded = true
        for name in ["NSDraggingSource", "NSFilePromiseProviderDelegate"] {
            if let proto = objc_getProtocol(name) {
                class_addProtocol(CatalystFilePromiseDrag.self, proto)
            }
        }
    }

    private func finishIfDone() {
        guard ended, pendingWrites <= 0 else { return }
        Self.active.removeAll { $0 === self }
    }

    // MARK: NSDraggingSource

    @objc(draggingSession:sourceOperationMaskForDraggingContext:)
    func sourceOperationMask(_ session: NSObject, context: Int) -> UInt {
        Self.dragOperationCopy
    }

    @objc(draggingSession:endedAtPoint:operation:)
    func draggingEnded(_ session: NSObject, at point: CGPoint, operation: UInt) {
        ended = true
        if operation == 0 { pendingWrites = 0 }
        finishIfDone()
    }

    // MARK: NSFilePromiseProviderDelegate

    @objc(filePromiseProvider:fileNameForType:)
    func fileName(_ provider: NSObject, forType type: String) -> String {
        guard let index = provider.value(forKey: "userInfo") as? Int,
              items.indices.contains(index) else { return "File" }
        return items[index].name
    }

    @objc(filePromiseProvider:writePromiseToURL:completionHandler:)
    func writePromise(_ provider: NSObject, to url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let index = provider.value(forKey: "userInfo") as? Int,
              items.indices.contains(index) else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        items[index].write(url) { [self] error in
            completionHandler(error)
            pendingWrites -= 1
            finishIfDone()
        }
    }

    @objc(operationQueueForFilePromiseProvider:)
    func operationQueue(_ provider: NSObject) -> OperationQueue {
        .main
    }
}
#endif
