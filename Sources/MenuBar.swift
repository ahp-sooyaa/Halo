import AppKit
import SwiftUI

enum MenuBarIcon {
    static let idle = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Halo")

    /// A ring that fills clockwise from 12 o'clock. Template image, so it follows the menu bar's colour.
    static func progress(_ fraction: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2.5, dy: 2.5)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.03, min(1, fraction))), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Halo: \(Int(fraction * 100))% done"
        return image
    }
}

/// One job in the menu bar menu; updates live while the menu is open.
struct JobRow: View {
    static let width: CGFloat = 300
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon
                Text(job.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if job.isActive {
                    Button("Cancel") { job.cancel() }
                        .controlSize(.small)
                } else if !job.outputs.isEmpty {
                    Button("Show") { job.revealOutputs() }
                        .controlSize(.small)
                }
            }
            if job.isActive {
                ProgressView(value: job.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .help(job.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .finished:
            Image(systemName: job.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(job.failures.isEmpty ? .green : .orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        let failed = job.failures.isEmpty ? "" : " · \(job.failures.count) failed"
        switch job.state {
        case .queued: return "Waiting · \(job.inputs.count) \(job.inputs.count == 1 ? "image" : "images")"
        case .running: return "\(job.completed) of \(job.total)" + failed
        case .finished, .cancelled: return Notifier.summary(for: job)
        }
    }
}
