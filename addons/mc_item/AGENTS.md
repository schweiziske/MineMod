# Minecraft -> Garry's Mod conversion rules

English | [简体中文](../../docs/zh/addons/mc_item/AGENTS.md)

This repository ports Minecraft Java item, animation, and rendering behavior to Garry's Mod. Follow this document before changing model positions, angles, scales, animation, first-person projection, or `PoseStack` code.

## Fundamentals

- Minecraft Java client rendering data follows OpenGL/JOML/`PoseStack` conventions; Garry's Mod/Source follows DX9/Source conventions. Coordinate systems, handedness, local axes, matrix multiplication semantics, and projection parameters cannot be copied directly.
- There is no universal fixed `x/y/z` swap for “OpenGL -> DX9”. First identify whether data belongs to Minecraft world space, camera space, `ModelPart` local space, item display space, or the converted MDL's local space.
- Minecraft world up is `+Y`; Source world up is `+Z`. The Source model-local basis is `+X = Forward`, `+Y = Left`, `+Z = Up`; `Angle:Right()` points along local `-Y`.
- Treat Minecraft camera space as `+X = right`, `+Y = up`, `+Z = toward the viewer`; use `Right / Up / -Forward` for the Source camera basis. The single existing entry point is `MCITEM.Render.CameraOffset`.

## Units and scaling

- Minecraft item display translation uses model pixels. Divide by `16` to obtain block units; use `MCITEM.Render.DisplayOffset`.
- The current `mc2source` item model export constant is `$scale 36.5`: one model block unit equals `36.5` Source units. This is the model export scale, not the world block size.
- Obtain Minecraft world block size from the runtime block-size API/`MC.BS`. Do not substitute `36.5` for world block size or use variable world block size to overwrite the model export scale.
- Model entities also have their own render scale. Translation and model scale must use consistent units; scaling the model without scaling camera-space translation is incorrect.

## Transforms and projection

- Preserve Java `PoseStack` translate/rotate/scale call order, right-multiplication semantics, and pivots. Rotations do not commute; do not independently flip Java Euler component signs and then combine them in another order.
- Reconstruct the complete matrix or three basis vectors in Minecraft space first, then perform one Minecraft -> Source basis conversion. Do not approximate a matrix recoverable from source with manually tuned Source Euler angles.
- Camera-axis mapping does not apply directly to compiled model axes. The current shield geometry contract is `ShieldModel (x,y,z) -> runtime MDL local (z,x,y)`, including the special renderer's `(1,-1,-1)` and idle-sequence yaw. Use `MCITEM.Render.ApplyExactShieldTransform`.
- Minecraft's perspective-matrix `70` is vertical FOV; Source viewmodel FOV is horizontal at a reference aspect ratio of `4:3`. Convert with `2*atan(tan(vertical/2)*(4/3))`: `70` becomes approximately `86.067`. Do not pass `70` directly to Source and claim equivalent projection.

## Change requirements

- Every new vector/angle/scale value must have an identifiable source space and unit. Trace Minecraft source and converter output when the origin is unclear.
- Reuse or extend shared conversion functions in `lua/mcitem/cl_item_render.lua` first. Implement new axis contracts centrally and add regression checks; do not introduce private axis corrections in individual weapons.
- Manually tuned anchors may compensate for known Source viewmodel/model-asset differences. They must not hide sign, axis, FOV, `1/16`, or block-size conversion errors.
- Verify idle poses, rotated poses, and nonzero pivots/translations separately. An idle screenshot alone cannot establish a correct coordinate conversion.
