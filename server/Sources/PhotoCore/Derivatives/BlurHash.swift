import Foundation
import CoreGraphics

/// BlurHash encoder (https://blurha.sh), reference algorithm.
public enum BlurHash {
    static let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")

    public static func encode(cgImage: CGImage, x cx: Int = 4, y cy: Int = 3) -> String {
        // Render into a small sRGB RGBA buffer.
        let w = min(cgImage.width, 64), h = max(1, Int((Double(cgImage.height) * Double(w) / Double(cgImage.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var factors: [(Double, Double, Double)] = []
        for j in 0..<cy {
            for i in 0..<cx {
                let norm: Double = (i == 0 && j == 0) ? 1 : 2
                var r = 0.0, g = 0.0, b = 0.0
                for y in 0..<h {
                    for x in 0..<w {
                        let basis = norm * cos(Double.pi * Double(i) * Double(x) / Double(w))
                            * cos(Double.pi * Double(j) * Double(y) / Double(h))
                        let o = (y * w + x) * 4
                        r += basis * srgbToLinear(pixels[o])
                        g += basis * srgbToLinear(pixels[o + 1])
                        b += basis * srgbToLinear(pixels[o + 2])
                    }
                }
                let scale = 1.0 / Double(w * h)
                factors.append((r * scale, g * scale, b * scale))
            }
        }

        var out = encode83((cx - 1) + (cy - 1) * 9, length: 1)
        let ac = factors.dropFirst()
        let maximumValue: Double
        if !ac.isEmpty {
            let actualMax = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max()!
            let quantised = Int(max(0, min(82, floor(actualMax * 166 - 0.5))))
            maximumValue = Double(quantised + 1) / 166
            out += encode83(quantised, length: 1)
        } else {
            maximumValue = 1
            out += encode83(0, length: 1)
        }
        let dc = factors[0]
        out += encode83((linearToSrgb(dc.0) << 16) + (linearToSrgb(dc.1) << 8) + linearToSrgb(dc.2), length: 4)
        for f in ac {
            func q(_ v: Double) -> Int { Int(max(0, min(18, floor(signPow(v / maximumValue, 0.5) * 9 + 9.5)))) }
            out += encode83(q(f.0) * 19 * 19 + q(f.1) * 19 + q(f.2), length: 2)
        }
        return out
    }

    static func encode83(_ value: Int, length: Int) -> String {
        var s = ""
        for i in 1...length {
            let digit = (value / Int(pow(83, Double(length - i)))) % 83
            s.append(chars[digit])
        }
        return s
    }

    static func srgbToLinear(_ v: UInt8) -> Double {
        let x = Double(v) / 255
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ v: Double) -> Int {
        let x = max(0, min(1, v))
        return x <= 0.0031308 ? Int(x * 12.92 * 255 + 0.5) : Int((1.055 * pow(x, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    static func signPow(_ v: Double, _ e: Double) -> Double { copysign(pow(abs(v), e), v) }
}
