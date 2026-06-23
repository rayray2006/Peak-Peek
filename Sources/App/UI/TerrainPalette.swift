import Foundation
import UIKit

/// Grayscale relief palette. (Ported from RidgeLine.)
enum TerrainPalette {
    /// Distance band upper edges in meters (band per fill layer, far -> near ordering).
    static let bandUpperEdges: [Double] = [3_000, 9_000, 22_000, 55_000, 110_000, .infinity]
    static var bandCount: Int { bandUpperEdges.count }

    /// Quantization of hillshade [0,1] into discrete tone steps per distance band.
    static let shadeSteps = 7

    static func bandIndex(forDistanceMeters d: Double) -> Int {
        for (i, edge) in bandUpperEdges.enumerated() where d <= edge { return i }
        return bandUpperEdges.count - 1
    }

    static func shadeStep(forShade shade: Double) -> Int {
        min(shadeSteps - 1, max(0, Int(shade * Double(shadeSteps))))
    }

    static func grayColor(band: Int, shadeStep: Int) -> UIColor {
        let s = Double(shadeStep) / Double(max(1, shadeSteps - 1))
        let litGray = 0.20 + 0.74 * s
        let haze = pow(Double(band) / Double(max(1, bandCount - 1)), 1.4)
        let gray = litGray * (1 - 0.62 * haze) + 0.95 * (0.62 * haze)
        return UIColor(white: CGFloat(gray), alpha: 1.0)
    }

    static let skyTop = TopoStyle.background
    static let skyHorizon = TopoStyle.background
    static let strokeInk = UIColor(white: 0.10, alpha: 1.0)
}
