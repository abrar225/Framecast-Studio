import AppKit

/// One explicit SDR color space for composition, buffer conversion and pixel
/// inspection. Read pixels through Core Graphics rather than AppKit's implicit
/// display/HDR conversion when comparing encoded/source values.
enum VideoColor {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static func sample(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, x < image.width, y >= 0, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return NSColor(srgbRed: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255, alpha: CGFloat(data[3]) / 255)
    }
}
