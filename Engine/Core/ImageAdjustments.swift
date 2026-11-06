import Foundation

/// Pixel edits are baked into a fresh PNG so document readers share the result.
/// Keep formulas aligned with desktop/image-tools.js.
enum ImageAdjustments {
    enum Filter: String, CaseIterable { case normal, grayscale, sepia, invert }
    struct Settings {
        var opacity = 100.0
        var brightness = 0.0
        var contrast = 0.0
        var saturation = 100.0
        var skewX = 0.0
        var skewY = 0.0
        var perspectiveX = 0.0
        var perspectiveY = 0.0
        var filter: Filter = .normal
    }
    enum Failure: LocalizedError {
        case invalidInput
        var errorDescription: String? { "그림 크기와 보정 값을 확인해 주세요." }
    }
    static func apply(_ rgba: [UInt8], width: Int, height: Int, settings s: Settings) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 16_000_000 / height, rgba.count == width * height * 4,
              s.opacity.isFinite, (0...100).contains(s.opacity),
              s.brightness.isFinite, (-100...100).contains(s.brightness),
              s.contrast.isFinite, (-100...100).contains(s.contrast),
              s.saturation.isFinite, (0...200).contains(s.saturation),
              s.skewX.isFinite, (-30...30).contains(s.skewX), s.skewY.isFinite, (-30...30).contains(s.skewY),
              (-75...75).contains(s.perspectiveX), (-75...75).contains(s.perspectiveY)
        else { throw Failure.invalidInput }
        var result = [UInt8](repeating: 0, count: rgba.count)
        let tx = tan(s.skewX * .pi / 180), ty = tan(s.skewY * .pi / 180), det = 1 - tx * ty
        let factor = 1 + s.contrast / 100, offset = s.brightness / 100, sat = s.saturation / 100
        let transformed = s.skewX != 0 || s.skewY != 0 || s.perspectiveX != 0 || s.perspectiveY != 0
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        for y in 0..<height { for x in 0..<width {
            var source = (y * width + x) * 4
            let target = source
            if transformed {
                let dx = (Double(x) + 0.5) / Double(width) - 0.5, dy = (Double(y) + 0.5) / Double(height) - 0.5
                let divisor = det * (1 - dx * s.perspectiveX / 100 - dy * s.perspectiveY / 100)
                let sx = Int(floor(((dx - tx * dy) / divisor + 0.5) * Double(width)))
                let sy = Int(floor(((dy - ty * dx) / divisor + 0.5) * Double(height)))
                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                source = (sy * width + sx) * 4
            }
            var r = (Double(rgba[source]) / 255 - 0.5) * factor + 0.5 + offset
            var g = (Double(rgba[source + 1]) / 255 - 0.5) * factor + 0.5 + offset
            var b = (Double(rgba[source + 2]) / 255 - 0.5) * factor + 0.5 + offset
            let gray = r * 0.2126 + g * 0.7152 + b * 0.0722
            r = gray + (r - gray) * sat; g = gray + (g - gray) * sat; b = gray + (b - gray) * sat
            switch s.filter {
            case .normal: break
            case .grayscale:
                let v = r * 0.2126 + g * 0.7152 + b * 0.0722; r = v; g = v; b = v
            case .sepia:
                let nr = r * 0.393 + g * 0.769 + b * 0.189
                let ng = r * 0.349 + g * 0.686 + b * 0.168
                let nb = r * 0.272 + g * 0.534 + b * 0.131
                r = nr; g = ng; b = nb
            case .invert: r = 1 - r; g = 1 - g; b = 1 - b
            }
            result[target] = byte(r); result[target + 1] = byte(g); result[target + 2] = byte(b)
            result[target + 3] = UInt8((Double(rgba[source + 3]) * s.opacity / 100).rounded())
        } }
        return result
    }
}
