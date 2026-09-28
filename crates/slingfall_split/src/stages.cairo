//! Stage configurations of the spike beyond `rapier2d_classes::SlimSplitStages`.

use rapier2d::pipeline::stages::{BasicShapeKernels, ForceEventStage, NoFreePath, StageConfig};
use rapier2d::prelude::{ColliderSet, ContactForceEvent, Fixed};
use rapier2d_classes::{
    ClassHashes, LibraryCallActiveSet, LibraryCallBroadPhase, LibraryCallForceEvents,
    LibraryCallIslands, LibraryCallMass, LibraryCallNarrowPhase, LibraryCallSolveAdvance,
};
use rapier_dynamics2d::narrow_phase::NarrowPhase;
use starknet::SyscallResultTrait;
use starknet::syscalls::{library_call_syscall, storage_write_syscall};
use crate::hashes::SplitHashes;

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

/// Storage slot of the hook emulation's sink.
const HOOK_SLOT: felt252 = selector!("tick_hook");

/// The tick-hook emulation (size only, never run): the force events collected in process, then
/// handed to the game's class (`RulesClass::hook`) in compact form (both colliders and the total
/// force magnitude), its answer (the removals) written to a storage slot. What a `TickHook` slot
/// of `StageConfig` would compile into the caller, less the application of the removals, which
/// `inventory::PlusRemove` measures (`World::remove_body`).
pub impl HookForces<impl G: SplitHashes> of ForceEventStage {
    fn collect(
        groups: bool, dt: Fixed, ref narrow: NarrowPhase, ref colliders: ColliderSet,
    ) -> Array<ContactForceEvent> {
        // No composite shape in the game: the convex collection (as `LibraryCallForceEvents`).
        assert(!groups, rapier2d_classes::forces::forces_errors::GROUPS);
        let mut events = rapier2d::pipeline::force_events::collect_convex(
            dt, ref narrow, ref colliders,
        );
        let mut calldata = array![];
        calldata.append(events.len().into());
        for event in events.span() {
            event.collider1.serialize(ref calldata);
            event.collider2.serialize(ref calldata);
            event.total_force_magnitude.serialize(ref calldata);
        }
        let ret = library_call_syscall(G::rules(), selector!("hook"), calldata.span())
            .unwrap_syscall();
        storage_write_syscall(0, HOOK_SLOT.try_into().unwrap(), ret.len().into()).unwrap_syscall();
        events
    }
}

/// `SlimSplitStages` with the tick hook after the force events ([`HookForces`]).
pub impl HookStages<impl H: ClassHashes, impl G: SplitHashes> of StageConfig {
    impl Narrow = LibraryCallNarrowPhase<H>;
    impl Broad = LibraryCallBroadPhase<H>;
    impl Islands = LibraryCallIslands<H>;
    impl Advance = LibraryCallSolveAdvance<H>;
    impl Mass = LibraryCallMass<H>;
    impl Shapes = BasicShapeKernels;
    impl Forces = HookForces<G>;
    impl Active = LibraryCallActiveSet<H>;
    impl Free = NoFreePath;
    const KINEMATIC: bool = false;
}
