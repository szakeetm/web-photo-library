import Foundation
import CoreGraphics
import Metal

public enum EditRenderError: Error, CustomStringConvertible {
    case noGPU, shader(String), tooLarge(Int, Int), failed(String)
    public var description: String {
        switch self {
        case .noGPU: "No Metal GPU available for rendering edits."
        case .shader(let m): "Edit shaders failed to compile: \(m)"
        case .tooLarge(let w, let h): "Image too large to render (\(w)×\(h))."
        case .failed(let m): "Rendering the edit failed: \(m)"
        }
    }
}

/// Runs the shared edit pipeline (shaders/edit.wgsl, translated to MSL) on the Mac's GPU.
/// Input and output pixels are Display-P3-encoded RGBA8, exactly as in the browser.
public final class EditRenderer: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let luma: MTLRenderPipelineState
    let blur: MTLRenderPipelineState
    let develop: MTLRenderPipelineState
    let sampler: MTLSamplerState
    /// The GPU is shared; renders are serialised (each is a few milliseconds of GPU time).
    private let lock = NSLock()

    nonisolated(unsafe) private static var cached: Result<EditRenderer, Error>?
    private static let cacheLock = NSLock()

    /// One renderer per process (compiling the shaders takes ~100 ms).
    public static func shared() throws -> EditRenderer {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return try cached.get() }
        let r = Result { try EditRenderer() }
        cached = r
        return try r.get()
    }

    public static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw EditRenderError.noGPU }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: editShaderMSL, options: nil) } catch {
            throw EditRenderError.shader(String(describing: error))
        }
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vs_main")
            d.fragmentFunction = library.makeFunction(name: fragment)
            guard d.vertexFunction != nil, d.fragmentFunction != nil else { throw EditRenderError.shader("missing \(fragment)") }
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        luma = try pipeline("fs_luma", .rgba16Float)
        blur = try pipeline("fs_blur", .rgba16Float)
        develop = try pipeline("fs_develop", .rgba8Unorm)
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sd) else { throw EditRenderError.noGPU }
        sampler = s
    }

    /// Display-P3 RGBA8 pixels of `image` (orientation already applied by the caller).
    public static func rgba(of image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw EditRenderError.failed("bitmap context")
            }
            ctx.interpolationQuality = .none
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    public static func image(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: displayP3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EditRenderError.failed("image")
        }
        return img
    }

    public func render(_ image: CGImage, recipe: EditRecipe) throws -> CGImage {
        let out = try render(rgba: try Self.rgba(of: image), width: image.width, height: image.height, recipe: recipe)
        return try Self.image(rgba: out.pixels, width: out.width, height: out.height)
    }

    /// Renders `recipe` over a Display-P3 RGBA8 image; returns the output pixels.
    public func render(rgba: [UInt8], width: Int, height: Int, recipe: EditRecipe) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let maxSide = 16384
        let (ow, oh) = recipe.outputSize(sourceWidth: width, sourceHeight: height)
        guard width <= maxSide, height <= maxSide, ow <= maxSide, oh <= maxSide else { throw EditRenderError.tooLarge(max(width, ow), max(height, oh)) }
        let (lw, lh) = EditRecipe.lumaSize(sourceWidth: width, sourceHeight: height)

        lock.lock(); defer { lock.unlock() }
        func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat, target: Bool) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = target ? [.renderTarget, .shaderRead] : [.shaderRead]
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { throw EditRenderError.failed("texture \(w)×\(h)") }
            return t
        }
        let src = try texture(width, height, .rgba8Unorm, target: false)
        rgba.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let lumaA = try texture(lw, lh, .rgba16Float, target: true)
        let lumaB = try texture(lw, lh, .rgba16Float, target: true)
        let output = try texture(ow, oh, .rgba8Unorm, target: true)

        guard let cmd = queue.makeCommandBuffer() else { throw EditRenderError.failed("command buffer") }
        func pass(_ pipeline: MTLRenderPipelineState, target: MTLTexture, blur: (Float, Float) = (0, 0), textures: [(Int, MTLTexture)]) throws {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target
            rp.colorAttachments[0].loadAction = .dontCare
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { throw EditRenderError.failed("encoder") }
            enc.setRenderPipelineState(pipeline)
            var params = recipe.shaderParams(outW: ow, outH: oh, srcW: width, srcH: height, blur: blur)
            enc.setFragmentBytes(&params, length: params.count * 4, index: 0)
            for (i, t) in textures { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        try pass(luma, target: lumaA, textures: [(0, src)])
        try pass(blur, target: lumaB, blur: (1, 0), textures: [(1, lumaA)])
        try pass(blur, target: lumaA, blur: (0, 1), textures: [(1, lumaB)])
        try pass(develop, target: output, textures: [(0, src), (1, lumaA)])
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error { throw EditRenderError.failed(String(describing: e)) }

        var pixels = [UInt8](repeating: 0, count: ow * oh * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: ow * 4, from: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0) }
        return (pixels, ow, oh)
    }
}
