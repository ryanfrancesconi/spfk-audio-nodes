# SPFKAudioNodes

Audio node types, parameter automation, file playback, metronome, and offline rendering for macOS and iOS.

Extracted from [SPFKAudioWorkspace](https://github.com/ryanfrancesconi/spfk-audio-workspace) to separate reusable node-level components from engine/workspace management.

## Features

- **Stereo Fader** - Custom audio unit with independent left/right gain, stereo flip, mono mixdown, dB conversion, and parameter automation
- **Parameter System** - `NodeParameter` wrapping `AUParameter` with safe optional access, value clamping, ramping, and automation recording
- **Automation** - Cubic spline interpolation curves, editable automation points with gain/dB conversion, and region fade descriptions
- **File Playback** - Single-file player with editable playback ranges, sample-accurate scheduling, and host-time or sample-time modes
- **Metronome** - Beat/bar/subdivision click player with configurable sound sets and mute support
- **Offline Rendering** - Actor-based `EngineRenderer` for bouncing audio engine graphs to files in manual rendering mode
- **Track Model** - `AudioTrack` with mixer, audio unit chain, and connect/detach lifecycle
- **Mixer** - `MixerWrapper` around `AVAudioMixerNode` with volume and pan control

## Architecture

```
SPFKAudioNodes
  |-- AudioUnit/               AUAudioUnit infrastructure
  |   |-- AudioEngineNodeAU    Protocol for AU-backed engine nodes
  |   |-- Internals/           SPFKAudioUnit base class, AU extensions
  |
  |-- Parameters/              Parameter system
  |   |-- NodeParameter        AUParameter wrapper with safe access and ramping
  |   |-- Parameter            Property wrapper for NodeParameter values
  |   |-- NodeParameterDef     Parameter specification (address, range, unit)
  |
  |-- Automation/              Parameter automation curves
  |   |-- AutomationCurve      Cubic spline interpolated gain curves
  |   |-- AutomationPoint      Editable point with gain/dB and UI position
  |   |-- RegionFadeDescription Fade-in/out region descriptors
  |
  |-- Fader/                   Stereo fader DSP node
  |   |-- Fader                Stereo gain AU with parameter automation
  |   |-- FaderParameter+      Parameter definitions and C bridge
  |
  |-- Players/                 Audio playback nodes
  |   |-- FilePlayer/          Single-file AVAudioPlayerNode scheduling
  |   |-- Metronome/           Beat/bar/subdivision click player
  |
  |-- Mixing/                  Track and mixer infrastructure
  |   |-- AudioTrack           Track model with mixer and audio unit chain
  |   |-- Mixable              Protocol for nodes with volume/pan
  |   |-- MixerWrapper         AVAudioMixerNode wrapper
  |
  |-- Rendering/               Offline rendering
      |-- EngineRenderer       Actor-based offline bounce to file
      |-- EngineRendererOptions Sample rate, bit depth, channel config
```

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

Spongefork (SPFK) is the personal software projects of [Ryan Francesconi](https://github.com/ryanfrancesconi). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2016 to 2025 he was the lead macOS developer at [Audio Design Desk](https://add.app).
