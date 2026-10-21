import SwiftUI

/// Shared analytical geometry keeps the artwork, detents and hit projection on
/// one circle. Artwork joins can soften without moving the thumb or hit targets.
struct ComposerThinkingArcGeometry {
    let size: CGSize
    var inset: CGFloat = 30
    private var halfWidth: CGFloat { max(1, (size.width - 2 * inset) / 2) }
    private var rise: CGFloat { min(min(66, halfWidth * 0.62), max(2, size.height - 2 * inset)) }
    private var radius: CGFloat { (halfWidth * halfWidth + rise * rise) / (2 * rise) }
    private var center: CGPoint {
        CGPoint(x: size.width / 2, y: size.height - inset + radius - rise)
    }
    private var halfAngle: Double { asin(Double(halfWidth / radius)) }
    private var startAngle: Double { -.pi / 2 - halfAngle }

    func point(at fraction: Double) -> CGPoint {
        let angle = startAngle + 2 * halfAngle * fraction
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                       y: center.y + radius * CGFloat(sin(angle)))
    }

    func fraction(at point: CGPoint) -> Double {
        min(1, max(0, projectedFraction(at: point)))
    }

    func projectedFraction(at point: CGPoint) -> Double {
        let angle = atan2(Double(point.y - center.y), Double(point.x - center.x))
        return (angle - startAngle) / (2 * halfAngle)
    }

    func path(to fraction: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .radians(startAngle),
                    endAngle: .radians(startAngle + 2 * halfAngle * fraction), clockwise: false)
        return path
    }
    /// Replace each abrupt curvature change between rail and semicircle with
    /// a short Hermite blend. The circular middle and cap tips remain exact.
    func band(to fraction: Double, thickness: CGFloat) -> Path {
        let half = thickness / 2
        let end = startAngle + 2 * halfAngle * fraction
        let startCenter = point(at: 0)
        let endCenter = point(at: fraction)
        if fraction <= 0 {
            return Path(ellipseIn: CGRect(x: startCenter.x - half, y: startCenter.y - half,
                                         width: thickness, height: thickness))
        }
        let outer = radius + half
        let inner = max(1, radius - half)
        // Keep adjacent blends apart as the selected segment grows from zero.
        let trim = min(half * 0.6, inner * CGFloat(end - startAngle) * 0.24)
        if trim < 0.0001 {
            return path(to: fraction).strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
        }
        let outerTrim = Double(trim / outer)
        let innerTrim = Double(trim / inner)
        let capTrim = Double(trim / half)
        func sample(_ origin: CGPoint, _ r: CGFloat, _ angle: Double, _ direction: CGFloat = 1) -> ArcSample {
            let x = CGFloat(cos(angle)), y = CGFloat(sin(angle))
            return ArcSample(point: CGPoint(x: origin.x + r * x, y: origin.y + r * y),
                             tangent: CGPoint(x: -y * direction, y: x * direction),
                             curvature: CGPoint(x: -x / r, y: -y / r))
        }
        var outline = Path()
        let first = sample(center, outer, startAngle + outerTrim)
        outline.move(to: first.point)
        outline.addArc(center: center, radius: outer, startAngle: .radians(startAngle + outerTrim),
                       endAngle: .radians(end - outerTrim), clockwise: false)
        Self.blend(&outline, from: sample(center, outer, end - outerTrim),
                   to: sample(endCenter, half, end + capTrim), length: 2 * trim)
        outline.addArc(center: endCenter, radius: half, startAngle: .radians(end + capTrim),
                       endAngle: .radians(end + .pi - capTrim), clockwise: false)
        Self.blend(&outline, from: sample(endCenter, half, end + .pi - capTrim),
                   to: sample(center, inner, end - innerTrim, -1), length: 2 * trim)
        outline.addArc(center: center, radius: inner, startAngle: .radians(end - innerTrim),
                       endAngle: .radians(startAngle + innerTrim), clockwise: true)
        Self.blend(&outline, from: sample(center, inner, startAngle + innerTrim, -1),
                   to: sample(startCenter, half, startAngle + .pi + capTrim), length: 2 * trim)
        outline.addArc(center: startCenter, radius: half, startAngle: .radians(startAngle + .pi + capTrim),
                       endAngle: .radians(startAngle + 2 * .pi - capTrim), clockwise: false)
        Self.blend(&outline, from: sample(startCenter, half, startAngle + 2 * .pi - capTrim),
                   to: first, length: 2 * trim)
        outline.closeSubpath()
        return outline
    }

    private struct ArcSample {
        let point: CGPoint
        let tangent: CGPoint
        let curvature: CGPoint
    }

    /// Quintic endpoint constraints carry position, tangent and curvature from
    /// both circles. Four native cubic segments approximate the blend smoothly;
    /// using lines here would introduce facets at device scale.
    private static func blend(_ path: inout Path, from start: ArcSample, to end: ArcSample, length: CGFloat) {
        func coefficients(_ p: CGFloat, _ q: CGFloat, _ v: CGFloat, _ w: CGFloat,
                          _ a: CGFloat, _ b: CGFloat) -> [CGFloat] {
            let c1 = v * length, c2 = a * length * length / 2
            let d0 = q - p - c1 - c2
            let d1 = w * length - c1 - 2 * c2
            let d2 = b * length * length - 2 * c2
            return [p, c1, c2, 10 * d0 - 4 * d1 + d2 / 2,
                    -15 * d0 + 7 * d1 - d2, 6 * d0 - 3 * d1 + d2 / 2]
        }
        let x = coefficients(start.point.x, end.point.x, start.tangent.x, end.tangent.x,
                             start.curvature.x, end.curvature.x)
        let y = coefficients(start.point.y, end.point.y, start.tangent.y, end.tangent.y,
                             start.curvature.y, end.curvature.y)
        func value(_ c: [CGFloat], _ t: CGFloat) -> CGFloat {
            c[0] + t * (c[1] + t * (c[2] + t * (c[3] + t * (c[4] + t * c[5]))))
        }
        func slope(_ c: [CGFloat], _ t: CGFloat) -> CGFloat {
            c[1] + t * (2 * c[2] + t * (3 * c[3] + t * (4 * c[4] + t * 5 * c[5])))
        }
        let step: CGFloat = 0.25
        for index in 0..<4 {
            let a = CGFloat(index) * step, b = a + step
            path.addCurve(to: CGPoint(x: value(x, b), y: value(y, b)),
                          control1: CGPoint(x: value(x, a) + slope(x, a) * step / 3,
                                            y: value(y, a) + slope(y, a) * step / 3),
                          control2: CGPoint(x: value(x, b) - slope(x, b) * step / 3,
                                            y: value(y, b) - slope(y, b) * step / 3))
        }
    }
}

