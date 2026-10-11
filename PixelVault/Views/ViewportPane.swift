import AppKit
import SwiftUI

/// A pannable, zoomable window onto the image. Every pane reads and writes the model's one
/// `Viewport`, so panes shown together stay locked to the same region.
///
/// `content` receives the image's frame in pane coordinates and the pane size, and draws
/// whatever belongs there.
struct ViewportPane<Content: View>: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @ViewBuilder var content: (_ imageFrame: CGRect, _ paneSize: CGSize) -> Content

    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = model.viewport.imageFrame(in: size)

            ZStack(alignment: .topLeading) {
                content(frame, size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture)
            .onTapGesture(count: 2) { toggleZoom() }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in select(at: tap.location, in: size) })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hover(at: location, in: size)
                case .ended: model.hover = nil
                }
            }
            .background {
                ViewportEventMonitor { event in handle(event, in: size) }
            }
            .onChange(of: size, initial: true) { model.viewport.update(imageSize: model.imagePixelSize, paneSize: size) }
            .onChange(of: model.imagePixelSize) { model.viewport.update(imageSize: model.imagePixelSize, paneSize: size) }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let step = CGSize(width: value.translation.width - lastDragTranslation.width,
                                  height: value.translation.height - lastDragTranslation.height)
                lastDragTranslation = value.translation
                model.viewport.pan(by: step)
            }
            .onEnded { _ in lastDragTranslation = .zero }
    }

    /// Double-click flips between fitting the window and one image pixel per screen pixel.
    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.22)) {
            if model.viewport.isFitted {
                model.viewport.setScale(1 / displayScale)
            } else {
                model.viewport.fit()
            }
        }
    }

    private func imagePixel(at location: CGPoint, in size: CGSize) -> (x: Int, y: Int)? {
        let point = model.viewport.imagePoint(at: location, in: size)
        let imageSize = model.imagePixelSize
        guard point.x >= 0, point.y >= 0, point.x < imageSize.width, point.y < imageSize.height else { return nil }
        return (Int(point.x), Int(point.y))
    }

    private func hover(at location: CGPoint, in size: CGSize) {
        let pixel = imagePixel(at: location, in: size)
        let hover = pixel.map { VaultModel.Hover(x: $0.x, y: $0.y) }
        if model.hover != hover { model.hover = hover }
    }

    private func select(at location: CGPoint, in size: CGSize) {
        guard model.result != nil, let pixel = imagePixel(at: location, in: size) else { return }
        model.selectPattern(atImageX: pixel.x, y: pixel.y)
    }

    private func handle(_ event: ViewportEventMonitor.Event, in size: CGSize) {
        let anchor = CGSize(width: event.location.x - size.width / 2, height: event.location.y - size.height / 2)
        switch event.kind {
        case .scroll(let delta):
            model.viewport.pan(by: delta)
        case .zoom(let factor):
            model.viewport.zoom(by: factor, anchor: anchor)
        }
    }
}

/// Feeds trackpad and mouse-wheel input to a pane. SwiftUI has no scroll-wheel gesture, so
/// this watches the window's events and claims those that land inside its own bounds.
struct ViewportEventMonitor: NSViewRepresentable {
    struct Event {
        enum Kind {
            /// Two-finger scroll: move the image by this many points.
            case scroll(CGSize)
            /// Pinch, mouse wheel, or ⌘-scroll: multiply the zoom by this factor.
            case zoom(CGFloat)
        }

        var kind: Kind
        /// Pointer position in the pane, top-left origin.
        var location: CGPoint
    }

    var handler: (Event) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }

    final class MonitorView: NSView {
        var handler: ((Event) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        // Never take clicks: the SwiftUI content in front owns those.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // AppKit calls this with a nil window when the view is torn down, which is where
        // the monitor is released.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // AppKit delivers local monitor callbacks on the main thread.
                MainActor.assumeIsolated { self?.consume(event) ?? false } ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true when the event was inside this pane and has been handled.
        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil else { return false }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return false }

            switch event.type {
            case .magnify:
                handler?(Event(kind: .zoom(1 + event.magnification), location: location))
            case .scrollWheel:
                if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
                    // A wheel notch or ⌘-scroll zooms; scale precise deltas down to match.
                    let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
                    handler?(Event(kind: .zoom(exp(amount)), location: location))
                } else {
                    handler?(Event(kind: .scroll(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)),
                                   location: location))
                }
            default:
                return false
            }
            return true
        }
    }
}
