import Cocoa
import CoreImage

// Pixel tools are deliberately independent of window/controller state. CIImage snapshots
// are immutable, so a brush stroke is a single reversible edit, not a chain of filters.
struct PhotoBrush: Codable {
    var name: String
    var kind: String
    var hardness: Double
    var width: Int = 0
    var height: Int = 0
    var samples: Data? = nil // Coverage, white = ink. Not Photoshop dynamics.
    // Optional fields keep previously saved NetVista tips readable.
    var spacing: Double? = nil
    var angle: Double? = nil
    var roundness: Double? = nil
    var diameter: Double? = nil
    static let defaults: [PhotoBrush] = [
        .init(name: "Hard round", kind: "round", hardness: 1),
        .init(name: "Soft round", kind: "round", hardness: 0),
        .init(name: "Chalk", kind: "texture", hardness: 0.75),
        .init(name: "Calligraphy", kind: "calligraphy", hardness: 0.9)
    ]
    var isValid: Bool {
        guard !name.isEmpty, name.utf8.count <= 4096, hardness.isFinite, (0...1).contains(hardness),
              [spacing,angle,roundness,diameter].compactMap({ $0 }).allSatisfy({ $0.isFinite }),
              (0.01...10).contains(spacing ?? 0.12), (-360...360).contains(angle ?? 0),
              (0.01...1).contains(roundness ?? 1), (1...8192).contains(diameter ?? 40) else { return false }
        if let samples {
            // Validate each dimension before multiplying untrusted imported integers.
            return width > 0 && height > 0 && width <= 8192 && height <= 8192 && width * height <= 32*1024*1024 && samples.count == width * height
        }
        return ["round","texture","calligraphy"].contains(kind)
    }
    func tip(color: NSColor, hardness: Double, maxDimension: Int = 1024) -> CGImage? {
        guard isValid, hardness.isFinite else { return nil }
        let originalW = samples == nil ? 128 : width, originalH = samples == nil ? 128 : height
        let factor = min(1, Double(max(1,min(2048,maxDimension))) / Double(max(originalW,originalH)))
        let w = max(1,Int(Double(originalW)*factor)), h = max(1,Int(Double(originalH)*factor))
        let hardness = min(1,max(0,hardness))
        let c = color.usingColorSpace(.deviceRGB) ?? .black
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            var coverage: Double
            if let samples {
                // Render only the size needed by this stroke/thumbnail, not a 64 MB RGBA
                // copy of a 4K tip for every mouse-down or slider movement.
                let sx = min(originalW-1,Int((Double(x)+0.5)*Double(originalW)/Double(w)))
                let sy = min(originalH-1,Int((Double(y)+0.5)*Double(originalH)/Double(h)))
                coverage = Double(samples[sy*originalW+sx]) / 255
            }
            else {
                let px = (Double(x) + 0.5) / Double(w) * 2 - 1
                let py = (Double(y) + 0.5) / Double(h) * 2 - 1
                let r = kind == "calligraphy" ? hypot((px + py) * 0.707, (py - px) * 2.5) : hypot(px, py)
                coverage = r <= hardness ? 1 : max(0, (1 - r) / max(0.001, 1 - hardness))
                if kind == "texture" { coverage *= Double((x * 73 + y * 151 + x * y * 17) % 101) / 100 }
            }
            let a = min(1, max(0, coverage * c.alphaComponent)), i = (y * w + x) * 4
            rgba[i] = UInt8(min(1,max(0,c.redComponent)) * a * 255); rgba[i+1] = UInt8(min(1,max(0,c.greenComponent)) * a * 255)
            rgba[i+2] = UInt8(min(1,max(0,c.blueComponent)) * a * 255); rgba[i+3] = UInt8(a * 255)
        }}
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum PhotoPixels {
    static let maxPixels = 64_000_000
    static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1 && size.width <= 16000 && size.height <= 16000 && size.width * size.height <= Double(maxPixels)
    }
    static func context(_ size: CGSize) -> CGContext? {
        guard validSize(size) else { return nil }
        return CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    static func png(_ image: CIImage, context: CIContext) throws -> Data {
        guard validSize(image.extent.size), let cg = context.createCGImage(image, from: image.extent), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw PhotoBrushError.invalid("Unable to encode layer pixels.") }
        return data
    }
    static func frozen(_ image: CIImage, context: CIContext) -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent) else { return image }
        return CIImage(cgImage: cg)
    }
    static func maskBounds(_ image: CIImage, context: CIContext) -> CGRect? {
        guard validSize(image.extent.size) else { return nil }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt8](repeating:0,count:w*h)
        context.render(image,toBitmap:&pixels,rowBytes:w,bounds:image.extent,format:.L8,colorSpace:CGColorSpaceCreateDeviceGray())
        var left = w, right = -1, top = h, bottom = -1
        for y in 0..<h { for x in 0..<w where pixels[y*w+x] > 0 { left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y) } }
        guard right >= left else { return nil }
        return CGRect(x:Double(left)+image.extent.minX,y:Double(h-1-bottom)+image.extent.minY,width:Double(right-left+1),height:Double(bottom-top+1))
    }
    static func color(at point: CGPoint, image: CIImage, context: CIContext) -> NSColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let alpha = max(1, Double(pixel[3]))
        return NSColor(deviceRed: min(1,Double(pixel[0])/alpha), green: min(1,Double(pixel[1])/alpha), blue: min(1,Double(pixel[2])/alpha), alpha: 1)
    }
    // Contiguous four-neighbour colour selection. Work is bounded by the document size.
    static func region(at point: CGPoint, image: CIImage, tolerance: Int, context: CIContext) -> CIImage? {
        let size = image.extent.size
        guard validSize(size) else { return nil }
        // Bitmap rows run top-to-bottom, while the native canvas and CI coordinates run upward.
        let w = Int(size.width), h = Int(size.height), x = Int(point.x), y = Int(size.height)-1-Int(point.y)
        guard x >= 0, y >= 0, x < w, y < h else { return nil }
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        context.render(image, toBitmap: &pixels, rowBytes: w*4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var seen = [UInt8](repeating: 0, count: w*h), queue = [y*w+x], head = 0
        let seed = Array(pixels[(y*w+x)*4..<(y*w+x)*4+4])
        seen[y*w+x] = 1
        while head < queue.count {
            let n = queue[head]; head += 1
            let px = n % w, py = n / w
            let neighbours = [px > 0 ? n-1 : -1, px+1 < w ? n+1 : -1, py > 0 ? n-w : -1, py+1 < h ? n+w : -1]
            for next in neighbours where next >= 0 && seen[next] == 0 {
                seen[next] = 2
                if (0..<4).allSatisfy({ abs(Int(pixels[next*4+$0])-Int(seed[$0])) <= tolerance }) { seen[next] = 1; queue.append(next) }
            }
        }
        let mask = Data(seen.map { $0 == 1 ? UInt8(255) : 0 })
        return CIImage(bitmapData: mask, bytesPerRow: w, size: size, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}

final class PhotoRasterStroke {
    let base: CIImage
    private let ink: CGContext
    private let tip: CGImage
    private let size: Double
    private let flow: Double
    private let opacity: Double
    private let erase: Bool
    private let selection: CIImage?
    private let clone: CGImage?
    private let cloneOffset: CGPoint
    private let spacing: Double
    private let angle: Double
    private let roundness: Double
    private var last: CGPoint?
    private var remainder = 0.0

    init?(base: CIImage, brush: PhotoBrush, size: Double, hardness: Double, opacity: Double, flow: Double, color: NSColor, erase: Bool, selection: CIImage?, clone: CGImage? = nil, cloneOffset: CGPoint = .zero) {
        guard size.isFinite, size > 0, size <= 160000, opacity.isFinite, flow.isFinite,
              let ink = PhotoPixels.context(base.extent.size), let tip = brush.tip(color: color, hardness: hardness, maxDimension: Int(min(2048,max(128,size*2)))) else { return nil }
        self.base = base; self.ink = ink; self.tip = tip; self.size = size; self.flow = flow; self.opacity = opacity; self.erase = erase; self.selection = selection; self.clone = clone; self.cloneOffset = cloneOffset
        spacing = max(0.5,size*(brush.spacing ?? 0.12)); angle = (brush.angle ?? 0) * .pi / 180; roundness = brush.roundness ?? 1
    }
    func append(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let previous = last {
            let distance = hypot(point.x-previous.x, point.y-previous.y)
            if distance > 0 {
                var d = spacing - remainder
                while d <= distance {
                    dab(CGPoint(x: previous.x + (point.x-previous.x)*d/distance, y: previous.y + (point.y-previous.y)*d/distance)); d += spacing
                }
                remainder = (remainder + distance).truncatingRemainder(dividingBy: spacing)
            }
        } else { dab(point) }
        last = point
    }
    private func dab(_ point: CGPoint) {
        // Diameter is the longest side, including tall imported tips.
        let w = size*Double(tip.width)/Double(max(tip.width,tip.height))
        let h = size*Double(tip.height)/Double(max(tip.width,tip.height))*roundness
        let rect = CGRect(x: -w/2, y: -h/2, width: w, height: h)
        ink.saveGState(); ink.setAlpha(flow)
        ink.translateBy(x:point.x,y:point.y); ink.rotate(by:angle)
        if let clone {
            // Tip alpha clips the sampled image; source remains frozen for the entire stroke.
            ink.clip(to: rect, mask: tip)
            ink.rotate(by:-angle); ink.translateBy(x:-point.x,y:-point.y)
            ink.draw(clone, in: CGRect(x: -cloneOffset.x, y: -cloneOffset.y, width: CGFloat(clone.width), height: CGFloat(clone.height)))
        } else { ink.draw(tip, in: rect) }
        ink.restoreGState()
    }
    func image() -> CIImage {
        guard let cg = ink.makeImage() else { return base }
        var paint = CIImage(cgImage: cg).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        if let selection { paint = paint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: base.extent), kCIInputMaskImageKey: selection]) }
        return paint.applyingFilter(erase ? "CIDestinationOutCompositing" : "CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: base]).cropped(to: base.extent)
    }
}

enum PhotoBrushError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

// Independent bounded reader of ABR sampled-tip records. Format research reference:
// https://github.com/GNOME/gimp/blob/master/app/core/gimpbrush-load.c
// Also checked against ag-psd's ABR/descriptor format definitions. No third-party
// implementation is embedded. Static tip metadata is supported, not Adobe's dynamics engine.
enum PhotoABR {
    struct ImportResult { var brushes: [PhotoBrush]; var warnings: [String] }
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= remaining else { throw PhotoBrushError.invalid("Truncated or corrupt ABR brush record.") }
            defer { offset += n }; return Array(bytes[offset..<offset+n])
        }
        mutating func uint(_ n: Int) throws -> Int { try take(n).reduce(0) { ($0 << 8) | Int($1) } }
        mutating func signed32() throws -> Int { Int(Int32(bitPattern: UInt32(try uint(4)))) }
        mutating func child(_ n: Int) throws -> Reader { Reader(bytes: try take(n)) }
        mutating func skip(_ n: Int) throws {
            guard n >= 0, n <= remaining else { throw PhotoBrushError.invalid("Truncated ABR record.") }; offset += n
        }
        mutating func text(_ n: Int) throws -> String { String(bytes:try take(n),encoding:.ascii) ?? "" }
        mutating func unicode() throws -> String {
            let n = try uint(4); guard n <= 16384 else { throw PhotoBrushError.invalid("ABR name is too long.") }
            return String(data:Data(try take(n*2)),encoding:.utf16BigEndian)?.trimmingCharacters(in:.controlCharacters) ?? ""
        }
        mutating func identifier() throws -> String { let n = try uint(4); guard n <= 4096 else { throw PhotoBrushError.invalid("Invalid ABR identifier.") }; return try text(n == 0 ? 4 : n) }
        mutating func double() throws -> Double {
            let bits = try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let value = Double(bitPattern:bits); guard value.isFinite else { throw PhotoBrushError.invalid("Invalid ABR setting.") }; return value
        }
    }
    static func read(_ data: Data, name: String) throws -> [PhotoBrush] {
        try readReport(data,name:name).brushes
    }
    static func readReport(_ data: Data, name: String) throws -> ImportResult {
        guard data.count <= 128*1024*1024 else { throw PhotoBrushError.invalid("Brush packs must be smaller than 128 MB.") }
        var r = Reader(bytes: [UInt8](data)); let version = try r.uint(2), count = try r.uint(2)
        var brushes: [PhotoBrush] = [], warnings: [String] = [], decodedBytes = 0
        var sampleIDs: [String] = [], presets: [[String:Any]] = []
        func checkedAppend(_ brush: PhotoBrush) throws {
            guard brush.isValid else { throw PhotoBrushError.invalid("Invalid brush settings.") }
            decodedBytes += brush.samples?.count ?? 0
            guard brushes.count < 1024, decodedBytes <= 64*1024*1024 else { throw PhotoBrushError.invalid("Decoded brush pack exceeds 64 MB / 1,024 tips. Import a smaller pack.") }
            brushes.append(brush)
        }
        if version == 1 || version == 2 {
            guard count <= 4096 else { throw PhotoBrushError.invalid("Too many ABR records.") }
            for index in 0..<count {
                let type = try r.uint(2), length = try r.uint(4); var record = try r.child(length)
                var decoded: PhotoBrush?
                do {
                    try record.skip(4); let spacing = max(0.01,min(10,Double(try record.uint(2))/100))
                    var title = "\(name) \(index+1)"
                    if version == 2 { let label = try record.unicode(); if !label.isEmpty { title = label } }
                    if type == 2 {
                        try record.skip(9); var brush = try sample(&record,name:title); brush.spacing = spacing; decoded = brush
                    } else if type == 1 {
                        let diameter = try record.uint(2), roundness = try record.uint(2), angle = Int(Int16(bitPattern:UInt16(try record.uint(2)))), hardness = try record.uint(2)
                        decoded = PhotoBrush(name:title,kind:"round",hardness:Double(hardness)/100,spacing:spacing,angle:Double(angle),roundness:max(0.01,Double(roundness)/100),diameter:Double(diameter))
                    } else { warnings.append("Skipped brush \(index+1): unsupported tip type \(type).") }
                } catch { warnings.append("Skipped brush \(index+1): \(error.localizedDescription)") }
                if let decoded {
                    if decoded.isValid { try checkedAppend(decoded) }
                    else { warnings.append("Skipped brush \(index+1): invalid tip settings.") }
                }
            }
        } else if [6,7,9,10].contains(version) && (count == 1 || count == 2) {
            while r.remaining > 0 {
                guard try r.text(4) == "8BIM" else { throw PhotoBrushError.invalid("Invalid ABR section signature.") }
                let tag = try r.text(4), length = try r.uint(4)
                var section = try r.child(length)
                if tag == "samp" {
                    var index = 0
                    while section.remaining > 0 {
                        index += 1; guard index <= 4096 else { throw PhotoBrushError.invalid("Too many sampled tips.") }
                        let length = try section.uint(4); var record = try section.child(length)
                        try section.skip((4-length%4)%4)
                        var decoded: PhotoBrush?, id = ""
                        do {
                            let idLength = try record.uint(1); id = try record.text(idLength)
                            try record.skip(count == 1 ? 10 : 264)
                            decoded = try sample(&record,name:"\(name) \(index)")
                        } catch { warnings.append("Skipped sampled tip \(index): \(error.localizedDescription)") }
                        if let decoded { try checkedAppend(decoded); sampleIDs.append(id) }
                    }
                } else if tag == "desc" {
                    do {
                        guard try section.uint(4) == 16 else { throw PhotoBrushError.invalid("Unknown descriptor version.") }
                        var budget = 100000
                        presets = try descriptor(&section,depth:0,budget:&budget)["Brsh"] as? [[String:Any]] ?? []
                    } catch { warnings.append("Preset names/settings could not be read; sampled tips are still available.") }
                }
                // Some writers pad sections as well as individual sampled records;
                // others start the next signature immediately. Accept both forms.
                var padding = (4-length%4)%4
                while padding > 0 && r.remaining > 0 && r.bytes[r.offset] == 0 { try r.skip(1); padding -= 1 }
            }
            if !presets.isEmpty {
                let samples = brushes; brushes = []; decodedBytes = 0
                var used = Set<Int>()
                for preset in presets {
                    guard let shape = preset["Brsh"] as? [String:Any] else { continue }
                    let type = shape["_class"] as? String ?? ""
                    var brush: PhotoBrush
                    if type == "computedBrush" { brush = PhotoBrush(name:"Round",kind:"round",hardness:1) }
                    else if type == "sampledBrush", let id = shape["sampledData"] as? String, let index = sampleIDs.firstIndex(of:id) { brush = samples[index]; used.insert(index) }
                    else { warnings.append("Skipped a \(type) preset: only round and sampled tips are supported."); continue }
                    brush.name = (preset["Nm  "] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? brush.name
                    brush.spacing = max(0.01,min(10,(shape["Spcn"] as? Double ?? 12)/100))
                    brush.angle = max(-360,min(360,shape["Angl"] as? Double ?? 0))
                    brush.roundness = max(0.01,min(1,(shape["Rndn"] as? Double ?? 100)/100))
                    brush.diameter = max(1,min(8192,shape["Dmtr"] as? Double ?? 40))
                    if brush.samples == nil { brush.hardness = max(0,min(1,(shape["Hrdn"] as? Double ?? 100)/100)) }
                    try checkedAppend(brush)
                }
                for (index,brush) in samples.enumerated() where !used.contains(index) { try checkedAppend(brush) }
                warnings.append("Imported tip shapes and static settings. Photoshop pressure, texture, scatter, dual-brush and mixer dynamics are not reproduced.")
            }
        } else { throw PhotoBrushError.invalid("ABR version \(version).\(count) is not supported. Use ABR v1/v2 or v6/v7/v9/v10 (subversion 1/2), or a PNG tip.") }
        guard !brushes.isEmpty else { throw PhotoBrushError.invalid("No usable brushes in this pack. " + (warnings.first ?? "It may contain only unsupported Photoshop bristle/mixer brushes.")) }
        return ImportResult(brushes:brushes,warnings:Array(Set(warnings)).sorted())
    }
    private static func sample(_ r: inout Reader, name: String) throws -> PhotoBrush {
        let top = try r.signed32(), left = try r.signed32(), bottom = try r.signed32(), right = try r.signed32()
        let depth = try r.uint(2), compression = try r.uint(1), w = right-left, h = bottom-top
        guard w > 0, h > 0, w <= 8192, h <= 8192, w*h <= 32*1024*1024, [8,16].contains(depth), compression <= 1 else { throw PhotoBrushError.invalid("Unsupported sample size/depth. Use 8/16-bit tips up to 8192 px and 32 megapixels, raw or PackBits.") }
        let rowBytes = w*(depth/8)
        var pixels: [UInt8] = []
        if compression == 0 { pixels = try r.take(rowBytes*h) }
        else {
            var lengths: [Int] = []; for _ in 0..<h { lengths.append(try r.uint(2)) }
            for length in lengths {
                var row = try r.child(length), decoded: [UInt8] = []
                while row.remaining > 0 {
                    let token = Int(Int8(bitPattern: UInt8(try row.uint(1))))
                    if token >= 0 { decoded += try row.take(token+1) }
                    else if token != -128 { decoded += [UInt8](repeating: UInt8(try row.uint(1)), count: 1-token) }
                    guard decoded.count <= rowBytes else { throw PhotoBrushError.invalid("Corrupt ABR compressed row.") }
                }
                guard decoded.count == rowBytes else { throw PhotoBrushError.invalid("Truncated ABR compressed row.") }
                pixels += decoded
            }
        }
        if depth == 16 { pixels = stride(from:0,to:pixels.count,by:2).map { pixels[$0] } }
        guard pixels.contains(where:{ $0 > 0 }) else { throw PhotoBrushError.invalid("This tip is entirely empty.") }
        return PhotoBrush(name: name, kind: "sample", hardness: 1, width: w, height: h, samples: Data(pixels))
    }

    // A bounded subset of Photoshop ActionDescriptor values, sufficient to preserve
    // preset names, sample IDs and ordinary round-brush geometry. Unknown descriptor
    // types fail just this metadata section, never discard already decoded samples.
    private static func descriptor(_ r: inout Reader, depth: Int, budget: inout Int) throws -> [String:Any] {
        guard depth < 32 else { throw PhotoBrushError.invalid("ABR metadata nesting is too deep.") }
        _ = try r.unicode(); let classID = try r.identifier(), count = try r.uint(4)
        guard count <= budget else { throw PhotoBrushError.invalid("ABR metadata is too large.") }; budget -= count
        var result: [String:Any] = ["_class":classID]
        for _ in 0..<count { let key = try r.identifier(), type = try r.text(4); result[key] = try value(&r,type:type,depth:depth+1,budget:&budget) }
        return result
    }
    private static func value(_ r: inout Reader, type: String, depth: Int, budget: inout Int) throws -> Any {
        guard depth < 32 else { throw PhotoBrushError.invalid("ABR metadata nesting is too deep.") }
        switch type {
        case "Objc","GlbO": return try descriptor(&r,depth:depth,budget:&budget)
        case "VlLs":
            let count = try r.uint(4); guard count <= budget else { throw PhotoBrushError.invalid("ABR list is too large.") }; budget -= count
            var values: [Any] = []; for _ in 0..<count { let type = try r.text(4); values.append(try value(&r,type:type,depth:depth+1,budget:&budget)) }; return values
        case "doub": return try r.double()
        case "UntF": try r.skip(4); return try r.double()
        case "long": return Double(try r.signed32())
        case "bool": return try r.uint(1) != 0
        case "TEXT": return try r.unicode()
        case "enum": _ = try r.identifier(); return try r.identifier()
        case "type","GlbC": _ = try r.unicode(); return try r.identifier()
        case "tdta","alis","Pth ": let n = try r.uint(4); try r.skip(n); return ""
        case "comp": try r.skip(8); return ""
        default: throw PhotoBrushError.invalid("Unsupported ABR metadata value \(type).")
        }
    }
}
