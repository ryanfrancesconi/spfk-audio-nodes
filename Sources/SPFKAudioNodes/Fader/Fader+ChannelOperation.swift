// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes

import AVFoundation
import SPFKAudioBase

extension Fader {
    /// The channel parameters as one operation. A mono operation plays the same signal on both
    /// sides.
    public var channelOperation: ChannelOperation {
        get {
            if mixToMono {
                switch Int(monoSource.rounded()) {
                case 1: return .mono(.left)
                case 2: return .mono(.right)
                default: return .mono(.average)
                }
            }
            if midSideDecode { return .midSideDecode(width: midSideWidth) }
            if midSideEncode { return .midSideEncode }
            if flipStereo { return .swap }
            return .none
        }
        set {
            var mono = false
            var decode = false
            var encode = false
            var swap = false

            switch newValue {
            case .none:
                break
            case .swap:
                swap = true
            case let .mono(source):
                mono = true
                monoSource = switch source {
                case .average: 0
                case .left: 1
                case .right: 2
                }
            case let .midSideDecode(width):
                decode = true
                let range = ChannelOperation.widthRange
                midSideWidth = min(max(width, range.lowerBound), range.upperBound)
            case .midSideEncode:
                encode = true
            }

            mixToMono = mono
            midSideDecode = decode
            midSideEncode = encode
            flipStereo = swap
        }
    }
}
