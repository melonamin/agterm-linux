import CGtk
import Foundation
import agtermCore

private final class ImageSize {
    var width = 0
    var height = 0
}

private let onImageSize: @convention(c)
    (UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, gpointer?) -> Void = { loader, width, height, data in
        guard let loader, let data else { return }
        let size = Unmanaged<ImageSize>.fromOpaque(data).takeUnretainedValue()
        size.width = Int(width)
        size.height = Int(height)
        // Preserve original dimensions for the budget while bounding decoded pixel storage. The page
        // embeds the original bytes; this loader validates format/metadata and never renders a widget.
        gdk_pixbuf_loader_set_size(loader, 1, 1)
    }

struct ImageProbe: Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int
    let mimeType: String

    enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case tooLarge(String)
        case notAnImage(String)
        case tooManyPixels(String)

        var description: String {
            switch self {
            case .unreadable(let path): "unreadable image: \(path)"
            case .tooLarge(let path): "image too large (over \(ImagePage.maxBytes >> 20) MB): \(path)"
            case .notAnImage(let path): "not a png, jpg, gif or webp image: \(path)"
            case .tooManyPixels(let path): "image too large (over \(ImagePage.maxPixels / 1_000_000) megapixels): \(path)"
            }
        }
    }

    static func load(path: String, maxBytes: Int = ImagePage.maxBytes) -> Result<(ImageProbe, Data), Failure> {
        BoundedFile.read(path: path, maxBytes: maxBytes)
            .mapError { $0 == .tooLarge ? .tooLarge(path) : .unreadable(path) }
            .flatMap { data in
                guard let mime = ImagePage.mimeType(sniffing: data), let dimensions = LinuxRasterDimensions.read(data, mime: mime) else {
                    return .failure(.notAnImage(path))
                }
                guard ImagePage.allowsPixels(width: dimensions.width, height: dimensions.height) else {
                    return .failure(.tooManyPixels(path))
                }
                guard let loader = gdk_pixbuf_loader_new() else { return .failure(.notAnImage(path)) }
                defer { g_object_unref(loader) }
                let size = ImageSize()
                let held = Unmanaged.passRetained(size)
                defer { held.release() }
                connect(OpaquePointer(loader), "size-prepared", unsafeBitCast(onImageSize, to: GCallback.self), held.toOpaque())
                var error: UnsafeMutablePointer<GError>?
                defer { if let error { g_error_free(error) } }
                var offset = 0
                var written: gboolean = 1
                // Feed only until the decoder has the dimensions. A full pixel decode would turn a
                // metadata probe into unbounded work across every frame of an animated picture.
                while offset < data.count, size.width == 0, written != 0 {
                    let count = min(mime == "image/gif" ? 1 : 1024, data.count - offset)
                    written = data.withUnsafeBytes { bytes in
                        gdk_pixbuf_loader_write(loader, bytes.bindMemory(to: UInt8.self).baseAddress! + offset,
                                                gsize(count), &error)
                    }
                    offset += count
                }
                var closeError: UnsafeMutablePointer<GError>?
                defer { if let closeError { g_error_free(closeError) } }
                let closed = gdk_pixbuf_loader_close(loader, &closeError)
                guard size.width > 0, size.height > 0 else { return .failure(.notAnImage(path)) }
                guard ImagePage.allowsPixels(width: size.width, height: size.height) else { return .failure(.tooManyPixels(path)) }
                guard written != 0, offset < data.count || closed != 0,
                      let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else {
                    return .failure(.notAnImage(path))
                }
                let orientation = gdk_pixbuf_get_option(pixbuf, "orientation").flatMap { Int(String(cString: $0)) } ?? 1
                return .success((ImageProbe(pixelWidth: size.width, pixelHeight: size.height,
                                            orientation: orientation, mimeType: mime), data))
            }
    }

    func natural(scale: Double) -> (width: Double, height: Double) {
        ImagePage.natural(pixelWidth: pixelWidth, pixelHeight: pixelHeight, orientation: orientation, scale: scale)
    }
}
