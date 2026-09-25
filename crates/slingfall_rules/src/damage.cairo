//! Damage from contact-force events, removals in ascending handle order (`docs/DESIGN.md` D6).
//! Lot G3.
//!
//! For each event (rapier's order: ascending pair) and each side that is a live block or core:
//! `excess = total_force_magnitude - material.force_threshold`; if `excess > 0`,
//! `hp -= floor(excess · damage_per_impulse_dt)` saturating at 0. One `Fixed` mul (floored) and
//! one integer part per event side, no sqrt. Static bodies and the pebble take no damage. A side
//! whose `hp` reaches 0 this tick is destroyed; [`remove`] removes the destroyed bodies at the end
//! of the tick, in ascending handle order (entity order: entity `i` owns handles of index `i`).
//! `World::remove_body` wakes the bodies in contact with the removed colliders itself (tested).

use rapier2d::prelude::{ContactForceEvent, Fixed, Handle, WorldTrait};
use slingfall_level::level::{KIND_CORE, KIND_STATIC, Level, Material};
use crate::score;
use crate::world::{Entity, Game};

/// `2^32`: the integer part of a non-negative raw Q32.32 value.
const NZ_ONE_RAW: NonZero<u64> = 0x100000000;

/// Applies the damage of `events` to the entities of `game` and returns the indices of the
/// entities destroyed by it (`hp` reached 0 this tick), ascending. The bodies stay in the world
/// until [`remove`].
pub fn apply(ref game: Game, level: @Level, events: Span<ContactForceEvent>) -> Array<usize> {
    if events.is_empty() {
        return array![];
    }
    let entities = game.entities.span();
    let materials = level.materials.span();
    // `(entity, damage)` of every event side that takes damage, in event order.
    let mut hits: Array<(usize, u32)> = array![];
    for event in events {
        let force = *event.total_force_magnitude;
        hit(ref hits, entities, materials, *event.collider1, force);
        hit(ref hits, entities, materials, *event.collider2, force);
    }
    if hits.is_empty() {
        return array![];
    }
    // Saturating subtractions in any order give the same `hp`: sum per entity, subtract once.
    let hits = hits.span();
    let mut updated: Array<Entity> = array![];
    let mut destroyed: Array<usize> = array![];
    let mut index = 0;
    for entity in entities {
        let mut entity = *entity;
        let mut total: u64 = 0;
        for (target, amount) in hits {
            if *target == index {
                total += (*amount).into();
            }
        }
        if total != 0 {
            let hp: u64 = entity.hp.into();
            entity.hp = if total >= hp {
                0
            } else {
                (hp - total).try_into().unwrap()
            };
            if entity.hp == 0 {
                destroyed.append(index);
            }
        }
        updated.append(entity);
        index += 1;
    }
    game.entities = updated;
    destroyed
}

/// `floor((force - material.force_threshold) · material.damage_per_impulse_dt)` when the excess
/// is positive, else 0 (D6): one floored `Fixed` product, then its integer part.
pub fn damage_of(force: Fixed, material: @Material) -> u32 {
    let excess = force - *material.force_threshold;
    if excess.raw <= 0 {
        return 0;
    }
    let scaled = excess * *material.damage_per_impulse_dt;
    if scaled.raw <= 0 {
        return 0;
    }
    let raw: u64 = scaled.raw.try_into().unwrap();
    let (whole, _) = DivRem::div_rem(raw, NZ_ONE_RAW);
    // `whole < 2^31`.
    whole.try_into().unwrap()
}

/// The entity owning `collider`: entity `i`'s collider has slot index `i` (`GameTrait::new`), so
/// one lookup and a full handle compare (the pebble may reuse a freed slot, with a new
/// generation). `None` for the pebble.
pub fn entity_of(entities: Span<Entity>, collider: Handle) -> Option<usize> {
    let index: usize = collider.index;
    if index >= entities.len() {
        return None;
    }
    if *entities[index].collider == collider {
        Some(index)
    } else {
        None
    }
}

/// Removes the bodies of the entities `indices` (ascending) from the world, in that order, marks
/// them dead, scores them (`score::on_destroyed`) and counts the cores down.
pub fn remove(ref game: Game, level: @Level, indices: Span<usize>) {
    if indices.is_empty() {
        return;
    }
    let materials = level.materials.span();
    let entities = game.entities.span();
    for index in indices {
        let entity = *entities[*index];
        let _ = game.world.remove_body(entity.body);
        let material: usize = entity.material.into();
        score::on_destroyed(ref game, materials[material]);
        if entity.kind == KIND_CORE {
            game.cores_left -= 1;
        }
    }
    let mut updated: Array<Entity> = array![];
    let mut next = indices;
    let mut index = 0;
    for entity in entities {
        let mut entity = *entity;
        if let Some(target) = next.get(0) {
            if *target.unbox() == index {
                entity.alive = false;
                let _ = next.pop_front();
            }
        }
        updated.append(entity);
        index += 1;
    }
    game.entities = updated;
}

/// Appends the damage of one event side, when it is a live block or core that takes some.
fn hit(
    ref hits: Array<(usize, u32)>,
    entities: Span<Entity>,
    materials: Span<Material>,
    collider: Handle,
    force: Fixed,
) {
    if let Some(index) = entity_of(entities, collider) {
        let entity = entities[index];
        if *entity.kind != KIND_STATIC && *entity.alive {
            let material: usize = (*entity.material).into();
            let amount = damage_of(force, materials[material]);
            if amount != 0 {
                hits.append((index, amount));
            }
        }
    }
}

#[cfg(test)]
mod tests;
