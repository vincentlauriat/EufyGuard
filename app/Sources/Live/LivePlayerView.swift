import SwiftUI
import AVFoundation
import CoreMedia

/// NSView hosting the hardware-decoding AVSampleBufferDisplayLayer.
final class PlayerNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supporté") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func enqueue(_ sample: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }
}

struct VideoSurface: NSViewRepresentable {
    @ObservedObject var controller: LiveStreamController

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView(frame: .zero)
        controller.decoder.onSample = { [weak view, weak controller] sample in
            DispatchQueue.main.async {
                view?.enqueue(sample)
                controller?.markSampleDisplayed()
            }
        }
        return view
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {}
}

/// Full live view presented when clicking a camera card.
struct CameraLiveView: View {
    let device: DeviceInfo
    @EnvironmentObject private var client: BridgeClient
    @StateObject private var controller = LiveStreamController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(device.name, systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                if controller.state == .playing {
                    Text("EN DIRECT")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            ZStack(alignment: .bottomLeading) {
                VideoSurface(controller: controller)
                if device.isPTZ, controller.state == .playing {
                    PTZPad { direction in
                        Task { await client.panTilt(device: device, direction: direction) }
                    }
                    .padding(16)
                }
                switch controller.state {
                case .connecting:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Connexion au flux P2P…")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                case .error(let message):
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                        Text(message)
                            .multilineTextAlignment(.center)
                        Button("Réessayer") {
                            controller.disconnect()
                            controller.connect(serial: device.serial)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding()
                case .playing:
                    EmptyView()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(.black)
        .onAppear { controller.connect(serial: device.serial) }
        .onDisappear { controller.disconnect() }
    }
}

/// Directional pad overlay to steer motorized (pan/tilt) cameras.
/// Arrow keys work too; R triggers a 360° sweep.
struct PTZPad: View {
    let action: (String) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ptzButton("chevron.up", direction: "up", key: .upArrow)
            HStack(spacing: 4) {
                ptzButton("chevron.left", direction: "left", key: .leftArrow)
                ptzButton("arrow.trianglehead.2.clockwise.rotate.90", direction: "rotate360", key: KeyEquivalent("r"))
                    .help("Tour complet (360°)")
                ptzButton("chevron.right", direction: "right", key: .rightArrow)
            }
            ptzButton("chevron.down", direction: "down", key: .downArrow)
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func ptzButton(_ icon: String, direction: String, key: KeyEquivalent) -> some View {
        Button {
            action(direction)
        } label: {
            Image(systemName: icon)
                .font(.title3.bold())
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.15), in: Circle())
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
    }
}
