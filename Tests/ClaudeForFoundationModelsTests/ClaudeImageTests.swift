// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ClaudeForFoundationModels

@Suite struct ClaudeImageTests {
  // MARK: - Resize math

  @Test func `the long-edge target leaves a small image untouched`() {
    #expect(ClaudeImage.targetLongEdge(width: 800, height: 600) == 800)
  }

  @Test func `a wide image is clamped to the long-edge cap`() {
    // 4000×1000 is under the pixel budget but over the long-edge cap.
    #expect(ClaudeImage.targetLongEdge(width: 4000, height: 1000) == ClaudeImage.maxLongEdge)
  }

  @Test func `a square image is clamped by the pixel budget, not the long edge`() {
    // 2000×2000 = 4 MP. Both caps bite; the pixel budget is tighter, so the
    // long edge lands below maxLongEdge.
    let target = ClaudeImage.targetLongEdge(width: 2000, height: 2000)
    #expect(target < ClaudeImage.maxLongEdge)
    #expect(target * target <= ClaudeImage.maxPixelCount)
  }

  // MARK: - Normalization

  @Test func `an oversized photo is downscaled within both caps`() throws {
    let image = try ClaudeImage(source: pngData(width: 4032, height: 3024))
    let (width, height) = try dimensions(of: image.data)
    #expect(max(width, height) <= ClaudeImage.maxLongEdge)
    #expect(width * height <= ClaudeImage.maxPixelCount)
    #expect(image.data.count <= ClaudeImage.maxByteCount)
  }

  @Test func `a downscaled image is re-encoded as jpeg`() throws {
    let image = try ClaudeImage(source: pngData(width: 4032, height: 3024))
    #expect(image.mediaType == "image/jpeg")
    #expect(ClaudeImage.supportedMediaTypes.contains(image.mediaType))
  }

  @Test func `an in-limits png keeps its format and dimensions`() throws {
    let image = try ClaudeImage(source: pngData(width: 640, height: 480))
    #expect(image.mediaType == "image/png")
    let (width, height) = try dimensions(of: image.data)
    #expect(width == 640)
    #expect(height == 480)
  }

  // MARK: - Metadata

  @Test func `an in-limits jpeg loses its camera metadata but keeps its orientation`() throws {
    let original = imageData(
      type: .jpeg,
      width: 640,
      height: 480,
      properties: cameraMetadata(orientation: 6)
    )
    let image = try ClaudeImage(source: original)
    #expect(image.mediaType == "image/jpeg")
    let (width, height) = try dimensions(of: image.data)
    #expect(width == 640)
    #expect(height == 480)

    // The GPS dictionary must vanish outright; EXIF/TIFF may survive as
    // containers for benign keys, so assert on the sensitive entries.
    let properties = try imageProperties(of: image.data)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
    #expect(exif[kCGImagePropertyExifLensModel] == nil)
    #expect(tiff[kCGImagePropertyTIFFMake] == nil)
    #expect(tiff[kCGImagePropertyTIFFModel] == nil)
    // Orientation survives so the capture still displays upright.
    let orientation = try #require(properties[kCGImagePropertyOrientation] as? UInt32)
    #expect(orientation == 6)
  }

  @Test func `the downscale path also drops camera metadata`() throws {
    let original = imageData(
      type: .jpeg,
      width: 4032,
      height: 3024,
      properties: cameraMetadata(orientation: 1)
    )
    let image = try ClaudeImage(source: original)
    let properties = try imageProperties(of: image.data)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    #expect(properties[kCGImagePropertyGPSDictionary] == nil)
    #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
  }

  @Test func `the aspect ratio is preserved through a downscale`() throws {
    let image = try ClaudeImage(source: pngData(width: 4000, height: 1000))
    let (width, height) = try dimensions(of: image.data)
    // 4:1 source, allow a pixel of rounding slop.
    #expect(abs(Double(width) / Double(height) - 4.0) < 0.05)
  }

  @Test func `non-image data throws undecodable`() {
    #expect(throws: ClaudeImage.Error.self) {
      try ClaudeImage(source: Data("not an image".utf8))
    }
  }

  // MARK: - Helpers

  /// A solid-color PNG of the given pixel size.
  private func pngData(width: Int, height: Int) -> Data {
    imageData(type: .png, width: width, height: height)
  }

  /// A solid-color image of the given pixel size and container format, with
  /// optional container metadata (orientation, EXIF, GPS, TIFF).
  private func imageData(
    type: UTType,
    width: Int,
    height: Int,
    properties: [CFString: Any]? = nil
  ) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = context.makeImage()!

    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      out as CFMutableData,
      type.identifier as CFString,
      1,
      nil
    )!
    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary?)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
  }

  /// Location, capture time, and device identifiers as a camera capture
  /// carries them — the data ``ClaudeImage`` must keep off the wire.
  private func cameraMetadata(orientation: UInt32) -> [CFString: Any] {
    [
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 37.7749,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 122.4194,
        kCGImagePropertyGPSLongitudeRef: "W",
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:05:21 12:00:00",
        kCGImagePropertyExifLensModel: "Wide Camera 26mm f/1.6",
      ],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Apple",
        kCGImagePropertyTIFFModel: "iPhone 17 Pro",
      ],
    ]
  }

  private func imageProperties(of data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
  }

  private func dimensions(of data: Data) throws -> (width: Int, height: Int) {
    let properties = try imageProperties(of: data)
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    return (width, height)
  }
}
