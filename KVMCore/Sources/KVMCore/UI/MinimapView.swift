import SwiftUI

public struct MinimapView<Background: View>: View {
    public static var maxSize: CGFloat { 200 }
    public static var minSize: CGFloat { 80 }

    @ObservedObject private var zoom: ViewerZoomState
    private let background: Background

    public init(zoom: ViewerZoomState, @ViewBuilder background: () -> Background) {
        self.zoom = zoom
        self.background = background()
    }

    public var body: some View {
        if zoom.isZoomed, let size = outerSize {
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                dimOutside(in: size)

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)

                viewportRect(in: size)
                cursorDot(in: size)
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        }
    }

    private var outerSize: CGSize? {
        guard let videoSize = zoom.videoSize, videoSize.width > 0, videoSize.height > 0 else {
            return nil
        }
        let aspect = videoSize.width / videoSize.height
        let width: CGFloat
        let height: CGFloat
        if aspect >= 1 {
            width = Self.maxSize
            height = max(Self.minSize * 0.6, Self.maxSize / aspect)
        } else {
            height = Self.maxSize
            width = max(Self.minSize * 0.6, Self.maxSize * aspect)
        }
        return CGSize(width: width, height: height)
    }

    /// Dims everything *outside* the visible viewport so the live video shows
    /// through the in-view region at full brightness. An even-odd fill of
    /// (full box) ∪ (visible rect) covers only the surrounding area.
    private func dimOutside(in size: CGSize) -> some View {
        let rect = viewportFrame(in: size)
        return Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
    }

    private func viewportRect(in size: CGSize) -> some View {
        let rect = viewportFrame(in: size)
        return Rectangle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func viewportFrame(in size: CGSize) -> CGRect {
        let visible = zoom.visibleRect()
        return CGRect(
            x: visible.minX * size.width,
            y: visible.minY * size.height,
            width: visible.width * size.width,
            height: visible.height * size.height
        )
    }

    @ViewBuilder
    private func cursorDot(in size: CGSize) -> some View {
        if let cursor = zoom.cursorNormalized {
            let diameter: CGFloat = 6
            Circle()
                .fill(Color.yellow)
                .frame(width: diameter, height: diameter)
                .offset(
                    x: cursor.x * size.width - diameter / 2,
                    y: cursor.y * size.height - diameter / 2
                )
        }
    }
}
