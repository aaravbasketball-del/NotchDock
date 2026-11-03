import AppKit
import SwiftUI

struct TriggerIndicatorView: View {
    @AppStorage("notchdock.fakeNotchEnabled") private var fakeNotchEnabled = false
    @AppStorage("notchdock.fakeNotchStyle") private var fakeNotchStyle = "notch"
    @AppStorage("notchdock.fakeNotchWidth") private var fakeNotchWidth = 180.0
    @AppStorage("notchdock.fakeNotchHeight") private var fakeNotchHeight = 32.0
    @AppStorage("notchdock.fakeNotchOnlyWithoutPhysicalNotch") private var onlyWithoutPhysical = false
    @AppStorage("notchdock.fakeNotchShowCamera") private var showCamera = true
    @AppStorage("notchdock.showTriggerBump") private var showTriggerBump = false

    var hasPhysicalNotch: Bool

    private var fakeNotchActive: Bool {
        fakeNotchEnabled && (!onlyWithoutPhysical || !hasPhysicalNotch)
    }

    var body: some View {
        Group {
            if fakeNotchActive {
                if fakeNotchStyle == "island" {
                    dynamicIslandView
                } else {
                    macBookNotchView
                }
            } else if showTriggerBump {
                triggerBumpView
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var dynamicIslandView: some View {
        ZStack {
            Capsule()
                .fill(Color.black)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)

            if showCamera {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(red: 0.08, green: 0.08, blue: 0.14))
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .fill(Color(red: 0.2, green: 0.35, blue: 0.65).opacity(0.8))
                                .frame(width: 2.8, height: 2.8)
                        )
                        .padding(.leading, 12)
                    Spacer()
                    Circle()
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.08))
                        .frame(width: 5, height: 5)
                        .padding(.trailing, 14)
                }
            }
        }
        .frame(width: CGFloat(fakeNotchWidth), height: CGFloat(fakeNotchHeight))
        .offset(y: 4)
    }

    private var macBookNotchView: some View {
        ZStack(alignment: .top) {
            FakeNotchSilhouette(topRadius: 6, bottomRadius: 10)
                .fill(Color.black)
                .overlay(
                    FakeNotchSilhouette(topRadius: 6, bottomRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

            if showCamera {
                Circle()
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.16))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .fill(Color(red: 0.2, green: 0.35, blue: 0.65).opacity(0.75))
                            .frame(width: 2.5, height: 2.5)
                    )
                    .offset(y: CGFloat(fakeNotchHeight) * 0.44)
            }
        }
        .frame(width: CGFloat(fakeNotchWidth), height: CGFloat(fakeNotchHeight))
    }

    private var triggerBumpView: some View {
        Capsule()
            .fill(Color.black.opacity(0.92))
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(width: 76, height: 14)
            .offset(y: -7)
    }
}

struct FakeNotchSilhouette: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let tr = min(topRadius, min(w / 4, h / 2))
        let br = min(bottomRadius, min((w - 2 * tr) / 2, h - tr))

        path.move(to: CGPoint(x: 0, y: 0))

        // Top-left outward curve: from (0, 0) curving down to (tr, tr)
        path.addArc(
            center: CGPoint(x: 0, y: tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // Left vertical edge down to (tr, h - br)
        path.addLine(to: CGPoint(x: tr, y: h - br))

        // Bottom-left inward curve: from (tr, h - br) to (tr + br, h)
        path.addArc(
            center: CGPoint(x: tr + br, y: h - br),
            radius: br,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )

        // Bottom horizontal edge
        path.addLine(to: CGPoint(x: w - tr - br, y: h))

        // Bottom-right inward curve: from (w - tr - br, h) to (w - tr, h - br)
        path.addArc(
            center: CGPoint(x: w - tr - br, y: h - br),
            radius: br,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )

        // Right vertical edge up to (w - tr, tr)
        path.addLine(to: CGPoint(x: w - tr, y: tr))

        // Top-right outward curve: from (w - tr, tr) curving up and out to (w, 0)
        path.addArc(
            center: CGPoint(x: w, y: tr),
            radius: tr,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        path.addLine(to: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return path
    }
}
