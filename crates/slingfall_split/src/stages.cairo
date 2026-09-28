//! Stage configurations of the spike beyond `rapier2d_classes::SlimSplitStages`.

use rapier2d::pipeline::stages::{BasicShapeKernels, NoFreePath, StageConfig};
use rapier2d_classes::{
    ClassHashes, LibraryCallActiveSet, LibraryCallBroadPhase, LibraryCallForceEvents,
    LibraryCallIslands, LibraryCallMass, LibraryCallNarrowPhase, LibraryCallSolveAdvance,
};

/// `SlimSplitStages` with the force events collected in `ForceEventsClass` (CS6's lever 3,
/// measured by rapier-cairo, not in `SlimSplitStages`).
pub impl SlimForceStages<impl H: ClassHashes> of StageConfig {
    impl Narrow = LibraryCallNarrowPhase<H>;
    impl Broad = LibraryCallBroadPhase<H>;
    impl Islands = LibraryCallIslands<H>;
    impl Advance = LibraryCallSolveAdvance<H>;
    impl Mass = LibraryCallMass<H>;
    impl Shapes = BasicShapeKernels;
    impl Forces = LibraryCallForceEvents<H>;
    impl Active = LibraryCallActiveSet<H>;
    impl Free = NoFreePath;
    const KINEMATIC: bool = false;
}
