import AppKit
import SwiftUI

// MARK: - Metrics capture

/// Measures the scroll events the OS actually delivers (ground truth for
/// what the ScrollEngine produces), plus derived smoothness stats.
final class ScrollMetrics: ObservableObject {
    struct Sample {
        let t: TimeInterval
        let dy: Double
    }

    @Published var velocity: Double = 0 // px/s over last 100ms
    @Published var peakVelocity: Double = 0
    @Published var eventsPerSecond: Double = 0
    @Published var totalDistance: Double = 0
    @Published var reversals: Int = 0
    @Published var jitter: Double = 0 // CV of |dy| while scrolling, lower = smoother
    @Published var history: [Sample] = [] // for the sparkline (last 6s)

    private var samples: [Sample] = []
    private var monitor: Any?
    private var timer: Timer?
    private var lastSign = 0

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.record(dy: event.scrollingDeltaY)
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    func stop() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        samples = []
        history = []
        velocity = 0
        peakVelocity = 0
        eventsPerSecond = 0
        totalDistance = 0
        reversals = 0
        jitter = 0
        lastSign = 0
    }

    private func record(dy: Double) {
        guard dy != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        samples.append(Sample(t: now, dy: dy))
        totalDistance += abs(dy)
        let sign = dy > 0 ? 1 : -1
        if lastSign != 0, sign != lastSign { reversals += 1 }
        lastSign = sign
    }

    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime
        samples.removeAll { now - $0.t > 2.0 }

        let recent = samples.filter { now - $0.t <= 0.1 }
        velocity = recent.reduce(0) { $0 + abs($1.dy) } / 0.1
        peakVelocity = max(peakVelocity, velocity)

        let lastSecond = samples.filter { now - $0.t <= 1.0 }
        eventsPerSecond = Double(lastSecond.count)

        // Smoothness: coefficient of variation of per-event |dy| while moving.
        if lastSecond.count >= 8 {
            let mags = lastSecond.map { abs($0.dy) }
            let mean = mags.reduce(0, +) / Double(mags.count)
            if mean > 0 {
                let variance = mags.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(mags.count)
                jitter = sqrt(variance) / mean
            }
        }

        history.append(Sample(t: now, dy: velocity))
        history.removeAll { now - $0.t > 6.0 }
    }

    var report: String {
        let c = ScrollEngine.shared.config
        return """
        MacDial scroll test report
        --------------------------
        peak velocity: \(Int(peakVelocity)) px/s
        events/sec (last 1s): \(Int(eventsPerSecond))
        total distance: \(Int(totalDistance)) px
        direction reversals: \(reversals)
        jitter (CV, lower is smoother): \(String(format: "%.3f", jitter))

        engine config:
        pixelsPerRevolution: \(String(format: "%.0f", c.pixelsPerRevolution))
        accel: \(String(format: "%.2f", c.accel))
        exponent: \(String(format: "%.2f", c.exponent))
        maxGain: \(String(format: "%.1f", c.maxGain))
        tau: \(String(format: "%.3f", c.tau))
        """
    }
}

// MARK: - Views

struct ScrollTestView: View {
    @StateObject private var metrics = ScrollMetrics()

    var body: some View {
        HStack(spacing: 0) {
            ScrollTargetView()
                .frame(minWidth: 380)
            Divider()
            MetricsPanel(metrics: metrics)
                .frame(width: 340)
        }
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
    }
}

/// Tall ruler content to scroll against.
private struct ScrollTargetView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0 ..< 400, id: \.self) { i in
                    HStack {
                        Text("\(i * 100)")
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 90, alignment: .trailing)
                        Rectangle()
                            .fill(i % 2 == 0 ? Color.primary.opacity(0.06) : Color.clear)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 100)
                    .background(i % 2 == 0 ? Color.primary.opacity(0.04) : Color.clear)
                }
            }
        }
        .overlay(alignment: .top) {
            Text("Point the cursor here and turn the dial")
                .font(.callout)
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
    }
}

private struct MetricsPanel: View {
    @ObservedObject var metrics: ScrollMetrics
    @State private var config = ScrollEngine.shared.config

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live output")
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(metrics.velocity))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("px/s")
                    .foregroundColor(.secondary)
            }

            SparklineView(samples: metrics.history)
                .frame(height: 60)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                statRow("Peak velocity", "\(Int(metrics.peakVelocity)) px/s")
                statRow("Events / sec", "\(Int(metrics.eventsPerSecond))")
                statRow("Total distance", "\(Int(metrics.totalDistance)) px")
                statRow("Reversals", "\(metrics.reversals)")
                statRow("Jitter (lower = smoother)", String(format: "%.3f", metrics.jitter))
            }
            .font(.callout)

            Divider()

            Text("Feel tuning")
                .font(.headline)

            tuning("Pixels / revolution", value: $config.pixelsPerRevolution, in: 100 ... 1200, format: "%.0f")
            tuning("Acceleration", value: $config.accel, in: 0 ... 8, format: "%.2f")
            tuning("Curve exponent", value: $config.exponent, in: 1 ... 2.2, format: "%.2f")
            tuning("Max gain", value: $config.maxGain, in: 2 ... 20, format: "%.1f")
            tuning("Smoothing τ (s)", value: $config.tau, in: 0.01 ... 0.15, format: "%.3f")

            HStack {
                Button("Reset stats") { metrics.reset() }
                Button("Reset tuning") {
                    config = ScrollEngine.Config()
                    apply()
                }
                Spacer()
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(metrics.report, forType: .string)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundColor(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func tuning(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range) { _ in apply() }
        }
    }

    private func apply() {
        let c = config
        ScrollEngine.shared.updateConfig { $0 = c }
    }
}

private struct SparklineView: View {
    let samples: [ScrollMetrics.Sample]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let t0 = samples.first!.t
            let t1 = max(samples.last!.t, t0 + 0.001)
            let maxV = max(samples.map(\.dy).max() ?? 1, 1)
            var path = Path()
            for (i, s) in samples.enumerated() {
                let x = (s.t - t0) / (t1 - t0) * size.width
                let y = size.height - (s.dy / maxV) * (size.height - 4)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Window plumbing

final class ScrollTestPanel {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered,
                             defer: false)
            w.title = "Scroll Test"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ScrollTestView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
