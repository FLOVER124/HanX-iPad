import UIKit

/// Source-aligned crop rectangle, in fractions of the original image.
enum SlideImageCrop {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func composed(_ outer: CGRect, _ inner: CGRect) -> CGRect {
        CGRect(x: outer.minX + outer.width * inner.minX, y: outer.minY + outer.height * inner.minY,
               width: outer.width * inner.width, height: outer.height * inner.height)
    }

    static func frame(for shape: SlideShape, rect: CGRect, restoring: Bool = false) -> Frame {
        let f = shape.frame
        let width = restoring ? f.w / rect.width : f.w
        let height = restoring ? f.h / rect.height : f.h
        let dx = (rect.midX - 0.5) * width * (shape.flipH ? -1 : 1)
        let dy = (rect.midY - 0.5) * height * (shape.flipV ? -1 : 1)
        let (rx, ry) = ShapeGeometry.rotated(dx, dy, shape.rotation)
        let w = restoring ? width : width * rect.width
        let h = restoring ? height : height * rect.height
        let sign = restoring ? -1.0 : 1.0
        return Frame(x: f.x + (f.w - w) / 2 + sign * rx, y: f.y + (f.h - h) / 2 + sign * ry, w: w, h: h)
    }

    static func crop(_ bitmap: SolidBackgroundRemoval.Bitmap, selection: CGRect) throws -> (Data, CGRect) {
        let rect = selection.standardized.intersection(full)
        guard !rect.isNull, !rect.isEmpty else { throw SolidBackgroundRemoval.Failure.invalidImage }
        let width = bitmap.width, height = bitmap.height
        let left = Int(floor(rect.minX * Double(width))), right = min(width, Int(ceil(rect.maxX * Double(width))))
        let top = Int(floor(rect.minY * Double(height))), bottom = min(height, Int(ceil(rect.maxY * Double(height))))
        var pixels = [UInt8]()
        pixels.reserveCapacity((right-left) * (bottom-top) * 4)
        for row in top..<bottom {
            pixels.append(contentsOf: bitmap.rgba[((row*width+left)*4)..<((row*width+right)*4)])
        }
        let cropped = SolidBackgroundRemoval.Bitmap(rgba: pixels, width: right-left, height: bottom-top)
        let exact = CGRect(x: Double(left)/Double(width), y: Double(top)/Double(height),
                           width: Double(right-left)/Double(width), height: Double(bottom-top)/Double(height))
        return (try cropped.png(), exact)
    }
}
