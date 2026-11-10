import Testing
import CoreGraphics
@testable import VidystStudio

struct CaptureSizingTests {
    @Test func budgetPreservesAspectEvennessAndNeverUpscales() {
        let retina = CaptureSizing.dimensions(contentSize: CGSize(width: 1512, height: 982), pointPixelScale: 2)
        #expect(retina.width == 3024)
        #expect(retina.height == 1964)

        let capped = CaptureSizing.dimensions(contentSize: CGSize(width: 1512, height: 982), pointPixelScale: 2, maxPixels: 1_000_000)
        #expect(capped.width * capped.height <= 1_000_000)
        #expect(capped.width * capped.height > 900_000)
        #expect(capped.width % 2 == 0)
        #expect(capped.height % 2 == 0)
        let nativeAspect = 3024.0 / 1964.0
        #expect(abs(Double(capped.width) / Double(capped.height) / nativeAspect - 1) < 0.02)

        // A source smaller than the budget is never upscaled, whatever the budget.
        let small = CaptureSizing.dimensions(contentSize: CGSize(width: 640, height: 360), pointPixelScale: 1, maxPixels: 8_294_400)
        #expect(small.width == 640)
        #expect(small.height == 360)

        // An output-derived budget (4x canvas pixels) keeps full detail when it already fits.
        let bounded = CaptureSizing.dimensions(contentSize: CGSize(width: 1920, height: 1080), pointPixelScale: 2, maxPixels: 4 * 1920 * 1080)
        #expect(bounded.width == 3840)
        #expect(bounded.height == 2160)
    }
}
