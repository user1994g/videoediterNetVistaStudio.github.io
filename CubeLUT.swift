import Foundation
import CoreImage
import CoreGraphics

/// The saved, per-clip reference to an external `.cube` file.
///
/// The original path is retained for its label and future relinking. New LUTs
/// can also embed their source bytes, allowing saved projects to survive a
/// moved or disconnected external file.
struct ClipLUTSettings: Codable, Equatable {
    /// Stable cache identity shared by every clip receiving this assignment.
    var id: UUID
    var fileURL: URL
    /// A normalized mix value: 0 is the original image and 1 is the full LUT.
    var strength: Double
    /// The original UTF-8 `.cube` bytes, stored with the project so colour work
    /// survives if the external file is later moved, renamed, or disconnected.
    var embeddedSource: Data?

    init(id: UUID = UUID(), fileURL: URL, strength: Double = 1, embeddedSource: Data? = nil) {
        self.id = id
        self.fileURL = fileURL.standardizedFileURL
        self.strength = Self.normalizedStrength(strength)
        self.embeddedSource = embeddedSource
    }

    /// Imports, validates, and embeds a LUT in one operation. This is the
    /// preferred initializer for a file selected by the user.
    init(embeddingFileAt fileURL: URL, strength: Double = 1) throws {
        let resolvedURL = fileURL.standardizedFileURL
        let source = try CubeLUT.sourceData(contentsOf: resolvedURL)
        guard let text = String(data: source, encoding: .utf8) else {
            throw CubeLUTError.invalidUTF8(resolvedURL)
        }
        _ = try CubeLUT.parse(text, sourceURL: resolvedURL)
        self.init(fileURL: resolvedURL, strength: strength, embeddedSource: source)
    }

    enum CodingKeys: String, CodingKey { case id, fileURL, strength, embeddedSource }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fileURL = try values.decode(URL.self, forKey: .fileURL).standardizedFileURL
        let decodedStrength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        guard decodedStrength.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .strength,
                in: values,
                debugDescription: "LUT strength must be a finite number."
            )
        }
        strength = Self.normalizedStrength(decodedStrength)
        embeddedSource = try values.decodeIfPresent(Data.self, forKey: .embeddedSource)
        if let embeddedSource, embeddedSource.count > CubeLUT.maximumFileBytes {
            throw DecodingError.dataCorruptedError(
                forKey: .embeddedSource,
                in: values,
                debugDescription: "The embedded LUT exceeds the \(CubeLUT.maximumFileBytes)-byte safety limit."
            )
        }
    }

    private static func normalizedStrength(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}

enum CubeLUTError: Error, Equatable, LocalizedError {
    case fileNotFound(URL)
    case fileIsNotRegular(URL)
    case fileTooLarge(URL, maximumBytes: Int)
    case sourceTextTooLarge(maximumBytes: Int)
    case cannotRead(URL, reason: String)
    case invalidUTF8(URL?)
    case missingThreeDimensionalSize
    case duplicateDirective(String, line: Int)
    case directiveAfterTableData(String, line: Int)
    case unsupportedOneDimensionalLUT(line: Int)
    case unsupportedDirective(String, line: Int)
    case invalidTitle(line: Int)
    case invalidDimension(String, line: Int)
    case dimensionOutOfRange(Int, line: Int)
    case invalidVector(String, line: Int)
    case nonFiniteValue(line: Int)
    case invalidDomain(axis: String, minimum: Float, maximum: Float)
    case tableDataBeforeDimension(line: Int)
    case invalidTableRow(line: Int)
    case tooManyTableEntries(expected: Int, line: Int)
    case tableEntryCountMismatch(expected: Int, actual: Int)
    case invalidStrength(Double)
    case coreImageFilterUnavailable(String)
    case coreImageProcessingFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "The LUT file “\(url.lastPathComponent)” could not be found. Choose the file again."
        case .fileIsNotRegular(let url):
            return "“\(url.lastPathComponent)” is not a readable LUT file."
        case .fileTooLarge(let url, let maximumBytes):
            return "The LUT file “\(url.lastPathComponent)” is too large. The limit is \(maximumBytes / 1_048_576) MB."
        case .sourceTextTooLarge(let maximumBytes):
            return "The LUT text is too large. The limit is \(maximumBytes / 1_048_576) MB."
        case .cannotRead(let url, let reason):
            return "The LUT file “\(url.lastPathComponent)” could not be read: \(reason)"
        case .invalidUTF8(let url):
            return url.map { "The LUT file “\($0.lastPathComponent)” is not valid UTF-8 text." }
                ?? "The LUT is not valid UTF-8 text."
        case .missingThreeDimensionalSize:
            return "The LUT is missing its LUT_3D_SIZE line."
        case .duplicateDirective(let name, let line):
            return "The LUT repeats \(name) on line \(line)."
        case .directiveAfterTableData(let name, let line):
            return "The \(name) setting on line \(line) must appear before the LUT table."
        case .unsupportedOneDimensionalLUT(let line):
            return "This file contains a 1D LUT on line \(line). NetVista Studio currently accepts 3D .cube LUTs."
        case .unsupportedDirective(let name, let line):
            return "The LUT setting \(name) on line \(line) is not supported."
        case .invalidTitle(let line):
            return "The LUT title on line \(line) must be enclosed in one pair of quotation marks."
        case .invalidDimension(let value, let line):
            return "“\(value)” on line \(line) is not a valid whole-number LUT size."
        case .dimensionOutOfRange(let value, let line):
            return "The LUT size \(value) on line \(line) is unsupported. Use a size from 2 to 64."
        case .invalidVector(let name, let line):
            return "\(name) on line \(line) must contain exactly three valid numbers."
        case .nonFiniteValue(let line):
            return "The LUT contains an infinite or invalid number on line \(line)."
        case .invalidDomain(let axis, let minimum, let maximum):
            return "The LUT’s \(axis) domain is invalid: \(minimum) must be less than \(maximum)."
        case .tableDataBeforeDimension(let line):
            return "The LUT table starts on line \(line) before LUT_3D_SIZE is declared."
        case .invalidTableRow(let line):
            return "The LUT table row on line \(line) must contain exactly three valid numbers."
        case .tooManyTableEntries(let expected, let line):
            return "The LUT has more than the expected \(expected) table rows (extra data begins on line \(line))."
        case .tableEntryCountMismatch(let expected, let actual):
            return "The LUT table is incomplete: expected \(expected) rows but found \(actual)."
        case .invalidStrength(let strength):
            return "The LUT strength \(strength) is invalid."
        case .coreImageFilterUnavailable(let name):
            return "The system colour filter \(name) is unavailable."
        case .coreImageProcessingFailed(let name):
            return "The system colour filter \(name) could not process this frame."
        }
    }
}

/// A parsed Adobe/IRIDAS-style three-dimensional `.cube` lookup table.
///
/// `cubeData` is already in Core Image's required native Float32 RGBA layout:
/// red varies fastest, then green, then blue, with an opaque alpha component.
struct CubeLUT {
    static let minimumDimension = 2
    static let maximumDimension = 64
    static let maximumFileBytes = 64 * 1_048_576

    let title: String?
    let dimension: Int
    let domainMinimum: SIMD3<Float>
    let domainMaximum: SIMD3<Float>
    let cubeData: Data
    let sourceURL: URL?

    fileprivate init(
        title: String?,
        dimension: Int,
        domainMinimum: SIMD3<Float>,
        domainMaximum: SIMD3<Float>,
        cubeData: Data,
        sourceURL: URL?
    ) {
        self.title = title
        self.dimension = dimension
        self.domainMinimum = domainMinimum
        self.domainMaximum = domainMaximum
        self.cubeData = cubeData
        self.sourceURL = sourceURL
    }

    init(contentsOf url: URL) throws {
        let resolvedURL = url.standardizedFileURL
        let bytes = try Self.sourceData(contentsOf: resolvedURL)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CubeLUTError.invalidUTF8(resolvedURL)
        }
        self = try Self.parse(text, sourceURL: resolvedURL)
    }

    static func sourceData(contentsOf url: URL) throws -> Data {
        let resolvedURL = url.standardizedFileURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: resolvedURL.path) else {
            throw CubeLUTError.fileNotFound(resolvedURL)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: resolvedURL.path)
        } catch {
            throw CubeLUTError.cannotRead(resolvedURL, reason: error.localizedDescription)
        }
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw CubeLUTError.fileIsNotRegular(resolvedURL)
        }
        if let byteCount = (attributes[.size] as? NSNumber)?.intValue,
           byteCount > Self.maximumFileBytes {
            throw CubeLUTError.fileTooLarge(resolvedURL, maximumBytes: Self.maximumFileBytes)
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: resolvedURL, options: [.mappedIfSafe])
        } catch {
            throw CubeLUTError.cannotRead(resolvedURL, reason: error.localizedDescription)
        }
        guard bytes.count <= Self.maximumFileBytes else {
            throw CubeLUTError.fileTooLarge(resolvedURL, maximumBytes: Self.maximumFileBytes)
        }
        return bytes
    }

    static func parse(_ text: String, sourceURL: URL? = nil) throws -> CubeLUT {
        guard text.utf8.count <= maximumFileBytes else {
            throw CubeLUTError.sourceTextTooLarge(maximumBytes: maximumFileBytes)
        }
        var parser = CubeLUTParser(sourceURL: sourceURL)
        return try parser.parse(text)
    }
    /// Applies the LUT and optionally blends it with the untreated frame.
    /// DOMAIN_MIN/MAX are normalized before Core Image samples the cube.
    func applying(
        to source: CIImage,
        strength: Double = 1,
        colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
    ) throws -> CIImage {
        guard strength.isFinite else { throw CubeLUTError.invalidStrength(strength) }
        let mix = min(1, max(0, strength))
        guard mix > 0 else { return source }

        let normalized = try domainNormalizedImage(source)
        let filterName = "CIColorCubeWithColorSpace"
        guard let cubeFilter = CIFilter(name: filterName) else {
            throw CubeLUTError.coreImageFilterUnavailable(filterName)
        }
        cubeFilter.setValue(normalized, forKey: kCIInputImageKey)
        cubeFilter.setValue(dimension, forKey: "inputCubeDimension")
        cubeFilter.setValue(cubeData, forKey: "inputCubeData")
        if let colorSpace { cubeFilter.setValue(colorSpace, forKey: "inputColorSpace") }
        guard let graded = cubeFilter.outputImage?.cropped(to: source.extent) else {
            throw CubeLUTError.coreImageProcessingFailed(filterName)
        }
        guard mix < 1 else { return graded }

        let blendName = "CIBlendWithAlphaMask"
        guard let blend = CIFilter(name: blendName) else {
            throw CubeLUTError.coreImageFilterUnavailable(blendName)
        }
        let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: mix))
            .cropped(to: source.extent)
        blend.setValue(graded, forKey: kCIInputImageKey)
        blend.setValue(source, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage?.cropped(to: source.extent) else {
            throw CubeLUTError.coreImageProcessingFailed(blendName)
        }
        return output
    }

    private func domainNormalizedImage(_ source: CIImage) throws -> CIImage {
        let minimum = domainMinimum
        let maximum = domainMaximum
        if minimum == SIMD3<Float>(repeating: 0), maximum == SIMD3<Float>(repeating: 1) {
            return source
        }

        let redRange = maximum.x - minimum.x
        let greenRange = maximum.y - minimum.y
        let blueRange = maximum.z - minimum.z
        guard redRange.isFinite, greenRange.isFinite, blueRange.isFinite,
              redRange > 0, greenRange > 0, blueRange > 0 else {
            throw CubeLUTError.coreImageProcessingFailed("DOMAIN_MIN/MAX normalization")
        }
        let redScale = CGFloat(1 / redRange)
        let greenScale = CGFloat(1 / greenRange)
        let blueScale = CGFloat(1 / blueRange)
        return source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: redScale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: greenScale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blueScale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(
                x: CGFloat(-minimum.x) * redScale,
                y: CGFloat(-minimum.y) * greenScale,
                z: CGFloat(-minimum.z) * blueScale,
                w: 0
            )
        ])
    }
}

/// A small, bounded and thread-safe cache so video playback does not parse the
/// same LUT text for every frame. Entries are refreshed when the source file's
/// size or modification date changes.
final class CubeLUTCache: @unchecked Sendable {
    static let shared = CubeLUTCache()

    private struct FileStamp: Equatable {
        let byteCount: UInt64
        let modifiedAt: TimeInterval
    }

    private struct Entry {
        let stamp: FileStamp?
        let lut: CubeLUT
        var lastAccess: UInt64
    }

    private enum CacheKey: Hashable {
        case external(URL)
        case embedded(UUID)
    }

    private let lock = NSLock()
    private let capacity: Int
    private var accessCounter: UInt64 = 0
    private var entries: [CacheKey: Entry] = [:]

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    func lut(for settings: ClipLUTSettings) throws -> CubeLUT {
        guard let source = settings.embeddedSource else {
            return try lut(at: settings.fileURL)
        }
        let resolvedURL = settings.fileURL.standardizedFileURL
        guard source.count <= CubeLUT.maximumFileBytes else {
            throw CubeLUTError.fileTooLarge(resolvedURL, maximumBytes: CubeLUT.maximumFileBytes)
        }
        let key = CacheKey.embedded(settings.id)

        lock.lock()
        accessCounter &+= 1
        let access = accessCounter
        if var cached = entries[key] {
            cached.lastAccess = access
            entries[key] = cached
            lock.unlock()
            return cached.lut
        }
        lock.unlock()

        guard let text = String(data: source, encoding: .utf8) else {
            throw CubeLUTError.invalidUTF8(resolvedURL)
        }
        let parsed = try CubeLUT.parse(text, sourceURL: resolvedURL)
        store(Entry(stamp: nil, lut: parsed, lastAccess: access), for: key)
        return parsed
    }

    func lut(at url: URL) throws -> CubeLUT {
        let resolvedURL = url.standardizedFileURL
        let stamp = try fileStamp(at: resolvedURL)
        let key = CacheKey.external(resolvedURL)

        lock.lock()
        accessCounter &+= 1
        let access = accessCounter
        if var cached = entries[key], cached.stamp == stamp {
            cached.lastAccess = access
            entries[key] = cached
            lock.unlock()
            return cached.lut
        }
        lock.unlock()

        let parsed = try CubeLUT(contentsOf: resolvedURL)
        store(Entry(stamp: stamp, lut: parsed, lastAccess: access), for: key)
        return parsed
    }

    private func store(_ entry: Entry, for key: CacheKey) {
        lock.lock()
        entries[key] = entry
        if entries.count > capacity,
           let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            entries.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func fileStamp(at url: URL) throws -> FileStamp {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { throw CubeLUTError.fileNotFound(url) }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch {
            throw CubeLUTError.cannotRead(url, reason: error.localizedDescription)
        }
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw CubeLUTError.fileIsNotRegular(url)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= UInt64(CubeLUT.maximumFileBytes) else {
            throw CubeLUTError.fileTooLarge(url, maximumBytes: CubeLUT.maximumFileBytes)
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return FileStamp(byteCount: size, modifiedAt: modified)
    }
}

enum CubeLUTRuntime {
    static func apply(
        _ settings: ClipLUTSettings?,
        to source: CIImage,
        cache: CubeLUTCache = .shared,
        colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)
    ) throws -> CIImage {
        guard let settings else { return source }
        let lut = try cache.lut(for: settings)
        return try lut.applying(to: source, strength: settings.strength, colorSpace: colorSpace)
    }

    /// Playback-friendly behavior: a missing or damaged external LUT never
    /// makes the monitor black. The original frame is returned and the caller
    /// receives a localized error suitable for a status label or warning badge.
    static func applyOrPassThrough(
        _ settings: ClipLUTSettings?,
        to source: CIImage,
        cache: CubeLUTCache = .shared,
        colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB),
        report: ((CubeLUTError) -> Void)? = nil
    ) -> CIImage {
        do {
            return try apply(settings, to: source, cache: cache, colorSpace: colorSpace)
        } catch let error as CubeLUTError {
            report?(error)
            return source
        } catch {
            report?(.coreImageProcessingFailed(error.localizedDescription))
            return source
        }
    }
}

private struct CubeLUTParser {
    let sourceURL: URL?
    private var title: String?
    private var sawTitle = false
    private var dimension: Int?
    private var domainMinimum = SIMD3<Float>(repeating: 0)
    private var domainMaximum = SIMD3<Float>(repeating: 1)
    private var sawDomainMinimum = false
    private var sawDomainMaximum = false
    private var rgbaValues: [Float] = []
    private var tableEntryCount = 0
    private var tableStarted = false

    init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    mutating func parse(_ source: String) throws -> CubeLUT {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawSubstring) in lines.enumerated() {
            let lineNumber = offset + 1
            var rawLine = String(rawSubstring)
            if rawLine.last == "\r" { rawLine.removeLast() }
            if lineNumber == 1, rawLine.first == "\u{FEFF}" { rawLine.removeFirst() }
            let line = Self.removingComment(from: rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if tableStarted {
                if !Self.looksLikeNumber(line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "") {
                    let directive = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? line
                    throw CubeLUTError.directiveAfterTableData(directive, line: lineNumber)
                }
                try appendTableRow(line, lineNumber: lineNumber)
                continue
            }

            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = tokens.first else { continue }
            let keyword = first.uppercased()
            switch keyword {
            case "TITLE":
                guard !sawTitle else { throw CubeLUTError.duplicateDirective("TITLE", line: lineNumber) }
                title = try Self.parseTitle(from: line, keyword: first, lineNumber: lineNumber)
                sawTitle = true
            case "LUT_3D_SIZE":
                guard dimension == nil else { throw CubeLUTError.duplicateDirective("LUT_3D_SIZE", line: lineNumber) }
                guard tokens.count == 2, let size = Int(tokens[1]) else {
                    throw CubeLUTError.invalidDimension(tokens.dropFirst().joined(separator: " "), line: lineNumber)
                }
                guard (CubeLUT.minimumDimension...CubeLUT.maximumDimension).contains(size) else {
                    throw CubeLUTError.dimensionOutOfRange(size, line: lineNumber)
                }
                dimension = size
                rgbaValues.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN":
                guard !sawDomainMinimum else { throw CubeLUTError.duplicateDirective("DOMAIN_MIN", line: lineNumber) }
                domainMinimum = try Self.parseVector(tokens, name: "DOMAIN_MIN", lineNumber: lineNumber)
                sawDomainMinimum = true
            case "DOMAIN_MAX":
                guard !sawDomainMaximum else { throw CubeLUTError.duplicateDirective("DOMAIN_MAX", line: lineNumber) }
                domainMaximum = try Self.parseVector(tokens, name: "DOMAIN_MAX", lineNumber: lineNumber)
                sawDomainMaximum = true
            case "LUT_1D_SIZE":
                throw CubeLUTError.unsupportedOneDimensionalLUT(line: lineNumber)
            default:
                if Self.looksLikeNumber(first) {
                    guard dimension != nil else { throw CubeLUTError.tableDataBeforeDimension(line: lineNumber) }
                    tableStarted = true
                    try appendTableRow(line, lineNumber: lineNumber)
                } else {
                    throw CubeLUTError.unsupportedDirective(first, line: lineNumber)
                }
            }
        }

        guard let dimension else { throw CubeLUTError.missingThreeDimensionalSize }
        try validateDomain(axis: "red", minimum: domainMinimum.x, maximum: domainMaximum.x)
        try validateDomain(axis: "green", minimum: domainMinimum.y, maximum: domainMaximum.y)
        try validateDomain(axis: "blue", minimum: domainMinimum.z, maximum: domainMaximum.z)

        let expected = dimension * dimension * dimension
        guard tableEntryCount == expected else {
            throw CubeLUTError.tableEntryCountMismatch(expected: expected, actual: tableEntryCount)
        }
        let data = rgbaValues.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        return CubeLUT(
            title: title,
            dimension: dimension,
            domainMinimum: domainMinimum,
            domainMaximum: domainMaximum,
            cubeData: data,
            sourceURL: sourceURL
        )
    }

    private mutating func appendTableRow(_ line: String, lineNumber: Int) throws {
        guard let size = dimension else { throw CubeLUTError.tableDataBeforeDimension(line: lineNumber) }
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count == 3,
              let red = Float(tokens[0]),
              let green = Float(tokens[1]),
              let blue = Float(tokens[2]) else {
            throw CubeLUTError.invalidTableRow(line: lineNumber)
        }
        guard red.isFinite, green.isFinite, blue.isFinite else {
            throw CubeLUTError.nonFiniteValue(line: lineNumber)
        }
        let expected = size * size * size
        guard tableEntryCount < expected else {
            throw CubeLUTError.tooManyTableEntries(expected: expected, line: lineNumber)
        }
        // Both the Cube specification and Core Image use R-fastest ordering.
        rgbaValues.append(contentsOf: [red, green, blue, 1])
        tableEntryCount += 1
    }

    private func validateDomain(axis: String, minimum: Float, maximum: Float) throws {
        let range = maximum - minimum
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, range.isFinite else {
            throw CubeLUTError.invalidDomain(axis: axis, minimum: minimum, maximum: maximum)
        }
    }

    private static func parseVector(_ tokens: [String], name: String, lineNumber: Int) throws -> SIMD3<Float> {
        guard tokens.count == 4,
              let red = Float(tokens[1]),
              let green = Float(tokens[2]),
              let blue = Float(tokens[3]) else {
            throw CubeLUTError.invalidVector(name, line: lineNumber)
        }
        guard red.isFinite, green.isFinite, blue.isFinite else {
            throw CubeLUTError.nonFiniteValue(line: lineNumber)
        }
        return SIMD3<Float>(red, green, blue)
    }

    private static func parseTitle(from line: String, keyword: String, lineNumber: Int) throws -> String {
        let start = line.index(line.startIndex, offsetBy: keyword.count)
        let remainder = line[start...].trimmingCharacters(in: .whitespaces)
        guard remainder.count >= 2, remainder.first == "\"", remainder.last == "\"" else {
            throw CubeLUTError.invalidTitle(line: lineNumber)
        }
        let innerStart = remainder.index(after: remainder.startIndex)
        let innerEnd = remainder.index(before: remainder.endIndex)
        let inner = String(remainder[innerStart..<innerEnd])
        guard !inner.contains("\"") else { throw CubeLUTError.invalidTitle(line: lineNumber) }
        return inner
    }

    private static func looksLikeNumber(_ token: String) -> Bool {
        if Float(token) != nil { return true }
        switch token.lowercased() {
        case "nan", "+nan", "-nan", "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity":
            return true
        default:
            return false
        }
    }

    private static func removingComment(from line: String) -> String {
        var insideTitle = false
        for index in line.indices {
            let character = line[index]
            if character == "\"" { insideTitle.toggle() }
            if character == "#", !insideTitle { return String(line[..<index]) }
        }
        return line
    }
}
