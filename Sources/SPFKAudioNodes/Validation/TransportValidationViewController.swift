// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

#if os(macOS)
    import AppKit
    import AudioToolbox
    import SPFKUtils

    /// Inspector panel that displays the `TransportSnapshot` captured by a `TransportValidationAU`.
    /// Refreshes at ~10 fps, vsync-aligned via `DisplayLinkTimer`.
    @available(macOS 14, *)
    public final class TransportValidationViewController: NSViewController {
        public static let contentSize = NSSize(width: 400, height: 265)

        private weak var validationAU: TransportValidationAU?
        private var displayLink: DisplayLinkTimer?
        private var lastRefreshTime: CFTimeInterval = 0
        private let refreshInterval: CFTimeInterval = 0.1 // 10 fps
        private var valueFields: [NSTextField] = []

        public init(validationAU: TransportValidationAU) {
            self.validationAU = validationAU
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            assertionFailure("Unimplemented")
        }

        override public func loadView() {
            let root = FlippedView(frame: NSRect(origin: .zero, size: Self.contentSize))
            view = root
            buildViews(in: root)
        }

        override public func viewDidAppear() {
            super.viewDidAppear()
            displayLink = DisplayLinkTimer(on: view)
            displayLink?.eventHandler = { [weak self] in
                self?.handleDisplayLink()
            }
            displayLink?.resume()
        }

        override public func viewDidDisappear() {
            super.viewDidDisappear()
            displayLink?.dispose()
            displayLink = nil
        }

        // MARK: - Layout

        private func buildViews(in parent: NSView) {
            let rows: [(label: String, placeholder: String)] = [
                ("Tempo", "0.00"),
                ("Time Signature", "0 / 0"),
                ("Beat Position", "0.000"),
                ("Measure Downbeat", "0.000"),
                ("Sample Offset / Beat", "0"),
                ("Transport Flags", "(none)"),
                ("Sample Position", "0"),
                ("Cycle Start", "0.000"),
                ("Cycle End", "0.000"),
            ]

            // Extra gap before the transport state group (after row 4)
            let groupBreakAfter = 4

            let labelX: CGFloat = 12
            let labelW: CGFloat = 168
            let valueX: CGFloat = 188
            let valueW: CGFloat = 200
            let rowH: CGFloat = 22
            let rowStride: CGFloat = 26
            let groupGap: CGFloat = 8
            let topPad: CGFloat = 12

            var y = topPad

            for (i, row) in rows.enumerated() {
                if i == groupBreakAfter + 1 {
                    let sep = NSBox(frame: NSRect(x: labelX, y: y, width: labelW + 8 + valueW, height: 8))
                    sep.boxType = .separator
                    parent.addSubview(sep)
                    y += groupGap
                }

                let labelField = makeLabel(row.label, frame: NSRect(x: labelX, y: y, width: labelW, height: rowH))
                let valueField = makeValue(row.placeholder, frame: NSRect(x: valueX, y: y, width: valueW, height: rowH))
                parent.addSubview(labelField)
                parent.addSubview(valueField)
                valueFields.append(valueField)

                y += rowStride
            }
        }

        private func makeLabel(_ text: String, frame: NSRect) -> NSTextField {
            let field = NSTextField(frame: frame)
            field.stringValue = text
            field.alignment = .right
            field.font = .systemFont(ofSize: 11, weight: .medium)
            field.textColor = .secondaryLabelColor
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            field.drawsBackground = false
            return field
        }

        private func makeValue(_ placeholder: String, frame: NSRect) -> NSTextField {
            let field = NSTextField(frame: frame)
            field.stringValue = placeholder
            field.alignment = .left
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .labelColor
            field.isEditable = false
            field.isSelectable = false
            field.isBordered = false
            field.drawsBackground = false
            return field
        }

        // MARK: - Refresh

        private func handleDisplayLink() {
            guard let link = displayLink else { return }
            guard link.timestamp - lastRefreshTime >= refreshInterval else { return }
            lastRefreshTime = link.timestamp
            refresh()
        }

        private func refresh() {
            guard let snap = validationAU?.snapshot else { return }

            let timeSig = "\(Int(snap.timeSignatureNumerator)) / \(snap.timeSignatureDenominator)"

            let values: [String] = [
                String(format: "%.2f bpm", snap.currentTempo),
                timeSig,
                String(format: "%.3f", snap.currentBeatPosition),
                String(format: "%.3f", snap.currentMeasureDownbeatPosition),
                "\(snap.sampleOffsetToNextBeat)",
                flagsDescription(snap.transportFlags),
                String(format: "%.0f", snap.currentSamplePosition),
                String(format: "%.3f", snap.cycleStartBeatPosition),
                String(format: "%.3f", snap.cycleEndBeatPosition),
            ]

            for (field, value) in zip(valueFields, values) {
                field.stringValue = value
            }
        }

        private func flagsDescription(_ flags: AUHostTransportStateFlags) -> String {
            if flags.isEmpty { return "(none)" }
            var parts: [String] = []
            if flags.contains(.moving) { parts.append("moving") }
            if flags.contains(.recording) { parts.append("recording") }
            if flags.contains(.cycling) { parts.append("cycling") }
            if parts.isEmpty { parts.append("0x\(String(flags.rawValue, radix: 16))") }
            return parts.joined(separator: " | ")
        }
    }

    // MARK: -

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
#endif
