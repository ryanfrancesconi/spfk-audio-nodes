# SPFKAudioNodes

[![Version](https://img.shields.io/github/v/tag/ryanfrancesconi/spfk-audio-nodes)](https://github.com/ryanfrancesconi/spfk-audio-nodes/tags)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fryanfrancesconi%2Fspfk-audio-nodes%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ryanfrancesconi/spfk-audio-nodes)

The building blocks of an `AVAudioEngine` graph: the custom audio units, players and mixing pieces
that spfk-audio-workspace assembles into ShadowTag's playback and offline render. Nothing here owns
an engine. Each piece is a node, or a small group of nodes, for a host to attach and connect.

That covers a stereo gain and channel-operation unit (`ChannelGain`), a time-stretch and pitch-shift
unit (`TimePitch`), sample-accurate players for a file or for a decoded stream, a metronome, a mixer
track with an effects chain, sample-accurate parameter automation, and an offline renderer that
bounces a graph in manual rendering mode. Audio unit DSP is C++, in a companion target, and
evaluates curves through the same C functions spfk-audio-base defines, so what is drawn and exported
is what plays.

Engine and device management belong to spfk-audio-workspace, hosting third-party units to
spfk-au-host, decoding containers to the packages that own them, and the time and pitch algorithm to
spfk-tempo.

## Constraints

A `StreamPlayer` decodes before it has anything to play, so its scheduling is `async`. Starting the
node before scheduling completes plays an empty queue. Publishing automation replaces the node's
whole automation, so every automated parameter goes into one publish.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
