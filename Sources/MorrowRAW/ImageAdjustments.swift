import Foundation

struct ImageAdjustments: Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 5200
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var sharpening: Double = 0
    var noiseReduction: Double = 0
    var vignette: Double = 0
    var distortion: Double = 0
    var cropAspectRatio: String = "Original"
    var cropAngle: Double = 0
    var cropX: Double = 0
    var cropY: Double = 0
    var cropWidth: Double = 1
    var cropHeight: Double = 1
    var rotation: Int = 0
    var healSize: Double = 10
    var gradients: [LinearGradient] = []
    var adjustmentBrushes: [AdjustmentBrush] = []
    var healSpots: [HealSpot] = []
    var colorProfileMatrix = ColorCheckerProfile.identityMatrix
    var cachedExif: ExifData?

    mutating func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let parser = AdjustmentXMLParser()
        try parser.parse(data)
        gradients = parser.gradients
        adjustmentBrushes = parser.adjustmentBrushes
        healSpots = parser.healSpots
        colorProfileMatrix = parser.colorProfileMatrix
        cachedExif = parser.exif
        exposure = parser.number("Exposure", fallback: exposure)
        contrast = parser.number("Contrast", fallback: contrast)
        highlights = parser.number("Highlights", fallback: highlights)
        shadows = parser.number("Shadows", fallback: shadows)
        whites = parser.number("Whites", fallback: whites)
        blacks = parser.number("Blacks", fallback: blacks)
        temperature = parser.number("Temperature", fallback: temperature)
        tint = parser.number("Tint", fallback: tint)
        vibrance = parser.number("Vibrance", fallback: vibrance)
        saturation = parser.number("Saturation", fallback: saturation)
        sharpening = parser.number("Sharpening", fallback: sharpening)
        noiseReduction = parser.number("NoiseReduction", fallback: noiseReduction)
        vignette = parser.number("Vignette", fallback: vignette)
        distortion = parser.number("Distortion", fallback: distortion)
        cropAngle = parser.number("CropAngle", fallback: cropAngle)
        cropX = parser.number("CropX", fallback: cropX)
        cropY = parser.number("CropY", fallback: cropY)
        cropWidth = parser.number("CropWidth", fallback: cropWidth)
        cropHeight = parser.number("CropHeight", fallback: cropHeight)
        if let numericRotation = parser.values["Rotation"] {
            rotation = Int(numericRotation)
        } else {
            let value = parser.text("Rotation", fallback: "R\(rotation)")
            rotation = Int(value.dropFirst().prefix { $0.isNumber }) ?? rotation
        }
        healSize = parser.number("HealSize", fallback: healSize)
        cropAspectRatio = parser.text("CropAspectRatio", fallback: cropAspectRatio)
    }

    func save(to url: URL) throws {
        let root = XMLElement(name: "RawPipe")
        let placeholder = XMLElement(name: "IsPlaceholder", stringValue: "false")
        let values = XMLElement(name: "Adjustments")
        let fields: [(String, String)] = [
            ("Exposure", exposure.xmlValue), ("Contrast", contrast.xmlValue),
            ("Highlights", highlights.xmlValue), ("Shadows", shadows.xmlValue),
            ("Whites", whites.xmlValue), ("Blacks", blacks.xmlValue),
            ("Temperature", temperature.xmlValue), ("Tint", tint.xmlValue),
            ("Vibrance", vibrance.xmlValue), ("Saturation", saturation.xmlValue),
            ("Sharpening", sharpening.xmlValue), ("NoiseReduction", noiseReduction.xmlValue),
            ("Vignette", vignette.xmlValue), ("Distortion", distortion.xmlValue),
            ("CropAspectRatio", cropAspectRatio), ("CropAngle", cropAngle.xmlValue),
            ("CropX", cropX.xmlValue), ("CropY", cropY.xmlValue),
            ("CropWidth", cropWidth.xmlValue), ("CropHeight", cropHeight.xmlValue),
            ("Rotation", "R\(rotation)"), ("HealSize", healSize.xmlValue)
        ]
        for (name, value) in fields {
            values.addChild(XMLElement(name: name, stringValue: value))
        }
        if colorProfileMatrix.count == 9,
           zip(colorProfileMatrix, ColorCheckerProfile.identityMatrix).contains(where: { abs($0 - $1) > 0.000001 }) {
            let profile = XMLElement(name: "ColorProfile")
            for (index, value) in colorProfileMatrix.enumerated() {
                profile.addChild(XMLElement(name: "M\(index / 3)\(index % 3)", stringValue: value.xmlValue))
            }
            values.addChild(profile)
        }
        if !gradients.isEmpty {
            let gradientList = XMLElement(name: "Gradients")
            for gradient in gradients {
                let node = XMLElement(name: "LinearGradient")
                let fields: [(String, String)] = [
                    ("CenterX", gradient.centerX.xmlValue), ("CenterY", gradient.centerY.xmlValue),
                    ("Angle", gradient.angle.xmlValue), ("Range", gradient.range.xmlValue),
                    ("Exposure", gradient.exposure.xmlValue), ("Contrast", gradient.contrast.xmlValue),
                    ("Highlights", gradient.highlights.xmlValue), ("Shadows", gradient.shadows.xmlValue),
                    ("Saturation", gradient.saturation.xmlValue)
                ]
                for (name, value) in fields { node.addChild(XMLElement(name: name, stringValue: value)) }
                gradientList.addChild(node)
            }
            values.addChild(gradientList)
        }
        if !adjustmentBrushes.isEmpty {
            let brushList = XMLElement(name: "AdjustmentBrushes")
            for brush in adjustmentBrushes {
                let node = XMLElement(name: "AdjustmentBrush")
                let fields: [(String, String)] = [
                    ("RadiusNorm", brush.radiusNorm.xmlValue),
                    ("Feather", brush.feather.xmlValue),
                    ("Exposure", brush.exposure.xmlValue),
                    ("Contrast", brush.contrast.xmlValue),
                    ("Highlights", brush.highlights.xmlValue),
                    ("Shadows", brush.shadows.xmlValue),
                    ("Whites", brush.whites.xmlValue),
                    ("Blacks", brush.blacks.xmlValue),
                    ("Temperature", brush.temperature.xmlValue),
                    ("Tint", brush.tint.xmlValue),
                    ("Vibrance", brush.vibrance.xmlValue),
                    ("Saturation", brush.saturation.xmlValue)
                ]
                for (name, value) in fields { node.addChild(XMLElement(name: name, stringValue: value)) }
                let points = XMLElement(name: "Points")
                for point in brush.points {
                    let pointNode = XMLElement(name: "Point")
                    pointNode.addChild(XMLElement(name: "X", stringValue: point.x.xmlValue))
                    pointNode.addChild(XMLElement(name: "Y", stringValue: point.y.xmlValue))
                    points.addChild(pointNode)
                }
                node.addChild(points)
                brushList.addChild(node)
            }
            values.addChild(brushList)
        }
        if !healSpots.isEmpty {
            let spotList = XMLElement(name: "HealSpots")
            for spot in healSpots {
                let node = XMLElement(name: "HealSpot")
                let fields: [(String, String)] = [
                    ("TargetX", spot.targetX.xmlValue), ("TargetY", spot.targetY.xmlValue),
                    ("SourceX", spot.sourceX.xmlValue), ("SourceY", spot.sourceY.xmlValue),
                    ("Radius", spot.radius.xmlValue), ("RadiusNorm", spot.radiusNorm.xmlValue),
                    ("Strength", spot.strength.xmlValue),
                    ("UseInpaint", spot.useInpaint ? "true" : "false")
                ]
                for (name, value) in fields { node.addChild(XMLElement(name: name, stringValue: value)) }
                spotList.addChild(node)
            }
            values.addChild(spotList)
        }
        if let exif = cachedExif {
            let node = XMLElement(name: "Exif")
            let fields: [(String, String)] = [
                ("CameraMake", exif.cameraMake), ("CameraModel", exif.cameraModel),
                ("Lens", exif.lens), ("ISO", exif.iso), ("Aperture", exif.aperture),
                ("Shutter", exif.shutter), ("FocalLength", exif.focalLength),
                ("ExposureBias", exif.exposureBias), ("WhiteBalance", exif.whiteBalance),
                ("MeteringMode", exif.meteringMode), ("FocusMode", exif.focusMode),
                ("ColorTemperature", exif.colorTemperature.xmlValue),
                ("Tint", exif.tint.xmlValue), ("DateTaken", exif.dateTaken),
                ("Width", String(exif.width)), ("Height", String(exif.height)),
                ("FileSize", String(exif.fileSize)), ("FilePath", exif.filePath)
            ]
            for (name, value) in fields { node.addChild(XMLElement(name: name, stringValue: value)) }
            root.addChild(node)
        }
        root.addChild(placeholder)
        root.addChild(values)
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try document.xmlData(options: [.nodePrettyPrint]).write(to: url, options: .atomic)
    }
}

struct LinearGradient: Equatable {
    var centerX = 0.5
    var centerY = 0.15
    var angle = 0.0
    var range = 0.12
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
}

struct AdjustmentBrushPoint: Equatable {
    var x: Double
    var y: Double
}

struct AdjustmentBrush: Equatable {
    var points: [AdjustmentBrushPoint] = []
    var radiusNorm = 0.045
    var feather = 0.65
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0
    var temperature = 5200.0
    var tint = 0.0
    var vibrance = 0.0
    var saturation = 0.0
}

struct HealSpot: Equatable {
    var targetX = 0.0
    var targetY = 0.0
    var sourceX = 0.0
    var sourceY = 0.0
    var radius = 10.0
    var radiusNorm = 0.02
    var strength = 1.0
    var useInpaint = false
}

struct ExifData: Equatable {
    var cameraMake = ""
    var cameraModel = ""
    var lens = ""
    var iso = ""
    var aperture = ""
    var shutter = ""
    var focalLength = ""
    var exposureBias = ""
    var whiteBalance = ""
    var meteringMode = ""
    var focusMode = ""
    var colorTemperature = 0.0
    var tint = 0.0
    var dateTaken = ""
    var width = 0
    var height = 0
    var fileSize: Int64 = 0
    var filePath = ""
}

private extension Double {
    var xmlValue: String { String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), self) }
}

private final class AdjustmentXMLParser: NSObject, XMLParserDelegate {
    var values: [String: Double] = [:]
    var strings: [String: String] = [:]
    var gradients: [LinearGradient] = []
    var adjustmentBrushes: [AdjustmentBrush] = []
    var healSpots: [HealSpot] = []
    var colorProfileMatrix = ColorCheckerProfile.identityMatrix
    var exif: ExifData?
    private var text = ""
    private var currentGradient: LinearGradient?
    private var currentAdjustmentBrush: AdjustmentBrush?
    private var currentBrushPoint: AdjustmentBrushPoint?
    private var currentHealSpot: HealSpot?
    private var currentColorProfile = false
    private var currentExif: ExifData?

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "MorrowRAW", code: 1)
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "LinearGradient" { currentGradient = LinearGradient() }
        if elementName == "AdjustmentBrush" { currentAdjustmentBrush = AdjustmentBrush() }
        if elementName == "Point" { currentBrushPoint = AdjustmentBrushPoint(x: 0, y: 0) }
        if elementName == "HealSpot" { currentHealSpot = HealSpot() }
        if elementName == "ColorProfile" { currentColorProfile = true }
        if elementName == "Exif" { currentExif = ExifData() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isStructuredField = currentGradient != nil || currentAdjustmentBrush != nil ||
            currentBrushPoint != nil || currentHealSpot != nil || currentExif != nil || currentColorProfile
        if var gradient = currentGradient, elementName != "LinearGradient", let number = Double(value) {
            switch elementName {
            case "CenterX": gradient.centerX = number
            case "CenterY": gradient.centerY = number
            case "Angle": gradient.angle = number
            case "Range": gradient.range = number
            case "Exposure": gradient.exposure = number
            case "Contrast": gradient.contrast = number
            case "Highlights": gradient.highlights = number
            case "Shadows": gradient.shadows = number
            case "Saturation": gradient.saturation = number
            default: break
            }
            currentGradient = gradient
        }
        if elementName == "LinearGradient", let gradient = currentGradient {
            gradients.append(gradient)
            currentGradient = nil
        }
        if var point = currentBrushPoint, elementName != "Point", let number = Double(value) {
            switch elementName {
            case "X": point.x = number
            case "Y": point.y = number
            default: break
            }
            currentBrushPoint = point
        }
        if let point = currentBrushPoint, elementName == "Point" {
            currentAdjustmentBrush?.points.append(point)
            currentBrushPoint = nil
        }
        if var brush = currentAdjustmentBrush,
           currentBrushPoint == nil,
           elementName != "AdjustmentBrush",
           elementName != "Point",
           let number = Double(value) {
            switch elementName {
            case "RadiusNorm": brush.radiusNorm = number
            case "Feather": brush.feather = number
            case "Exposure": brush.exposure = number
            case "Contrast": brush.contrast = number
            case "Highlights": brush.highlights = number
            case "Shadows": brush.shadows = number
            case "Whites": brush.whites = number
            case "Blacks": brush.blacks = number
            case "Temperature": brush.temperature = number
            case "Tint": brush.tint = number
            case "Vibrance": brush.vibrance = number
            case "Saturation": brush.saturation = number
            default: break
            }
            currentAdjustmentBrush = brush
        }
        if elementName == "AdjustmentBrush", let brush = currentAdjustmentBrush {
            adjustmentBrushes.append(brush)
            currentAdjustmentBrush = nil
        }
        if var spot = currentHealSpot, elementName != "HealSpot" {
            if let number = Double(value) {
                switch elementName {
                case "TargetX": spot.targetX = number
                case "TargetY": spot.targetY = number
                case "SourceX": spot.sourceX = number
                case "SourceY": spot.sourceY = number
                case "Radius": spot.radius = number
                case "RadiusNorm": spot.radiusNorm = number
                case "Strength": spot.strength = min(1, max(0, number))
                default: break
                }
            } else if elementName == "UseInpaint" { spot.useInpaint = value.lowercased() == "true" }
            currentHealSpot = spot
        }
        if elementName == "HealSpot", let spot = currentHealSpot {
            healSpots.append(spot)
            currentHealSpot = nil
        }
        if currentColorProfile, elementName != "ColorProfile", let number = Double(value),
           elementName.count == 3, elementName.first == "M",
           let row = Int(String(elementName[elementName.index(after: elementName.startIndex)])),
           let column = Int(String(elementName.last!)), row < 3, column < 3 {
            colorProfileMatrix[row * 3 + column] = number
        }
        if elementName == "ColorProfile" { currentColorProfile = false }
        if var exif = currentExif, elementName != "Exif" {
            switch elementName {
            case "CameraMake": exif.cameraMake = value
            case "CameraModel": exif.cameraModel = value
            case "Lens": exif.lens = value
            case "ISO": exif.iso = value
            case "Aperture": exif.aperture = value
            case "Shutter": exif.shutter = value
            case "FocalLength": exif.focalLength = value
            case "ExposureBias": exif.exposureBias = value
            case "WhiteBalance": exif.whiteBalance = value
            case "MeteringMode": exif.meteringMode = value
            case "FocusMode": exif.focusMode = value
            case "ColorTemperature": exif.colorTemperature = Double(value) ?? exif.colorTemperature
            case "Tint": exif.tint = Double(value) ?? exif.tint
            case "DateTaken": exif.dateTaken = value
            case "Width": exif.width = Int(value) ?? exif.width
            case "Height": exif.height = Int(value) ?? exif.height
            case "FileSize": exif.fileSize = Int64(value) ?? exif.fileSize
            case "FilePath": exif.filePath = value
            default: break
            }
            currentExif = exif
        }
        if elementName == "Exif", let exif = currentExif {
            self.exif = exif
            currentExif = nil
        }
        if !isStructuredField && currentExif == nil {
            if let number = Double(value) {
                values[elementName] = number
            } else if !value.isEmpty {
                strings[elementName] = value
            }
        }
        text = ""
    }

    func number(_ key: String, fallback: Double) -> Double { values[key] ?? fallback }
    func text(_ key: String, fallback: String) -> String { strings[key] ?? fallback }
}
