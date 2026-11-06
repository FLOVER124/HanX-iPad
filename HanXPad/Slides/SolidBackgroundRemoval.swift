import UIKit
import ImageIO

/// Removes only color-matched regions connected to an image edge. It does not
/// infer people/objects, so enclosed details of the same color are preserved.
enum SolidBackgroundRemoval {
    static let maximumPixels = 16_000_000
    enum Failure: LocalizedError {
        case invalidImage, tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "이 그림을 처리할 수 없습니다. PNG 또는 JPEG 그림을 선택해 주세요."
            case .tooLarge: return "1,600만 화소 이하의 그림을 사용해 주세요."
            case .encoding: return "투명 PNG 그림을 만들 수 없습니다."
            }
        }
    }
    struct Bitmap {
        var rgba: [UInt8]
        let width: Int
        let height: Int
        func cgImage() throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw Failure.encoding }
            return image
        }
        func png() throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure.encoding }
            CGImageDestinationAddImage(destination, try cgImage(), nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
            return data as Data
        }
        func removing(color: (UInt8, UInt8, UInt8), tolerance: Double) throws -> Bitmap {
            Bitmap(rgba: try SolidBackgroundRemoval.remove(rgba: rgba, width: width, height: height, color: color, tolerance: tolerance), width: width, height: height)
        }
        var backgroundColor: (UInt8, UInt8, UInt8) {
            // A quantized border histogram is less sensitive than one corner to
            // an object touching the image edge. Ignore transparent border pixels.
            var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
            func sample(_ index: Int) {
                let p = index * 4
                guard rgba[p + 3] > 127 else { return }
                let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                let key = (r / 16) << 8 | (g / 16) << 4 | b / 16
                let old = buckets[key] ?? (0,0,0,0)
                buckets[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
            }
            for x in 0..<width { sample(x); if height > 1 { sample((height - 1) * width + x) } }
            if height > 2 { for y in 1..<(height - 1) { sample(y * width); if width > 1 { sample(y * width + width - 1) } } }
            guard let best = buckets.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }).first?.value else { return (255,255,255) }
            return (UInt8(best.red / best.count), UInt8(best.green / best.count), UInt8(best.blue / best.count))
        }
    }
    static func decode(_ data: Data, maximumDimension: Int? = nil) throws -> Bitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.invalidImage }
        if maximumDimension == nil, width > maximumPixels / height { throw Failure.tooLarge }
        let limit = maximumDimension ?? max(width, height)
        guard limit > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ] as CFDictionary) else { throw Failure.invalidImage }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= maximumPixels / h else { throw Failure.tooLarge }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Failure.invalidImage }
        // Work in straight alpha so semitransparent background colors match too.
        for p in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[p + 3])
            if alpha > 0 && alpha < 255 { for c in 0..<3 { rgba[p + c] = UInt8(min(255, (Int(rgba[p + c]) * 255 + alpha / 2) / alpha)) } }
        }
        return Bitmap(rgba: rgba, width: w, height: h)
    }
    static func remove(rgba: [UInt8], width: Int, height: Int, color: (UInt8, UInt8, UInt8), tolerance: Double) throws -> [UInt8] {
        guard width > 0, height > 0, width <= maximumPixels / height,
              rgba.count == width * height * 4, tolerance.isFinite, tolerance >= 0, tolerance <= 255 else { throw Failure.invalidImage }
        var output = rgba
        var visited = [UInt8](repeating: 0, count: width * height)
        var queue: [Int] = []
        let threshold = tolerance * tolerance * 3
        func enqueue(_ index: Int) {
            guard visited[index] == 0 else { return }
            visited[index] = 1
            let p = index * 4
            let dr = Double(rgba[p]) - Double(color.0), dg = Double(rgba[p + 1]) - Double(color.1), db = Double(rgba[p + 2]) - Double(color.2)
            if rgba[p + 3] == 0 || dr * dr + dg * dg + db * db <= threshold { queue.append(index) }
        }
        for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
        for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
        // Depth-first flood uses a bounded stack and never visits a pixel twice.
        while let index = queue.popLast() {
            let p = index * 4
            output[p] = 0; output[p + 1] = 0; output[p + 2] = 0; output[p + 3] = 0
            let x = index % width, y = index / width
            if x > 0 { enqueue(index - 1) }; if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }; if y + 1 < height { enqueue(index + width) }
        }
        return output
    }
}
