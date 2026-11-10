import Foundation
import ImageIO
import RFBProtocol
import RFBTransport

/// Gives TIFF-only and BMP-only remote images a PNG so apps that read
/// only common image types can paste them. CPU-bound: run detached.
enum VNCClipboardImageNormalizer {
    static func needsNormalization(_ content: VNCClipboardContent) -> Bool {
        content.items.contains(where: needsPNG)
    }

    static func normalized(_ content: VNCClipboardContent) -> VNCClipboardContent {
        VNCClipboardContent(items: content.items.map { item in
            guard needsPNG(item),
                  let sourceIndex = item.firstIndex(where: {
                      $0.type == ClipboardType.tiff || $0.type == ClipboardType.bmp
                  }),
                  let png = pngData(from: item[sourceIndex].data) else {
                return item
            }
            var result = item
            result.insert(.init(type: ClipboardType.png, data: png), at: sourceIndex)
            result.removeAll { $0.type == ClipboardType.bmp }
            return result
        })
    }

    private static func needsPNG(_ item: VNCClipboardContent.Item) -> Bool {
        let types = Set(item.map(\.type))
        return !types.isDisjoint(with: [ClipboardType.tiff, ClipboardType.bmp])
            && types.isDisjoint(with: ClipboardType.commonImages.union([ClipboardType.heic]))
    }

    static func pngData(
        from data: Data,
        maximumDecodedBytes: Int = ClipboardImageBudget.maximumDecodedBytes
    ) -> Data? {
        guard let image = ClipboardImageBudget.image(
            from: data, maximumBytes: maximumDecodedBytes) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, ClipboardType.png as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
