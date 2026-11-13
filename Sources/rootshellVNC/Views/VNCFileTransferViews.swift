#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

/// Shown while a drag moves on the Mac; releasing over it downloads what
/// the Mac was dragging.
struct VNCDragOutTargetView: View {
    let names: [String]
    let isTargeted: Bool

    static let size = CGSize(width: 260, height: 56)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(isTargeted
                     ? String(localized: "Release to Download", bundle: .module)
                     : String(localized: "Drag Here to Download", bundle: .module))
                    .font(.headline)
                Text(VNCFileTransferController.displayName(names))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.8)
            }
        }
            .foregroundStyle(isTargeted ? Color.white : Color.primary)
            .padding(.horizontal, 18)
            .frame(width: Self.size.width, height: Self.size.height)
            .background {
                Capsule()
                    .fill(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [6, 4]))
            }
            .shadow(radius: 8)
            .scaleEffect(isTargeted ? 1.06 : 1)
            .animation(.snappy(duration: 0.15), value: isTargeted)
            .accessibilityElement(children: .combine)
    }
}

/// Uploads and downloads with progress, cancel, and Save to Files.
struct VNCFileTransfersPanel: View {
    @Bindable var controller: VNCFileTransferController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "File Transfers", bundle: .module))
                    .font(.headline)
                Spacer()
                if controller.transfers.contains(where: { !$0.isActive }) {
                    Button(String(localized: "Clear", bundle: .module)) {
                        controller.clearFinished()
                    }
                    .font(.subheadline)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Hide File Transfers", bundle: .module))
            }
            if controller.transfers.isEmpty {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(controller.transfers.reversed()) { transfer in
                            VNCFileTransferRow(transfer: transfer, controller: controller)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 10)
    }

    private var hint: String {
        switch (controller.canUpload, controller.canDownload) {
        case (true, true):
            #if targetEnvironment(macCatalyst)
            return String(
                localized: "Drop files on the screen to copy them to the Mac. Drag files on the Mac out of the window to download them.",
                bundle: .module)
            #else
            return String(
                localized: "Drop files on the screen to copy them to the Mac. Drag files on the Mac to the top of the screen to download them.",
                bundle: .module)
            #endif
        case (true, false):
            return String(localized: "Drop files on the screen to copy them to the Mac.", bundle: .module)
        case (false, true):
            #if targetEnvironment(macCatalyst)
            return String(
                localized: "Drag files on the Mac out of the window to download them.",
                bundle: .module)
            #else
            return String(
                localized: "Drag files on the Mac to the top of the screen to download them.",
                bundle: .module)
            #endif
        case (false, false):
            return String(localized: "This computer doesn't support file transfer.", bundle: .module)
        }
    }
}

private struct VNCFileTransferRow: View {
    let transfer: VNCFileTransfer
    let controller: VNCFileTransferController
    @State private var isSaving = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .transferring || transfer.state == .preparing {
                    if let fraction = transfer.fractionCompleted, transfer.state == .transferring {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .modifier(DownloadDragModifier(urls: savableURLs))
        .fileMover(isPresented: $isSaving, files: savableURLs) { result in
            if case .success = result {
                controller.downloadWasSaved(transfer.id)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if transfer.isActive {
            Button {
                controller.cancel(transfer.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Cancel Transfer", bundle: .module))
        } else {
            HStack(spacing: 12) {
                if !savableURLs.isEmpty {
                    Button {
                        isSaving = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Save to Files", bundle: .module))
                    ShareLink(items: savableURLs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    controller.remove(transfer.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove", bundle: .module))
            }
        }
    }

    private var savableURLs: [URL] {
        transfer.direction == .download ? transfer.localURLs : []
    }

    private var icon: String {
        switch transfer.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        default:
            return transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .completed: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var statusIsError: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var status: String {
        let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
        let done = ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)
        switch transfer.state {
        case .dragging:
            return String(localized: "Drop on a folder or the desktop", bundle: .module)
        case .preparing:
            return transfer.direction == .upload
                ? String(localized: "Preparing…", bundle: .module)
                : String(localized: "Waiting for the Mac…", bundle: .module)
        case .transferring:
            if transfer.totalBytes > 0, transfer.completedBytes >= transfer.totalBytes {
                return String(localized: "Finishing…", bundle: .module)
            }
            return transfer.totalBytes > 0
                ? String(localized: "\(done) of \(total)", bundle: .module)
                : done
        case .completed:
            if transfer.direction == .upload {
                let folder = transfer.remoteFolder.map { ($0 as NSString).lastPathComponent } ?? ""
                return folder.isEmpty
                    ? String(localized: "Copied to the Mac", bundle: .module)
                    : String(localized: "Copied to \(folder)", bundle: .module)
            }
            return String(localized: "Downloaded · \(total)", bundle: .module)
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Cancelled", bundle: .module)
        }
    }
}

/// Lets a finished single-file download be dragged into another app.
private struct DownloadDragModifier: ViewModifier {
    let urls: [URL]

    func body(content: Content) -> some View {
        if urls.count == 1, let url = urls.first {
            content.onDrag {
                NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
        } else {
            content
        }
    }
}
#endif
