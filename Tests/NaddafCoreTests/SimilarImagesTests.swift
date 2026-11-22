import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import NaddafCore

private func writePNG(_ url: URL, size: Int, draw: (CGContext, CGFloat) -> Void) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let ctx = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    draw(ctx, CGFloat(size))
    let image = try #require(ctx.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func stripes(_ ctx: CGContext, _ s: CGFloat) {
    for i in 0..<8 {
        ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(i) * s / 8, width: s, height: s / 8))
    }
}

private func circles(_ ctx: CGContext, _ s: CGFloat) {
    ctx.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    for i in 0..<5 {
        let inset = CGFloat(i) * s / 12
        ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1) : CGColor(red: 0.95, green: 0.9, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
    }
}

@Test func similarIdenticalAndResizedCopyAreGrouped() async throws {
    try await withTempDirAsync { dir in
        try writePNG(dir.appendingPathComponent("a.png"), size: 256, draw: stripes)
        try writePNG(dir.appendingPathComponent("a_small.png"), size: 128, draw: stripes)
        try writePNG(dir.appendingPathComponent("b.png"), size: 256, draw: circles)
        let groups = try await SimilarImagesScanner(roots: [dir]).groups()
        #expect(groups.count == 1)
        #expect(groups.first?.keep.url.lastPathComponent == "a.png")
        #expect(groups.first?.extras.map(\.url.lastPathComponent) == ["a_small.png"])
    }
}

@Test func similarDifferentImagesNotGrouped() async throws {
    try await withTempDirAsync { dir in
        try writePNG(dir.appendingPathComponent("a.png"), size: 256, draw: stripes)
        try writePNG(dir.appendingPathComponent("b.png"), size: 256, draw: circles)
        #expect(try await SimilarImagesScanner(roots: [dir]).groups().isEmpty)
    }
}

@Test func similarNonImageFilesAreIgnored() async throws {
    try await withTempDirAsync { dir in
        try writePNG(dir.appendingPathComponent("a.png"), size: 128, draw: stripes)
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("broken".utf8).write(to: dir.appendingPathComponent("broken.png"))
        #expect(try await SimilarImagesScanner(roots: [dir]).groups().isEmpty)
    }
}
