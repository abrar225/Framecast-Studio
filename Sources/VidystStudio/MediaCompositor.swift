import Foundation
import AppKit
import CoreImage
import CoreVideo

// Composition, layer drawing, QR generation, and encoder pixel-buffer preparation.
// Extracted from MediaEngine: same module and MainActor isolation as the engine core.
extension MediaEngine {
    func compose(width: Int, height: Int) -> CGImage? {
        compose(configuration: config, width: width, height: height)
    }

    func compose(configuration config: RenderConfiguration, width: Int, height: Int) -> CGImage? {
        guard width > 0, width <= 3840, height > 0, height <= 3840, width * height <= 3840 * 2160,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: VideoColor.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawComposition(configuration: config, in: context, width: width, height: height)
        return context.makeImage()
    }

    /// One drawing interpretation serves preview images and native encoder buffers.
    func drawComposition(configuration config: RenderConfiguration, in context: CGContext, width: Int, height: Int) {
        context.setFillColor(color(config.backgroundHex).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for layer in config.layers where layer.visible && layer.opacity > 0 {
            guard [layer.x, layer.y, layer.width, layer.height, layer.opacity, layer.cornerRadius, layer.rotation, layer.cropLeft, layer.cropTop, layer.cropRight, layer.cropBottom, layer.brightness, layer.contrast, layer.saturation].allSatisfy(\.isFinite), layer.width > 0, layer.height > 0 else { continue }
            let bounds = CGRect(x: layer.x * Double(width), y: (1 - layer.y - layer.height) * Double(height), width: layer.width * Double(width), height: layer.height * Double(height))
            context.saveGState(); context.setAlpha(CGFloat(min(1, max(0, layer.opacity))))
            if layer.rotation != 0 {
                context.translateBy(x: bounds.midX, y: bounds.midY)
                context.rotate(by: -CGFloat(layer.rotation.truncatingRemainder(dividingBy: 360)) * .pi / 180)
                context.translateBy(x: -bounds.midX, y: -bounds.midY)
            }
            let radius = min(Double(min(bounds.width, bounds.height)) / 2, max(0, layer.cornerRadius) * Double(width) / Double(config.width))
            let mask=layer.shape=="circle" ? CGPath(ellipseIn:bounds,transform:nil):CGPath(roundedRect:bounds,cornerWidth:radius,cornerHeight:radius,transform:nil)
            context.addPath(mask);context.clip()
            var source: CGImage?
            switch layer.kind {
            case "camera": source = cameraFrame
            case "screen": source = screenFrame
            case "image": source = imageCache[layer.path]
            case "qr": source = qrImages[layer.text]
            case "color": context.setFillColor(color(layer.text.isEmpty ? "7658F2" : layer.text).cgColor); context.fill(bounds)
            case "text":
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(12, min(96, bounds.height * 0.42)), weight: .semibold), .foregroundColor: NSColor.white]
                (layer.text as NSString).draw(in: bounds.insetBy(dx: 8, dy: 4), withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            default: break
            }
            if let original = source, let source = processedImage(original, layer: layer) {
                let horizontal = bounds.width / CGFloat(source.width)
                let vertical = bounds.height / CGFloat(source.height)
                let scale = (layer.kind == "qr" || layer.fit.lowercased() == "fit") ? min(horizontal, vertical) : max(horizontal, vertical)
                let imageWidth = layer.fit.lowercased() == "stretch" ? bounds.width : CGFloat(source.width) * scale
                let imageHeight = layer.fit.lowercased() == "stretch" ? bounds.height : CGFloat(source.height) * scale
                var rect = CGRect(x: bounds.midX - imageWidth / 2, y: bounds.midY - imageHeight / 2, width: imageWidth, height: imageHeight)
                if layer.mirrored {
                    context.translateBy(x: bounds.midX * 2, y: 0); context.scaleBy(x: -1, y: 1)
                    rect.origin.x = bounds.midX - rect.width / 2
                }
                context.interpolationQuality = layer.kind == "qr" ? .none : .high; context.draw(source, in: rect)
            }
            context.restoreGState()
        }
    }

    func makeQRCode(_ text: String) -> CGImage? {
        // ISO QR version 40, error correction M has at most 2,331 byte-mode data bytes.
        guard !text.isEmpty, let data = text.data(using: .utf8), data.count <= 2331,
              let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": data, "inputCorrectionLevel": "M"]),
              let code = filter.outputImage else { return nil }
        let padded = code.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: padded)
        return filterContext.createCGImage(code.composited(over: white), from: padded)
    }

    /// CGImage crop rectangles have a top-left pixel origin; canvas geometry remains bottom-left internally.
    func processedImage(_ original: CGImage, layer: RenderLayer) -> CGImage? {
        let onePixelX = 1 / Double(original.width), onePixelY = 1 / Double(original.height)
        let left = min(1 - onePixelX, max(0, layer.cropLeft)), top = min(1 - onePixelY, max(0, layer.cropTop))
        let right = min(1 - left - onePixelX, max(0, layer.cropRight)), bottom = min(1 - top - onePixelY, max(0, layer.cropBottom))
        let brightness = min(1, max(-1, layer.brightness))
        let contrast = min(4, max(0, layer.contrast)), saturation = min(4, max(0, layer.saturation))
        let options = [left, top, right, bottom, brightness, contrast, saturation]
        if let cached = processedImages[layer.id], cached.original === original, cached.options == options { return cached.image }
        var result = original
        if left != 0 || top != 0 || right != 0 || bottom != 0 {
            let crop = CGRect(x: left * Double(original.width), y: top * Double(original.height), width: (1 - left - right) * Double(original.width), height: (1 - top - bottom) * Double(original.height)).integral
            guard let cropped = original.cropping(to: crop) else { return nil }
            result = cropped
        }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let input = CIImage(cgImage: result)
            let filtered = input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
            guard let rendered = filterContext.createCGImage(filtered, from: input.extent) else { return nil }
            result = rendered
        }
        // Each entry retains source identity and transformed pixels, so stale identities cannot alias.
        if processedImages.count >= 32, processedImages[layer.id] == nil { processedImages.removeAll(keepingCapacity: true) }
        processedImages[layer.id] = ProcessedImage(original: original, options: options, image: result)
        return result
    }

    func color(_ hex: String) -> NSColor {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return .black }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    func compositionBuffer(configuration: RenderConfiguration, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        makePixelBuffer(width: width, height: height, pool: pool) { context in
            drawComposition(configuration: configuration, in: context, width: width, height: height)
        }
    }

    func pixelBuffer(image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        makePixelBuffer(width: width, height: height, pool: pool) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The pixel buffer owns its storage through encoder submission; no intermediate full-frame image.
    func makePixelBuffer(width: Int, height: Int, pool: CVPixelBufferPool?, draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let status: CVReturn
        if let pool { status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) }
        else { status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &output) }
        guard status == kCVReturnSuccess, let output else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let address = CVPixelBufferGetBaseAddress(output), let context = CGContext(data: address, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output), space: VideoColor.space, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, VideoColor.space, .shouldPropagate)
        draw(context)
        return output
    }
}
