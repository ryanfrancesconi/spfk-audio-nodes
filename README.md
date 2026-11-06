# SPFKAudioNodes

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-audio-nodes)](https://github.com/ryanfrancesconi/spfk-audio-nodes/tags)
[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)

Custom audio units, players and mixing nodes for `AVAudioEngine`. Nothing here owns an engine. Each
piece is a node, or a small group of nodes, for the host to attach and connect.

## Features

- `ChannelGain`: stereo gain and channel operations
- `TimePitch`: time stretch and pitch shift
- `FilePlayer` and `StreamPlayer` for sample-accurate playback of a file or a decoded stream
- `Metronome`
- `AudioTrack`: a mixer track with an effects chain
- Sample-accurate parameter automation (`NodeAutomation`)
- `EngineRenderer`: offline rendering in manual rendering mode

## Notes

- `StreamPlayer` scheduling is `async`. Starting the node before scheduling completes plays an empty
  queue.
- `NodeAutomation.publish` replaces the node's whole automation, so publish every automated
  parameter together.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
