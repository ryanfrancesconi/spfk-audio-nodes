# SPFKAudioNodes

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-audio-nodes)](https://github.com/ryanfrancesconi/spfk-audio-nodes/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)

Audio node types, parameter automation, file playback, metronome, and offline rendering for macOS and iOS.

Extracted from [SPFKAudioWorkspace](https://github.com/ryanfrancesconi/spfk-audio-workspace) to separate reusable node-level components from engine/workspace management.

## Features

- **Stereo Fader** - Custom audio unit with independent left/right gain, stereo flip, mono mixdown, dB conversion, and parameter automation
- **Parameter System** - `NodeParameter` wrapping `AUParameter` with safe optional access, value clamping, ramping, and automation recording
- **Automation** - Cubic spline interpolation curves, editable automation points with gain/dB conversion, and region fade descriptions
- **File Playback** - Single-file player with editable playback ranges, sample-accurate scheduling, and host-time or sample-time modes
- **Stream Playback** - Buffer-queue player for containers `AVAudioFile` cannot open, fed by an external decoder with backpressure and prefill
- **Source Abstraction** - `TransportSourcePlayer`, the surface a transport drives whether the audio came from a file or a stream
- **Metronome** - Beat/bar/subdivision click player with configurable sound sets and mute support
- **Offline Rendering** - Actor-based `EngineRenderer` for bouncing audio engine graphs to files in manual rendering mode
- **Track Model** - `AudioTrack` with mixer, audio unit chain, and connect/detach lifecycle
- **Mixer** - `MixerWrapper` around `AVAudioMixerNode` with volume and pan control

## Usage

### Fader

```swift
import SPFKAudioNodes

let fader = try await Fader(gain: 0.8)
fader.dB = -6              // set gain in dB
fader.leftGain = 0.5       // independent channel control
fader.flipStereo = true    // swap L/R
```

### File Playback

```swift
let player = try FilePlayer()
try player.load(url: audioFileURL)
try player.schedule(from: 1.0, to: 3.0)  // play seconds 1-3
try player.play()
```

### Stream Playback

For a container `AVAudioFile` cannot open — Matroska, chiefly. `StreamPlayer` takes any
`SeekablePCMSource` and keeps the node's queue fed from it, so the decoder lives in whichever
package owns the container rather than here.

```swift
let player = StreamPlayer()
try player.load(source: decoder, url: url, duration: duration)

try await player.schedule(from: 1.0, to: 3.0, when: 0, hostTime: nil, onComplete: nil)
try player.play()
```

`schedule` is `async` here and synchronous on `FilePlayer`: a file is armed by handing the node a
segment, whereas a stream has to decode before there is anything to hand over. Starting the node
before that has happened plays an empty queue.

### Looping either source

`enqueueRepeat` queues a pass after whatever is already scheduled. `AVAudioPlayerNode` plays a
command with no time immediately after the last one, so neither player times anything against a
clock — which is also why this works in manual rendering mode, where host time is ignored.

```swift
try player.enqueueRepeat(from: loopStart, to: loopEnd, onComplete: nil)
```

The range is stated rather than reused from the current run, because playback can begin inside a
loop and that first partial pass is not what repeats.

### Offline Rendering

```swift
let renderer = EngineRenderer(engineManager: engineManager)
try await renderer.write(
    to: outputURL,
    duration: duration,
    options: EngineRendererOptions(sampleRate: 44100, bitDepth: 24)
)
```

## Dependencies

- **SPFKAudioBase** - Audio type definitions and format utilities
- **SPFKAUHost** - Audio unit hosting and component discovery
- **SPFKUtils** - General extensions (AUValue dB conversion, etc.)
- **SPFKAudioNodesC** - C/C++ companion target for DSP kernels and parameter automation render observers

## Requirements

- **Platforms:** macOS 13+, iOS 16+
- **Swift:** 6.2+

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
