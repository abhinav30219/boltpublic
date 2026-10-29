# Robot rig pipeline

Turns the Tripo-generated quadruped robot-dog FBX into `App/Resources/Robot.usdz`: a rigid joint hierarchy the
SceneKit renderer animates by rotating nodes (`hip_FL`, `knee_FL`, `ankle_FL`, ...). No skinning, no bones.

## Inputs
- `assets/robot/source/robot.fbx` - the Tripo export (one mesh, Z up, 77 loose islands).
- Blender 5.x at `/Applications/Blender.app` (override with `BLENDER=/path/to/Blender`).

## Command
```
bash tools/robot-rig/build_robot.sh
```
1. `rig.py` splits the mesh into islands, classifies them into parts, cuts the fused front legs at the knee,
   builds the joint hierarchy, assigns materials, adds knee sleeves, deletes rods that would poke through the
   body, and exports `App/Resources/Robot.usdz` (Y-up). It also writes `out/robot_rigged.blend` and `out/pivots.json`.
2. `verify.py` re-imports the USDZ in Blender and reads the stage with `usdcat`; checks the contract below, including
   that every contract name is exactly one prim in the USD. Prints `OK`, or lists violations and exits 1.
3. `scenekit_check.swift` loads the USDZ with `SCNScene(url:)` (`xcrun swift tools/robot-rig/scenekit_check.swift
   App/Resources/Robot.usdz`, macOS) and asserts each contract name is found exactly once, joint rest `eulerAngles`
   are zero, and the material names SceneKit sees. It prints joint world positions and material names.
4. `poses.py` renders check poses to `out/pose_<pose>_<view>_<color|grey>.png` (rest, walk, crouch, hop, knee25,
   hipfwd, hipback; `knee25` also has `kneeL`/`kneeR` close-ups). `out/` is git-ignored.

## Asset contract
| Thing | Rule |
|---|---|
| Up axis | Y. The single top-level prim `robot` carries a -90 deg X rotation; everything below keeps the model's own Z-up frame, so joint-local axes are unchanged. |
| Orientation | Front (face) is local -Y. `L` is model -X, `R` is +X, `F`/`B` are front/back. |
| Joints | `hip_XX`, `knee_XX`, `ankle_XX` for XX in FL FR BL BR. Hierarchy `body > hip > knee > ankle`. All rest rotations identity. |
| Swing | Rotate about the joint's local X. Positive = foot toward the back. |
| Meshes | `body`, `upperLeg_XX` (under hip), `lowerLeg_XX` (under knee), `foot_XX` (under ankle), `kneeSleeve_FL`, `kneeSleeve_FR` (under knee). Each mesh's origin is its joint. |
| Materials | `mat_shell` body, `mat_limb` upper legs, `mat_joint` lower legs and sleeves, `mat_foot` feet, `mat_accent` reserved (one 1 mm triangle hidden inside the body keeps it in the file). |
| Face | `face_anchor` empty under `body`, local -Y points out of the face. |

`_mesh` convention: every mesh part is a transform prim with the contract name (`body`, `upperLeg_FL`, `kneeSleeve_FL`,
...) holding a child Mesh prim named `<name>_mesh` (`body_mesh` carries `mat_shell` and `mat_accent`). Contract names
therefore occur exactly once and refer to the transforms; `_mesh` nodes are the geometry. Materials live under
`/robot/_materials`. In SceneKit the world is Y-up with the face toward +Z (model -Y becomes world +Z); joint-local
frames stay in the model's Z-up frame, so swing is still about the joint's local X.

The build stops at the first failing step (Blender crash, contract violation, SceneKit mismatch) with a non-zero exit
and the log tail; logs are in `out/<step>.log`.

## Knee sleeve
The front legs are one fused mesh, cut at z = 0.46 (`KNEE_CUT_Z`). The knee pivots at the centre of the cut
section, so the caps are flush at rest and a bend opens a small wedge. `kneeSleeve_FL/FR` is a cylinder on the
model X axis, radius 1.15 x half the section length, as long as the leg is wide, parented to the knee; it hides
that wedge (checked at 25 deg).

## Rods through the body
Linkage rods ride with their upper leg. Each is swept through hip -30..+30 deg against the body (BVH overlap);
any that intersects at any swept angle, including a rod already overlapping the body at rest (0 deg), is deleted and listed in the build output (`ROD-DELETE`, `DELETED-PARTS`).

## After a new Tripo export
1. Replace `assets/robot/source/robot.fbx`, run `build_robot.sh`.
2. The island classification in `rig.py` is by face count and position, tuned to this model. If a part lands in
   the wrong group, or `verify.py` fails, adjust the thresholds in the classification loop, `KNEE_CUT_Z`
   (`rig.py` argument 3) and the eye-disc filter for `face_anchor`.
3. Open the renders in `out/` and check: no gap at the front knees in `knee25`, no rods through the body in
   `hipfwd`/`hipback`, feet attached in every pose.
