#if targetEnvironment(macCatalyst)
import Foundation

/// Reads the Mac keyboard layout for keys AppKit keeps from UIKit, whose
/// press therefore carries no characters. HIToolbox has no Catalyst headers.
@MainActor
enum CatalystKeyboardLayout {
    private typealias CopyLayout = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias GetProperty = @convention(c) (AnyObject, CFString) -> UnsafeRawPointer?
    private typealias KeyboardType = @convention(c) () -> UInt8
    private typealias LayoutType = @convention(c) (Int16) -> UInt32
    private typealias Translate = @convention(c) (
        UnsafeRawPointer, UInt16, UInt16, UInt32, UInt32, UInt32,
        UnsafeMutablePointer<UInt32>, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<UInt16>
    ) -> Int32

    private struct Symbols {
        let copyLayout: CopyLayout
        let getProperty: GetProperty
        let layoutData: CFString
        let keyboardType: KeyboardType
        let layoutType: LayoutType
        let translate: Translate
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
                  "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_NOW),
              let copyLayout = dlsym(handle, "TISCopyCurrentKeyboardLayoutInputSource"),
              let getProperty = dlsym(handle, "TISGetInputSourceProperty"),
              let layoutData = dlsym(handle, "kTISPropertyUnicodeKeyLayoutData"),
              let keyboardType = dlsym(handle, "LMGetKbdType"),
              let layoutType = dlsym(handle, "KBGetLayoutType"),
              let translate = dlsym(handle, "UCKeyTranslate") else { return nil }
        return Symbols(
            copyLayout: unsafeBitCast(copyLayout, to: CopyLayout.self),
            getProperty: unsafeBitCast(getProperty, to: GetProperty.self),
            layoutData: layoutData.assumingMemoryBound(to: CFString.self).pointee,
            keyboardType: unsafeBitCast(keyboardType, to: KeyboardType.self),
            layoutType: unsafeBitCast(layoutType, to: LayoutType.self),
            translate: unsafeBitCast(translate, to: Translate.self))
    }()

    /// The unmodified character on the key left of 1, HID usage 0x35.
    static var graveKeyCharacter: String? {
        guard let symbols, let source = symbols.copyLayout()?.takeRetainedValue(),
              let property = symbols.getProperty(source, symbols.layoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let keyboardType = symbols.keyboardType()
        // ISO keyboards report this key as virtual key 10 rather than 50.
        let isISO = symbols.layoutType(Int16(keyboardType)) == 0x49534F20
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UInt16](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { layout in
            // Display action, no modifiers, dead keys reported as characters.
            symbols.translate(
                layout.baseAddress!, isISO ? 10 : 50, 3, 0, UInt32(keyboardType), 1,
                &deadKeys, characters.count, &length, &characters)
        }
        guard status == 0, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
#endif
