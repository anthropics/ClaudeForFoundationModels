// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import ClaudeAPI
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(CoreImage)
import CoreImage
#endif

/// An image normalized for a Claude image content block.
///
/// The Messages API resizes images that exceed its limits before billing, which
/// costs latency the caller never sees. ``ClaudeImage`` does that resize up
/// front: it decodes source bytes in any format `ImageIO` reads, scales them to
/// fit ``maxLongEdge`` and ``maxPixelCount``, and re-encodes to a media type the
/// API accepts. The result is wire-ready.
///
/// Source metadata (EXIF, GPS, IPTC, XMP — location, capture time, device
/// identifiers) never reaches the wire: every path strips it, keeping only the
/// orientation so a portrait capture still displays upright.
struct ClaudeImage: Sendable, Hashable {
  /// JPEG, PNG, GIF, or WebP bytes within ``maxByteCount`` and the dimension
  /// caps. Base64-encoded onto the wire.
  let data: Data
  /// One of ``supportedMediaTypes``.
  let mediaType: String

  /// Longest edge, in pixels, the API keeps without resizing.
  static let maxLongEdge = 1568
  /// Total pixel budget the API keeps without resizing. A 1568×1568 image is
  /// ~2.46 MP, so for square-ish images this is the tighter bound.
  static let maxPixelCount = 1_150_000
  /// Per-image byte ceiling the API enforces.
  static let maxByteCount = 5 * 1024 * 1024
  /// Media types the API accepts for image content.
  static let supportedMediaTypes: Set<String> = [
    "image/jpeg", "image/png", "image/gif", "image/webp",
  ]

  enum Error: LocalizedError, Sendable {
    /// The bytes weren't a decodable image.
    case undecodable
    /// `ImageIO` could not write the re-encoded image.
    case encodingFailed
    /// Still over ``maxByteCount`` after re-encoding at the lowest quality.
    case tooLarge(byteCount: Int)

    var errorDescription: String? {
      switch self {
      case .undecodable:
        "The data could not be decoded as an image."
      case .encodingFailed:
        "The image could not be re-encoded for upload."
      case .tooLarge(let byteCount):
        "The image is \(byteCount) bytes after compression, over the "
          + "\(ClaudeImage.maxByteCount)-byte limit."
      }
    }
  }

  /// Decodes `data` in any format `ImageIO` reads, scales it to fit the
  /// dimension caps, and produces wire-ready bytes.
  ///
  /// Bytes already in a supported media type and within every limit keep their
  /// format and encoded pixels — no recompression; only the metadata is
  /// rewritten. Anything else (an oversized photo, a HEIC capture, a container
  /// ImageIO can't rewrite losslessly) is downscaled if needed and re-encoded
  /// as JPEG, which strips metadata by construction.
  init(source data: Data) throws {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw Error.undecodable
    }
    let properties =
      CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
    guard
      let width = properties?[kCGImagePropertyPixelWidth] as? Int,
      let height = properties?[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else {
      throw Error.undecodable
    }

    let sourceMediaType =
      CGImageSourceGetType(imageSource)
      .flatMap { UTType($0 as String)?.preferredMIMEType }

    let fitsDimensions =
      max(width, height) <= Self.maxLongEdge && width * height <= Self.maxPixelCount
    if fitsDimensions,
      let mediaType = sourceMediaType,
      Self.supportedMediaTypes.contains(mediaType),
      data.count <= Self.maxByteCount,
      let stripped = Self.strippedCopy(of: imageSource, properties: properties),
      stripped.count <= Self.maxByteCount
    {
      self.data = stripped
      self.mediaType = mediaType
      return
    }

    let cgImage = try Self.downscale(imageSource, width: width, height: height)
    self.data = try Self.encodeJPEG(cgImage)
    self.mediaType = "image/jpeg"
  }

  /// Encodes an already-decoded image (e.g. from a Foundation Models
  /// `Transcript.ImageAttachment`) to wire-ready JPEG: bakes in `orientation`,
  /// downscales to the dimension caps, re-encodes. Decoded pixels carry no
  /// source metadata, so there's nothing to strip.
  init(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws {
    let upright = Self.baked(cgImage, orientation: orientation)
    let target = Self.targetLongEdge(width: upright.width, height: upright.height)
    let fitted =
      target < max(upright.width, upright.height)
      ? try Self.downscale(upright, toLongEdge: target)
      : upright
    self.data = try Self.encodeJPEG(fitted)
    self.mediaType = "image/jpeg"
  }

  #if canImport(CoreImage)
  /// CIContext setup is expensive; one instance serves every image.
  private static let orientationContext = CIContext()
  #endif

  /// Rotates/flips the pixels so the image displays upright without an
  /// orientation tag — JPEG re-encoding below writes none. watchOS has no
  /// CoreImage; pixels pass through as captured there, which is upright for
  /// everything but rotated captures.
  private static func baked(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation
  ) -> CGImage {
    guard orientation != .up else { return image }
    #if canImport(CoreImage)
    let oriented = CIImage(cgImage: image).oriented(orientation)
    return Self.orientationContext.createCGImage(oriented, from: oriented.extent) ?? image
    #else
    return image
    #endif
  }

  private static func downscale(_ image: CGImage, toLongEdge target: Int) throws -> CGImage {
    let scale = Double(target) / Double(max(image.width, image.height))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw Error.encodingFailed
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let resized = context.makeImage() else { throw Error.encodingFailed }
    return resized
  }

  /// Losslessly re-containers the source with its metadata replaced by an
  /// orientation-only set: the encoded pixels are copied as-is, while EXIF,
  /// GPS, IPTC, and XMP are dropped. Returns `nil` when the container can't be
  /// rewritten losslessly (e.g. GIF) — the caller falls back to the
  /// decode-and-re-encode path, which strips metadata anyway.
  private static func strippedCopy(
    of source: CGImageSource,
    properties: [CFString: Any]?
  ) -> Data? {
    guard let type = CGImageSourceGetType(source) else { return nil }
    let metadata = CGImageMetadataCreateMutable()
    if let orientation = properties?[kCGImagePropertyOrientation] as? UInt32, orientation != 1 {
      guard
        CGImageMetadataSetValueMatchingImageProperty(
          metadata,
          kCGImagePropertyTIFFDictionary,
          kCGImagePropertyTIFFOrientation,
          orientation as CFNumber
        )
      else { return nil }
    }
    let out = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(out as CFMutableData, type, 1, nil),
      CGImageDestinationCopyImageSource(
        destination,
        source,
        [kCGImageDestinationMetadata: metadata] as CFDictionary,
        nil
      )
    else {
      return nil
    }
    return out as Data
  }

  // MARK: - Pixel work

  /// Long-edge target, in pixels, that satisfies both ``maxLongEdge`` and
  /// ``maxPixelCount`` while preserving the aspect ratio. Never upscales.
  static func targetLongEdge(width: Int, height: Int) -> Int {
    let longEdge = max(width, height)
    let area = Double(width) * Double(height)
    let longEdgeScale = min(1, Double(Self.maxLongEdge) / Double(longEdge))
    let areaScale =
      area > Double(Self.maxPixelCount)
      ? (Double(Self.maxPixelCount) / area).squareRoot()
      : 1
    return max(1, Int((Double(longEdge) * min(longEdgeScale, areaScale)).rounded()))
  }

  private static func downscale(
    _ source: CGImageSource,
    width: Int,
    height: Int
  ) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: targetLongEdge(width: width, height: height),
      // Bake in EXIF orientation so a portrait capture isn't sent sideways.
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw Error.undecodable
    }
    return image
  }

  /// Steps quality down until the JPEG fits ``maxByteCount``. A ≤1.15 MP frame
  /// is well under the ceiling at the top quality; the lower steps guard
  /// pathological inputs.
  private static func encodeJPEG(_ image: CGImage) throws -> Data {
    var smallest: Data?
    for quality in [0.85, 0.6, 0.4, 0.25] {
      guard let encoded = encode(image, quality: quality) else {
        throw Error.encodingFailed
      }
      if encoded.count <= maxByteCount {
        return encoded
      }
      smallest = encoded
    }
    throw Error.tooLarge(byteCount: smallest?.count ?? .max)
  }

  private static func encode(_ image: CGImage, quality: Double) -> Data? {
    let out = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        out as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
  }
}

extension ClaudeImage {
  /// Wire content block. The bridge emits this once `Transcript.Segment` carries
  /// an image case — see ``RequestBuilder``.
  var contentBlock: ContentBlock {
    .image(ImageSource(mediaType: mediaType, data: data))
  }
}
