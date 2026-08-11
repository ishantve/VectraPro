# ATCReplayKit

Recording, replay and timeline branching for a deterministic simulation.

Records **causes**, not state: a seed, a resolved configuration, and the sparse stream of discrete
inputs. Replay re-runs the simulation from those causes rather than playing back stored positions,
which is what makes it possible to pause a replay and continue live from that exact point — and what
keeps a forty-minute session in the low hundreds of kilobytes rather than tens of megabytes.

See [`docs/architecture/replay-engine.md`](../../docs/architecture/replay-engine.md) for the design
and the reasoning behind it.

## Dependencies

Foundation only. An event carries a phraseology code and its slot values, not a simulator command,
so this package does not depend on the simulation engine or on CoreLocation. That keeps it portable
to a C interface and to React Native and Unity.
