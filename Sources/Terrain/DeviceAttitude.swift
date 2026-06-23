import simd

/// Maps a Core Motion `CMAttitude.rotationMatrix` to the raymarcher's camera
/// basis (`forward`/`right`/`up`) in the world's local ENU frame
/// (x=east, y=north, z=up) — so turning the phone looks around the baked
/// panorama, with full roll.
///
/// ## Derivation
/// Started from CoreMotion with a `*ZVertical` reference frame whose Z axis is
/// vertical and X axis points north — i.e. reference axes (N, W, U) (Y=West
/// completes the right-handed set). With that frame, `M`'s ROWS are the device
/// body axes expressed in the reference frame (body: x=right, y=top,
/// z=toward-viewer):
///
///   device-right          = (m11, m12, m13)   in (N, W, U)
///   device-top            = (m21, m22, m23)   in (N, W, U)
///   device-toward-viewer  = (m31, m32, m33)   in (N, W, U)
///
/// The rear-camera look direction is *away* from the viewer, so
/// `forward = -device-toward-viewer`. Relabel a reference vector
/// (a,b,c) = a·North + b·West + c·Up into ENU (east, north, up):
/// East = -b (west = -east), North = a, Up = c  →  (a,b,c) ↦ (-b, a, c). Hence:
///
///   forward = (m32, -m31, -m33)
///   right   = (-m12,  m11,  m13)
///   up      = (-m22,  m21,  m23)
///
/// ## Provenance
/// This is the same device-verified rotation as PeakPeek's `AttitudeMapping`
/// (whose world is SceneKit East/Up/South); these formulas reproduce its
/// columns exactly under the documented SceneKit→ENU relabel, cross-checked via
/// the independent NWU derivation above.
///
/// ⚠️ Motion sign conventions CANNOT be validated in the simulator — verify
/// "looking around" on a physical device before trusting these. Do not flip
/// signs to match theory without a device in hand.
enum DeviceAttitude {
    struct Basis {
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    static func cameraBasis(
        m11: Double, m12: Double, m13: Double,
        m21: Double, m22: Double, m23: Double,
        m31: Double, m32: Double, m33: Double
    ) -> Basis {
        let forward = normalize(SIMD3<Float>(Float(m32), Float(-m31), Float(-m33)))
        let right   = normalize(SIMD3<Float>(Float(-m12), Float(m11), Float(m13)))
        let up      = normalize(SIMD3<Float>(Float(-m22), Float(m21), Float(m23)))
        return Basis(forward: forward, right: right, up: up)
    }
}
