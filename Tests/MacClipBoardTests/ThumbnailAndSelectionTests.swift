import AppKit
import Foundation
import ImageIO
import Testing
@testable import MacClipBoardCore
@testable import MacClipBoardSystem

@Suite struct ListSelectionTests {
    let ids = (0..<4).map { _ in UUID() }

    @Test func firstItemIsChosenWhenNothingIsSelectedWhicheverKeyWasPressed() {
        #expect(ListSelection.moved(from: nil, in: ids, by: 1) == ids[0])
        #expect(ListSelection.moved(from: nil, in: ids, by: -1) == ids[0])
        #expect(ListSelection.moved(from: UUID(), in: ids, by: 1) == ids[0]) // stale selection
    }

    @Test func movesOneStepAndStopsAtTheEnds() {
        #expect(ListSelection.moved(from: ids[1], in: ids, by: 1) == ids[2])
        #expect(ListSelection.moved(from: ids[1], in: ids, by: -1) == ids[0])
        #expect(ListSelection.moved(from: ids[0], in: ids, by: -1) == ids[0])
        #expect(ListSelection.moved(from: ids[3], in: ids, by: 1) == ids[3])
    }

    @Test func emptyListHasNoSelection() {
        #expect(ListSelection.moved(from: nil, in: [], by: 1) == nil)
        #expect(ListSelection.moved(from: ids[0], in: [], by: -1) == nil)
    }

    @Test func removalSelectsTheNextThenPreviousNeighbour() {
        #expect(ListSelection.neighbour(afterRemoving: ids[1], in: ids) == ids[2])
        #expect(ListSelection.neighbour(afterRemoving: ids[3], in: ids) == ids[2])
        #expect(ListSelection.neighbour(afterRemoving: ids[0], in: [ids[0]]) == nil)
        #expect(ListSelection.neighbour(afterRemoving: UUID(), in: ids) == nil)
    }
}

@Suite struct ThumbnailTests {
    /// Synthetic solid-colour image encoded by ImageIO, so no real user image is involved.
    func encoded(width: Int, height: Int, type: String) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func largeImagesAreDownsampledKeepingAspectRatio() throws {
        let thumb = try #require(Thumbnailer.makeThumbnail(from: encoded(width: 800, height: 400, type: "public.png"), maxPixelSize: 128))
        #expect(max(thumb.width, thumb.height) == 128)
        #expect(thumb.width == 2 * thumb.height)
    }

    @Test func tiffIsSupportedToo() throws {
        let thumb = try #require(Thumbnailer.makeThumbnail(from: encoded(width: 300, height: 300, type: "public.tiff"), maxPixelSize: 64))
        #expect(thumb.width <= 64 && thumb.height <= 64)
    }

    @Test func garbageAndInvalidSizesProduceNothingInsteadOfCrashing() {
        #expect(Thumbnailer.makeThumbnail(from: Data("not an image".utf8), maxPixelSize: 128) == nil)
        #expect(Thumbnailer.makeThumbnail(from: Data(), maxPixelSize: 128) == nil)
        #expect(Thumbnailer.makeThumbnail(from: encoded(width: 10, height: 10, type: "public.png"), maxPixelSize: 0) == nil)
    }

    @Test func imagesDeclaringAnAbsurdSizeAreRefused() {
        // 11 000 × 11 000 = 121 MP of a solid colour compresses to a tiny file but would need ~480 MB to decode.
        let data = encoded(width: 11_000, height: 11_000, type: "public.png")
        #expect(data.count < 8 * 1024 * 1024)
        #expect(Thumbnailer.makeThumbnail(from: data, maxPixelSize: 128) == nil)
    }

    @Test func payloadExposesTheStoredImageBytesWithoutChangingThem() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]), tiff = Data([0x49, 0x49, 0x2A, 0x00])
        let both = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.tiff", data: tiff),
                                             ClipboardRepresentation(type: "public.png", data: png)]])
        #expect(both.imageData == png) // PNG preferred, bytes identical
        let onlyTiff = ClipboardPayload(items: [[ClipboardRepresentation(type: "public.tiff", data: tiff)]])
        #expect(onlyTiff.imageData == tiff)
        #expect(payload("plain text").imageData == nil)
    }
}
