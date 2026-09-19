import Cocoa
import CoreImage

@main struct PhotoRasterChecks {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    static func rgba(_ image: CIImage, _ x: Int, _ y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x:x,y:y,width:1,height:1), format:.RGBA8, colorSpace:CGColorSpaceCreateDeviceRGB()); return bytes
    }
    static func main() throws {
        let extent = CGRect(x:0,y:0,width:64,height:64)
        let clear = CIImage(color:.clear).cropped(to:extent)
        let stroke = PhotoRasterStroke(base:clear,brush:PhotoBrush.defaults[0],size:12,hardness:1,opacity:0.5,flow:1,color:.red,erase:false,selection:nil)!
        stroke.append(CGPoint(x:10,y:12)); stroke.append(CGPoint(x:50,y:12))
        let painted = stroke.image(), centre = rgba(painted,30,12)
        precondition((120...135).contains(centre[0]) && (120...135).contains(centre[3]), "Stroke opacity must cap at 50% across overlapping dabs (premultiplied RGBA): \(centre)")
        precondition(rgba(painted,30,50)[3] == 0, "Stroke must not be vertically mirrored")
        precondition(rgba(clear,30,12)[3] == 0, "Undo source must remain immutable")
        let erase = PhotoRasterStroke(base:painted,brush:PhotoBrush.defaults[0],size:20,hardness:1,opacity:1,flow:1,color:.black,erase:true,selection:nil)!
        erase.append(CGPoint(x:30,y:12)); precondition(rgba(erase.image(),30,12)[3] == 0)
        let selection = CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:25,height:64)).composited(over:CIImage(color:.black).cropped(to:extent))
        let clipped = PhotoRasterStroke(base:clear,brush:PhotoBrush.defaults[1],size:30,hardness:0,opacity:1,flow:1,color:.blue,erase:false,selection:selection)!
        clipped.append(CGPoint(x:24,y:20)); precondition(rgba(clipped.image(),30,20)[3] == 0); precondition(rgba(clipped.image(),20,20)[3] > 0)
        let blocks = CIImage(color:.red).cropped(to:CGRect(x:0,y:0,width:20,height:15)).composited(over:CIImage(color:.blue).cropped(to:extent))
        let region = PhotoPixels.region(at:CGPoint(x:3,y:4),image:blocks,tolerance:1,context:context)!
        precondition(rgba(region,3,4)[0] > 250 && rgba(region,30,4)[0] == 0 && rgba(region,3,50)[0] == 0, "Wand selection orientation and connectivity")
        let clone = PhotoRasterStroke(base:blocks,brush:PhotoBrush.defaults[0],size:10,hardness:1,opacity:1,flow:1,color:.black,erase:false,selection:nil,clone:context.createCGImage(blocks,from:extent),cloneOffset:CGPoint(x:-30,y:-30))!
        clone.append(CGPoint(x:35,y:35)); precondition(rgba(clone.image(),35,35)[0] > 200, "Clone must sample requested source")
        let encoded = try PhotoPixels.png(painted,context:context), decoded = CIImage(data:encoded)!
        precondition(abs(Int(rgba(decoded,30,12)[3])-Int(centre[3])) <= 1, "Embedded pixel round trip")
        precondition(!PhotoPixels.validSize(CGSize(width:16000,height:16000)))
        precondition(!PhotoPixels.validSize(CGSize(width:Double.nan,height:1)))
        try abrChecks()
        print("PASS: brush opacity/spacing, immutable undo source, eraser, soft selection clipping, wand connectivity/orientation, clone source, PNG round trip, size guards, ABR raw/RLE/truncation")
    }
    static func be(_ n: Int, _ count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded:n >> ($0*8)) } }
    static func sample(_ compressed: Bool) -> [UInt8] {
        let bounds = be(0,4)+be(0,4)+be(2,4)+be(2,4)+be(8,2)
        return bounds + (compressed ? [1]+be(3,2)+be(3,2)+[1,255,0,1,64,128] : [0,255,0,64,128])
    }
    static func abrChecks() throws {
        for compressed in [false,true] {
            let body = [UInt8](repeating:0,count:15)+sample(compressed)
            let file = be(1,2)+be(1,2)+be(2,2)+be(body.count,4)+body
            let brushes = try PhotoABR.read(Data(file),name:"Fixture")
            precondition(brushes.count == 1 && brushes[0].samples == Data([255,0,64,128]))
            for size in [0,1,3,file.count-1] {
                do { _ = try PhotoABR.read(Data(file.prefix(size)),name:"Bad"); preconditionFailure("Truncation accepted") } catch {}
            }
        }
        var record = [UInt8(36)]+Array(String(repeating:"a",count:36).utf8)+[UInt8](repeating:0,count:10)+sample(false)
        let length = record.count; record += [UInt8](repeating:0,count:(4-length%4)%4)
        let section = be(length,4)+record
        let file = be(6,2)+be(1,2)+Array("8BIMsamp".utf8)+be(section.count,4)+section
        let v6 = try PhotoABR.read(Data(file),name:"V6")
        precondition(v6.first?.samples == Data([255,0,64,128]))
        // Modern metadata-only packs can contain round brushes with no bitmap section.
        func unicode(_ text: String) -> [UInt8] { let units = Array(text.utf16); return be(units.count,4)+units.flatMap { be(Int($0),2) } }
        func identifier(_ text: String) -> [UInt8] { be(text.utf8.count,4)+Array(text.utf8) }
        func descriptor(_ cls: String, _ entries: [(String,String,[UInt8])]) -> [UInt8] {
            unicode("")+identifier(cls)+be(entries.count,4)+entries.flatMap { identifier($0.0)+Array($0.1.utf8)+$0.2 }
        }
        let shape = descriptor("computedBrush",[("Dmtr","long",be(40,4)),("Hrdn","long",be(50,4))])
        let preset = descriptor("brushPreset",[("Nm  ","TEXT",unicode("My soft round")),("Brsh","Objc",shape)])
        let desc = be(16,4)+descriptor("null",[("Brsh","VlLs",be(1,4)+Array("Objc".utf8)+preset)])
        let computedFile = be(6,2)+be(2,2)+Array("8BIMdesc".utf8)+be(desc.count,4)+desc
        let round = try PhotoABR.read(Data(computedFile),name:"Round")[0]
        precondition(round.samples == nil && round.name == "My soft round" && round.hardness == 0.5 && round.diameter == 40)
        // 16-bit raw and PackBits; high bytes preserve coverage in the 8-bit engine.
        for compressed in [false,true] {
            let bounds = be(0,4)+be(0,4)+be(2,4)+be(2,4)+be(16,2)
            let values: [UInt8] = [255,255,0,0,64,0,128,0]
            let pixels = compressed ? [UInt8(1)]+be(5,2)+be(5,2)+[3]+Array(values.prefix(4))+[3]+Array(values.suffix(4)) : [UInt8(0)]+values
            let body = [UInt8](repeating:0,count:15)+bounds+pixels
            let file = be(1,2)+be(1,2)+be(2,2)+be(body.count,4)+body
            let tips = try PhotoABR.read(Data(file),name:"16bit")
            precondition(tips[0].samples == Data([255,0,64,128]))
        }
        // A damaged tip in an otherwise framed pack must not discard good tips.
        let good = [UInt8](repeating:0,count:15)+sample(false)
        let mixed = be(1,2)+be(2,2)+be(2,2)+be(1,4)+[0]+be(2,2)+be(good.count,4)+good
        let report = try PhotoABR.readReport(Data(mixed),name:"Mixed")
        precondition(report.brushes.count == 1 && !report.warnings.isEmpty)
        let invalid = PhotoBrush(name:"Bad",kind:"sample",hardness:1,width:Int.max,height:Int.max,samples:Data([1]))
        precondition(!invalid.isValid && invalid.tip(color:.black,hardness:1) == nil)
        let huge = PhotoBrush(name:"Large",kind:"sample",hardness:1,width:4096,height:4096,samples:Data(repeating:255,count:4096*4096))
        let thumb = huge.tip(color:.white,hardness:1,maxDimension:64)!
        precondition(thumb.width == 64 && thumb.height == 64,"Large-tip previews must stay bounded")
        let savedRound = try JSONDecoder().decode(PhotoBrush.self,from:JSONEncoder().encode(round))
        precondition(savedRound.name == round.name && savedRound.isValid && savedRound.diameter == 40)
        for path in CommandLine.arguments.dropFirst() {
            let report = try PhotoABR.readReport(Data(contentsOf:URL(fileURLWithPath:path)),name:"External")
            precondition(!report.brushes.isEmpty && report.brushes.allSatisfy(\.isValid))
            print("ABR fixture: \(path): \(report.brushes.count) brushes, names: \(report.brushes.prefix(3).map(\.name)); warnings: \(report.warnings)")
        }
    }
}
