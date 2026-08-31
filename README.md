# SPFKAudioNodes

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-audio-nodes)](https://github.com/ryanfrancesconi/spfk-audio-nodes/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)

Audio node types, parameter automation, file playback, metronome, and offline rendering for macOS and iOS.

Extracted from [SPFKAudioWorkspace](https://github.com/ryanfrancesconi/spfk-audio-workspace) to separate reusable node-level components from engine/workspace management.

## Key types

| Type | Description |
|------|-------------|
| **`Fader`** | A stereo fader audio unit: independent left/right gain, stereo flip, mono mixdown, dB conversion, parameter automation |
| **`NodeParameter`** / **`Parameter`** / **`NodeParameterDef`** | An `AUParameter` wrapped with safe optional access, clamping, ramping and automation recording |
| **`NodeParameterType`** | What a parameter is, for a node declaring its own |
| **`AutomationCurve`** / **`AutomationPoint`** | Curved automation over any time-varying parameter, converted to the linear ramps DSP consumes |
| **`ParameterAutomationTiming`** | When an automation run is anchored |
| **`RegionFadeDescription`** | Fade in and out curves over a region of a timeline |
| **`FilePlayer`** | Single-file playback with editable ranges and sample-accurate scheduling |
| **`StreamPlayer`** / **`StreamPlayerEvent`** | Buffer-queue playback for containers `AVAudioFile` cannot open |
| **`TransportSourcePlayer`** | The surface a transport drives, whether the audio came from a file or a stream |
| **`Metronome`** / **`MetronomeClick`** / **`MetronomeSoundSet`** | Beat, bar and subdivision clicks with configurable sound sets |
| **`AudioTrack`** / **`AudioTrackDelegate`** | A mixer input, a fader output and an effects chain, with a connect/detach lifecycle |
| **`MixerWrapper`** / **`Mixable`** | `AVAudioMixerNode` with volume and pan |
| **`EngineRenderer`** / **`EngineRendererOptions`** | Actor-based offline bounce of an engine graph in manual rendering mode |
| **`AudioEngineNodeAU`** / **`SPFKAudioUnit`** | The node-level audio unit surface everything above is built on |
| **`TransportValidationAU`** / **`TransportSnapshot`** | A test unit that captures the host transport and musical context it is handed on each render cycle |

## Playing from a stream

`StreamPlayer` takes any `SeekablePCMSource` and keeps the node's queue fed from it, so the decoder
lives in whichever package owns the container rather than here — Matroska, chiefly.

Scheduling is `async` on `StreamPlayer` and synchronous on `FilePlayer`: a file is armed by handing
the node a segment, whereas a stream has to decode before there is anything to hand over. Starting
the node before that has happened plays an empty queue.

`TransportSourcePlayer` is the seam between the two, and is deliberately narrow — it is the surface
`TransportPlayer` already used against `FilePlayer`, not a general player abstraction, since
anything wider would have to be honored twice. Both conformers drive an `AVAudioPlayerNode`, so
everything below the seam — the sample-accurate start, the playhead, the completion callbacks — is
one piece of machinery rather than two implementations of it.

## Looping either source

`enqueueRepeat` queues a pass after whatever is already scheduled. `AVAudioPlayerNode` plays a
command with no time immediately after the last one, so neither player times anything against a
clock — which is also why this works in manual rendering mode, where host time is ignored.

The range is stated rather than reused from the current run, because playback can begin inside a
loop and that first partial pass is not what repeats.

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
