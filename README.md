# SPFKAudioNodes

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-audio-nodes)](https://github.com/ryanfrancesconi/spfk-audio-nodes/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)

Audio node types, parameter automation, file playback, metronome, and offline rendering for macOS and iOS.

Extracted from [SPFKAudioWorkspace](https://github.com/ryanfrancesconi/spfk-audio-workspace) to separate reusable node-level components from engine/workspace management.

## Key types

| Type | Description |
|------|-------------|
| **`ChannelGain`** | A stereo gain and channel-operation audio unit: independent left/right gain, swap, mono mixdown, mid/side decode and encode, dB conversion, and its `automation` |
| **`NodeAutomation`** | A node's automation: publishes `ParameterCurve`s against a `TimelineMapping`, ramps, and reads back what each parameter rendered |
| **`AutomationRecorder`** | Records a parameter's writes with their host times and merges them into a curve |
| **`NodeParameter`** / **`Parameter`** / **`NodeParameterDef`** | An `AUParameter` wrapped with safe optional access, clamping and the touch gesture |
| **`NodeParameterType`** | What a parameter is, for a node declaring its own |
| **`AutomationPoint`** | A UI automation point; `ParameterCurve(points:taper:)` builds track automation from them |
| **`FilePlayer`** | Single-file playback with editable ranges and sample-accurate scheduling |
| **`StreamPlayer`** / **`StreamPlayerEvent`** | Buffer-queue playback for containers `AVAudioFile` cannot open |
| **`TransportSourcePlayer`** | The surface a transport drives, whether the audio came from a file or a stream |
| **`Metronome`** / **`MetronomeClick`** / **`MetronomeSoundSet`** | Beat, bar and subdivision clicks with configurable sound sets |
| **`AudioTrack`** / **`AudioTrackDelegate`** | A mixer input, a channel gain output and an effects chain, with a connect/detach lifecycle |
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

## Automation

A node's automation is one immutable snapshot of curves and a `TimelineMapping`, published with
`NodeAutomation.publish` and adopted by the render thread with one atomic exchange at the start of a
block. Every parameter's value is evaluated exactly per frame, through the same C function
`ParameterCurve.value(at:)` runs, so what is drawn and exported is what plays. Publishing replaces
the node's whole automation: a parameter cannot be automated twice. A curve multiplies the
parameter's own value or replaces it, and while replacing, `AutomationMode` decides who wins a
touched parameter. Any `DSPBase` subclass whose `process` reads its rampers is automated with no
code of its own.

The mapping is anchored to a render sample, a host time bound on the render thread, or the adopting
block. A loop is its wrap, so a loop of any length and any number of iterations is one publish.

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
- **SPFKAudioNodesC** - C/C++ companion target for DSP kernels and the render-thread automation scheduler, evaluating through **SPFKAudioBaseC**

## Requirements

- **Platforms:** macOS 13+, iOS 16+
- **Swift:** 6.2+

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
