// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-audio-nodes
// Heavily based on the AudioKit version. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

import AVFoundation
import SPFKAudioBase

extension AVAudioUnit {
    public static func instantiateLocal(
        with componentDescription: AudioComponentDescription,
        named name: String? = nil,
        version: UInt32? = nil
    ) async throws -> AVAudioUnit {
        //
        AUAudioUnit.registerSubclass(
            SPFKAudioUnit.self,
            as: componentDescription,
            name: name ?? "SPFK AU",
            version: version ?? 1
        )

        #if os(macOS)
            let options: AudioComponentInstantiationOptions = .loadInProcess
        #else
            let options: AudioComponentInstantiationOptions = []
        #endif

        let avAudioUnit = try await instantiate(
            with: componentDescription,
            options: options
        )

        if let localAU = avAudioUnit.auAudioUnit as? SPFKAudioUnit {
            try await localAU.update(format: AudioDefaults.shared.systemFormat)
        }

        return avAudioUnit
    }
}
