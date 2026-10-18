---
name: blender
description: Use when controlling Blender UI, menus, modal transforms, object creation, movement, scaling, rotation, and keyboard workflows.
---

# Blender

Blender is mostly a canvas app, so native macOS accessibility often cannot see its menus, viewport controls, or modal tool state. Prefer Cuse's local OCR/YOLO grounding for visible menu items and use Blender's keyboard modal commands for transform operations.

Blender viewport objects are different from Blender UI labels. A visible mesh/object/shape such as a cube, cylinder, cone, roof, or house body usually has no reliable OCR/AX label on the canvas. For pointing at or clicking a viewport object, use fresh screenshot visual coordinates (`point_2d` preferred, `box_2d` acceptable) instead of a bare label like `Cylinder`, because bare labels can match the outliner, menus, or property text.

If the user asks for a realistic, detailed, nice, downloaded, imported, or marketplace-quality model, do not default to the primitive house recipe. Treat it as an asset acquisition task for the outer agent: find a free/licensed asset, download it, validate the file, import it into Blender, then use Cuse visual context to verify the result.

For one-action-at-a-time control:

- Add objects through the visible `Add` menu, then `Mesh`, then the object type.
- After opening `Add` or any submenu, refresh visible targets before selecting the next menu item. In the Cuse harness this means call `/v1/targets`, then choose the menu item by `target_id` or `target_mark` when possible.
- Do not rely on bare letter menu accelerators such as `M`, `P`, or `C` unless the correct Blender popup/submenu is visibly open and was just observed. Visible menu target clicks are safer for `Add > Mesh > Cube/Plane/Cone`.
- For modal transforms, send physical key actions in sequence: `G` for grab/move, `S` for scale, `R` for rotate, then optional axis keys like `X`, `Y`, or `Z`, then numeric input, then `Return`.
- Each modal transform token is its own Cuse action. For example, scaling by 3 requires separate actions: `S`, type `3`, `Return`. Moving up 1.5 on Z requires separate actions: `G`, `Z`, type `1.5`, `Return`.
- Never send `S`, a numeric value, and `Return` in one workflow plan. Never press `S` twice unless the previous scale command was cancelled.
- Numeric transform input must behave like real keyboard typing. Do not paste numbers into Blender modal transform input.
- When selecting from an open Blender menu, prefer the menu popup region over duplicate labels in the right outliner or properties sidebar.
- When pointing at or clicking a 3D viewport object, do not rely on local target labels alone. Include visual coordinates from the screenshot, or ask Cuse for visual context first.
- For deleting objects in Blender, use `A` to select all when needed, `X` to delete selected objects, then confirm with `Return`. Do not use a fuzzy OCR click to confirm deletion.

## Imported Model Workflow

Use this path when the task asks to get or load an existing model from the web.

1. Use the outer agent's web/search/extract/browser tools to find a free or clearly licensed asset. Prefer direct asset pages over search-result snippets.
2. Prefer `.glb` or `.gltf` for Blender import. `.obj`, `.fbx`, and `.blend` are also acceptable. Do not download installers, archives with executables, or paid/login-gated assets without asking the user.
3. Download to a clear local task folder and keep the absolute path. Inspect the file size and extension before importing.
4. Prefer direct Blender import when possible because it is faster and less brittle than menu clicking:
   - `.glb` / `.gltf`: use Blender Python `bpy.ops.import_scene.gltf(filepath="/absolute/path/model.glb")`.
   - `.fbx`: use `bpy.ops.import_scene.fbx(filepath="/absolute/path/model.fbx")`.
   - `.obj`: use Blender's OBJ import operator for the installed Blender version.
   - `.blend`: use `bpy.ops.wm.open_mainfile(filepath="/absolute/path/file.blend")` if replacing the scene is intended; use Append when the user wants to merge assets into the current scene.
5. If the user explicitly wants to see the UI, or direct scripting is unavailable, drive Blender's UI through Cuse one action at a time:
   - Click `File`.
   - Choose `Import` then `glTF 2.0`, `Wavefront (.obj)`, or `FBX`, or choose `Open` / `Append` for `.blend`.
   - In the macOS file dialog, use the absolute path. Prefer paste/type path and press `Return`/`Open` over visually clicking folders.
   - Wait for Cuse after every action, refresh/ground visible menu targets after each menu opens, and verify after import.
6. After import, call Cuse `/v1/visual-context` with `reason:"post_action"` and the same `trace_id`. Do not claim success until the model is visible or the import produced a clear success signal.

## Reliable House Recipe

When the user asks to make a simple house in Blender through Cuse, use a small, reliable primitive-building loop. Do not try to send a multi-step plan. Every bullet below is one action followed by waiting for Cuse's response and observing/refreshing targets when the visible UI changes.

1. Switch/open Blender.
2. Select all objects with `A`.
3. Delete selected objects with `X`.
4. Confirm delete with `Return` if Blender asks. Do not click a guessed OCR target for this.
5. Open the Add menu with `Shift+A`.
6. Refresh targets and choose visible `Mesh`.
7. Refresh targets and choose visible `Cube` for the house body.
8. Scale the selected cube: `S`, type `3`, `Return`.
9. Flatten/shape the body on Z: `S`, `Z`, type `0.7`, `Return`.
10. Open Add with `Shift+A`, choose `Mesh`, then choose `Cone` for a roof. If the cone options are easy to edit, use 4 vertices for a pyramid roof; otherwise use the default cone as a recognizable roof.
11. Move the roof up: `G`, `Z`, type `1.1`, `Return`.
12. Scale the roof wider: `S`, type `2.4`, `Return`.
13. Add small cubes for a door and windows through `Add > Mesh > Cube`, then use `S`, axis-constrained scaling, `G`, axis-constrained movement, and `Return` to place them on the front.

For house tasks, prefer progress over perfection: create a body, a roof, a door, and at least one window. If a menu item is not visible or a transform state is uncertain, observe/refresh targets before continuing.

```cuse-runtime-hints
{
  "appMatchers": {
    "bundleIdentifiers": ["org.blenderfoundation.blender"],
    "names": ["Blender"]
  },
  "commandAliases": [
    {
      "phrases": ["select all", "select all objects", "select all shapes"],
      "type": "pressKey",
      "label": "A"
    },
    {
      "phrases": ["delete", "delete selected", "delete objects", "delete all objects", "delete all shapes"],
      "type": "pressKey",
      "label": "X"
    },
    {
      "phrases": ["scale"],
      "type": "pressKey",
      "label": "S"
    },
    {
      "phrases": ["grab", "move"],
      "type": "pressKey",
      "label": "G"
    },
    {
      "phrases": ["rotate"],
      "type": "pressKey",
      "label": "R"
    },
    {
      "phrases": ["x axis", "constrain to x axis"],
      "type": "pressKey",
      "label": "X"
    },
    {
      "phrases": ["y axis", "constrain to y axis"],
      "type": "pressKey",
      "label": "Y"
    },
    {
      "phrases": ["z axis", "constrain to z axis"],
      "type": "pressKey",
      "label": "Z"
    },
    {
      "phrases": ["confirm", "apply", "enter", "confirm transform"],
      "type": "pressKey",
      "label": "Return"
    },
    {
      "phrases": ["escape", "cancel"],
      "type": "pressKey",
      "label": "Escape"
    }
  ],
  "inputPolicies": [
    {
      "kind": "numericModalText",
      "delivery": "physicalKeys",
      "maxLength": 16,
      "characters": "0123456789.-+*/"
    }
  ],
  "targetPolicies": {
    "menuSelection": {
      "preferLeftMenuRegionMaxX": 0.72
    }
  },
  "plannerInstructions": [
    "Use one Cuse action at a time.",
    "After opening Add or a Blender submenu, call /v1/targets before choosing Mesh, Cube, Plane, Cone, or other visible menu items.",
    "Prefer visible menu target clicks with target_id or target_mark for Add > Mesh selections; do not rely on bare M/P/C menu accelerator keys unless the relevant submenu is visibly open and freshly observed.",
    "For Blender transforms, use key sequences like G, Z, type numeric value, Return.",
    "Each transform token is a separate Cuse action: S, type 3, Return must be sent as three separate /v1/workflow-plan requests.",
    "Never send S, a numeric value, and Return in one workflow plan. Never press S twice unless the previous scale command was cancelled.",
    "For Blender delete confirmations, press Return as a targetless key action; do not use /v1/plan-next-action to click a fuzzy OCR confirmation target.",
    "For numeric transform input, send a type step with the value only, for example {\"type\":\"type\",\"value\":\"2\"}.",
    "When choosing objects from Add > Mesh, ask Cuse for visible targets and choose the open menu item, not duplicate labels in the outliner.",
    "For pointing at or clicking a 3D viewport object such as a cube, cylinder, cone, roof, or house body, use screenshot visual coordinates: include point_2d when submitting a workflow step. Do not submit only a bare label like Cylinder because local OCR may match outliner/menu/property text instead of the object.",
    "If you need visual context for a Blender viewport object, call /v1/visual-context with visual_context=\"auto\" and query or target_label set to the object name before deciding the next action.",
    "For realistic, detailed, nice, downloaded, imported, or marketplace-quality model requests, use the outer agent's web/file/terminal tools to acquire and import a real asset. Cuse should only ground/click local UI and verify the Blender viewport.",
    "For downloaded .glb/.gltf/.obj/.fbx/.blend assets, prefer reliable Blender Python or terminal import when available. Use File > Import/Open/Append through Cuse only when visible UI interaction is requested or scripting is unavailable.",
    "When using Blender's file dialog, provide an absolute local file path rather than visually walking folders.",
    "For a simple house: clear the scene, add a Cube for the body, scale it, add a Cone or Cube roof, move it up, then add small Cube door/window details. Wait for Cuse after every single action."
  ]
}
```
