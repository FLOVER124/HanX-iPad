import UIKit
import Vision
import CoreVideo

/// Masks and brush coordinates use full-resolution, EXIF-normalized, top-left pixel space.
struct ImageBackgroundMask {
    var values: [UInt8]
    let width: Int
    let height: Int

    func applying(to original: SolidBackgroundRemoval.Bitmap) throws -> SolidBackgroundRemoval.Bitmap {
        guard width == original.width, height == original.height, values.count == width * height else {
            throw SolidBackgroundRemoval.Failure.invalidImage
        }
        var result = original
        for i in values.indices {
            result.rgba[i * 4 + 3] = UInt8((Int(original.rgba[i * 4 + 3]) * Int(values[i]) + 127) / 255)
        }
        return result
    }

    /// Display sampling never changes the full-resolution mask used by Apply.
    func preview(of original: SolidBackgroundRemoval.Bitmap, maximumDimension: Int = 900) throws -> SolidBackgroundRemoval.Bitmap {
        guard width == original.width, height == original.height, width > 0, height > 0,
              values.count == width * height, maximumDimension > 0 else { throw SolidBackgroundRemoval.Failure.invalidImage }
        let scale = min(1, Double(maximumDimension) / Double(max(width, height)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(w)))
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(h)))
            let source = sy * width + sx, target = (y * w + x) * 4
            for c in 0..<3 { pixels[target + c] = original.rgba[source * 4 + c] }
            pixels[target + 3] = UInt8((Int(original.rgba[source * 4 + 3]) * Int(values[source]) + 127) / 255)
        } }
        return SolidBackgroundRemoval.Bitmap(rgba: pixels, width: w, height: h)
    }

    /// Separable box feather with clamped edges; the editable mask remains unchanged.
    func feathered(radius: Int) -> ImageBackgroundMask {
        let r = max(0, min(20, radius))
        guard r > 0, width > 0, height > 0, values.count == width * height else { return self }
        let divisor = Double(2 * r + 1)
        var horizontal = [Double](repeating: 0, count: values.count)
        var result = values
        for y in 0..<height {
            let row = y * width
            var sum = 0.0
            for dx in -r...r { sum += Double(values[row + max(0, min(width - 1, dx))]) }
            for x in 0..<width {
                horizontal[row + x] = sum / divisor
                sum += Double(values[row + min(width - 1, x + r + 1)]) - Double(values[row + max(0, x - r)])
            }
        }
        for x in 0..<width {
            var sum = 0.0
            for dy in -r...r { sum += horizontal[max(0, min(height - 1, dy)) * width + x] }
            for y in 0..<height {
                result[y * width + x] = UInt8(max(0, min(255, (sum / divisor).rounded())))
                sum += horizontal[min(height - 1, y + r + 1) * width + x] - horizontal[max(0, y - r) * width + x]
            }
        }
        return ImageBackgroundMask(values: result, width: width, height: height)
    }

    mutating func stroke(from start: CGPoint, to end: CGPoint, radius: Double, keep: Bool, hardness: Double = 1) {
        guard hardness.isFinite, radius.isFinite, radius > 0, start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return }
        let left = max(0, Int(floor(min(start.x, end.x) - radius)))
        let right = min(width - 1, Int(ceil(max(start.x, end.x) + radius)))
        let top = max(0, Int(floor(min(start.y, end.y) - radius)))
        let bottom = min(height - 1, Int(ceil(max(start.y, end.y) + radius)))
        guard left <= right, top <= bottom else { return }
        let dx = end.x - start.x, dy = end.y - start.y, length = dx * dx + dy * dy
        for y in top...bottom { for x in left...right {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let t = length > 0 ? max(0, min(1, ((px - start.x) * dx + (py - start.y) * dy) / length)) : 0
            let distance = hypot(px - (start.x + t * dx), py - (start.y + t * dy))
            if distance <= radius {
                let hard = max(0, min(1, hardness)), inner = radius * hard
                let weight = distance <= inner || hard == 1 ? 1 : max(0, (radius - distance) / (radius - inner))
                let index = y * width + x, old = Double(values[index]), target = keep ? 255.0 : 0.0
                values[index] = UInt8(max(0, min(255, (old + (target - old) * weight).rounded())))
            }
        } }
    }
}

enum SubjectBackgroundRemoval {
    enum Failure: LocalizedError {
        case noSubject, unsupportedMask
        var errorDescription: String? {
            switch self {
            case .noSubject: return "피사체를 찾지 못했습니다. 단색 또는 수동 모드를 사용해 주세요."
            case .unsupportedMask: return "피사체 마스크를 읽을 수 없습니다. 단색 또는 수동 모드를 사용해 주세요."
            }
        }
    }
    static func mask(for original: SolidBackgroundRemoval.Bitmap, request: VNGenerateForegroundInstanceMaskRequest) throws -> ImageBackgroundMask {
        // decode already applies EXIF orientation. Never pass the source orientation again.
        let handler = VNImageRequestHandler(cgImage: try original.cgImage(), orientation: .up, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        guard CVPixelBufferGetWidth(buffer) == original.width, CVPixelBufferGetHeight(buffer) == original.height,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.unsupportedMask }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.unsupportedMask }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: original.width * original.height)
        for y in 0..<original.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<original.width {
                let value = row[x]
                values[y * original.width + x] = value.isFinite ? UInt8((max(0, min(1, value)) * 255).rounded()) : 0
            }
        }
        return ImageBackgroundMask(values: values, width: original.width, height: original.height)
    }
}
