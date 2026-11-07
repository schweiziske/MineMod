# MC Voxel World

English | [简体中文](docs/zh/CONTEXT.md)

This context defines the shared language for blocks, block states, and Minecraft world importing in the GMod MC addon.

## Language

**Block Type**:
A kind of block identified by a `minecraft:*` name, without the property combination of a particular world position.
_Avoid_: block state, block ID

**Block State**:
A complete, valid, immutable combination of properties for a block type, such as a stair's facing, half, and shape.
_Avoid_: Orient, Metadata

**State Property**:
A named dimension of a block state whose domain is a boolean, integer range, or enumeration.
_Avoid_: field, Metadata

**State Schema**:
The allowed state properties, value domains, and defaults for a block type.
_Avoid_: state table, Orient Rule

**State Registry**:
An immutable catalog containing every valid block state and assigning runtime identities.
_Avoid_: Palette

**Section Palette**:
The block states actually present in a `16×16×16` storage section. Cells refer to local indices in this palette.
_Avoid_: global state registry, block list

**State Behaviour**:
Rules that transform one block state into another in response to placement, neighbor changes, random ticks, or player interactions.
_Avoid_: state storage

**Block Entity**:
Typed data attached to a block position that cannot be expressed with finite state properties, such as container contents, sign text, or furnace progress. It is not a separate Garry's Mod Entity.
_Avoid_: block state, one GMod Entity per block, Tile Entity

**State-Lossless Import**:
Importing preserves Minecraft block names and all valid state properties. The term makes no promise that entities, behavior, or block entities are implemented.
_Avoid_: perfect import

## Workshop world synchronization

**World Package**:
A read-only collection of world data published through Workshop, with a stable content identity and a base snapshot.
_Avoid_: save, runtime world, Workshop ID

**Base Snapshot**:
The immutable voxel-world state in a world package; the sole reference for determining runtime differences.
_Avoid_: current world, backup

**Runtime World**:
The server's authoritative world, defined by one base snapshot and its associated overlay.
_Avoid_: Workshop map, baseline

**Overlay**:
The normalized set of differences between a runtime world and a specific base snapshot.
_Avoid_: full save, edit history, Dirty list

**Dirty Cell**:
A cell whose current block state or block entity differs from the baseline. Editing a cell and then restoring it does not make it dirty.
_Avoid_: edited cell, dirty history

**Base Hash**:
A cryptographic fingerprint identifying the complete contents of a base snapshot. Workshop item IDs are not part of this identity.
_Avoid_: Workshop ID, filename, version note

**World Generation**:
The identity of an active runtime-world session, separating old-world network data from the current world.
_Avoid_: map version, revision number

**Revision Barrier**:
The authoritative revision selected when a client loads the baseline. The client first receives the overlay at that revision, then continuously receives subsequent transactions.
_Avoid_: paused world, final revision

## Player game modes and mining

**Player Game Mode**:
The server-authoritative gameplay state of each player: `survival` or `creative`. Distinct from Garry's Mod's global Gamemode.
_Avoid_: server mode, client ConVar

**Mining Session**:
A survival player's temporary, continuous attempt to break a specific block state. The server owns the target, progress, and completion decision.
_Avoid_: block damage, client break prediction

**Effective Tool**:
A tool that increases mining speed for a block. This is independent of whether the tool meets the drop requirements.
_Avoid_: correct tool for drops

**Correct Tool for Drops**:
A tool that satisfies a block's drop requirements. It does not necessarily increase mining speed.
_Avoid_: effective tool
