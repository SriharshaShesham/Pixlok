import Foundation
import CoreGraphics

/// Non-destructive description of an edit. All values are neutral at their defaults.
/// Order of application (ImageEditPipeline): EXIF orientation → colour/light adjustments →
/// sharpness → rotationQuarterTurns → flips → straighten (rotate + scale-to-fill, no empty corners) → crop.
struct EditRecipe: Equatable, Codable {
    // Light
    var exposure: Double = 0      // EV stops, -3 ... 3          (CIExposureAdjust)
    var brightness: Double = 0    // -1 ... 1  (UI shows -100…100) (CIColorControls brightness, scaled)
    var contrast: Double = 0      // -1 ... 1                       (CIColorControls contrast 1+x*0.5 or similar)
    var highlights: Double = 0    // -1 ... 1                       (CIHighlightShadowAdjust)
    var shadows: Double = 0       // -1 ... 1                       (CIHighlightShadowAdjust)
    // Colour
    var saturation: Double = 0    // -1 ... 1  (-1 = greyscale)
    var vibrance: Double = 0      // -1 ... 1                       (CIVibrance)
    var temperature: Double = 0   // -1 ... 1  (-1 cooler, +1 warmer) (CITemperatureAndTint)
    var tint: Double = 0          // -1 ... 1  (-1 green, +1 magenta)
    // Detail
    var sharpness: Double = 0     // 0 ... 1                         (CISharpenLuminance)
    // Geometry
    var rotationQuarterTurns: Int = 0   // clockwise, 0...3
    var flipHorizontal = false
    var flipVertical = false
    var straighten: Double = 0          // degrees, -45 ... 45 (positive = clockwise)
    /// Crop rectangle, normalized 0...1 in the image AFTER rotation/flip/straighten,
    /// origin at TOP-LEFT (UI coordinates). nil = no crop.
    var crop: CGRect? = nil

    static let identity = EditRecipe()
    var isIdentity: Bool { self == .identity }

    var hasGeometryChange: Bool {
        rotationQuarterTurns % 4 != 0 || flipHorizontal || flipVertical || straighten != 0 || crop != nil
    }
}

/// Crop aspect presets shown in the edit panel.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        }
    }
    /// width / height, or nil for free. `original` resolved by caller from image size.
    var ratio: CGFloat? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        }
    }
}
