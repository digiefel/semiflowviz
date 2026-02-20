# Implementation Plan: Semiconductor Process Flow Visualizer in Julia

## Vision

A Julia package that reads a GDSII mask layout, accepts a description of fabrication
process steps (deposition, etch, CMP, implant, …), and builds a 3D material solid model
incrementally — one step at a time. The primary outputs are:

1. **Interactive 3D view** (GLMakie) to explore the growing structure after each step
2. **2D cross-section slices** at arbitrary planes, exported as SVG for documentation

The target workflow replaces the common practice of manually drawing process cross-sections
in PowerPoint, slide by slide, with a scriptable, high-fidelity, automated alternative.

```
process_flow.jl (user script)
       │
       ├─ load_gds("layout.gds")        → GDSLibrary  (mask polygons)
       ├─ substrate!(:silicon, 500µm)
       ├─ deposit!(:sio2, 2nm)
       ├─ deposit!(:poly, 50nm)
       ├─ etch!(:poly, mask=layer(1))
       └─ ...
              │
       ProcessSimulator
              │
     WorldState snapshots [0..N]
         /              \
  3D Renderer          Slicer
  (GLMakie)            (XZ / YZ / arbitrary plane)
       │                        │
  Interactive 3D             2D cross-section polygons
  step-by-step view          → SVG / PNG export
```

---

## Architecture

### Core Concept: Material Solids + Surface Map

The 3D structure at any process stage is represented as a collection of **material solids**:

```julia
struct MaterialSolid
    material::Symbol              # :silicon, :sio2, :poly, :metal1, …
    polygon::Vector{Tuple{Float64,Float64}}  # closed 2D XY footprint
    z_bottom::Float64
    z_top::Float64
end
```

Alongside this, a **surface map** tracks the current top-surface height per XY region
(a piecewise-constant Z field encoded as a polygon partition):

```julia
struct SurfaceRegion
    polygon::Vector{Tuple{Float64,Float64}}
    z::Float64   # current top-of-stack height in this region
end

const SurfaceMap = Vector{SurfaceRegion}
```

Together, these two structures are the **WorldState**:

```julia
struct WorldState
    solids::Vector{MaterialSolid}
    surface::SurfaceMap
    step_name::String
end
```

---

## Library Choices

### GDS Parsing: Custom (see Phase 1)
As described in the original plan — a minimal GDSII binary reader. Unchanged.

### 2D Polygon Boolean Operations: Clipper.jl
All deposit/etch masking requires polygon intersection, difference, and union.
`Clipper.jl` (JuliaGeometry organisation) wraps Angus Johnson's Clipper v6.4.2 and is
actively maintained. It uses integer coordinates (matching GDSII's native integer DB units
exactly, avoiding float precision issues):

```julia
using Clipper
c = Clipper.Clip()
add_path!(c, subject_path, Clipper.PolyTypeSubject, true)
add_path!(c, clip_path,    Clipper.PolyTypeClip,    true)
result = execute(c, Clipper.ClipTypeDifference, Clipper.PolyFillTypeNonZero)
```

Polygon offsetting (for conformal deposition rounding, future work) is handled by
`Clipper.ClipperOffset`.

### Polygon Triangulation: EarCut.jl + Triangulate.jl
For converting 2D material solid footprints into triangulated surfaces for 3D rendering.
- **EarCut.jl** for simple polygons (fast, good enough for rendering)
- **Triangulate.jl** when quality meshes with quality constraints are needed (e.g. FEM
  export)

### 3D Geometry: GeometryBasics.jl
`Point3f`, `TriangleFace`, `Mesh` — the standard Julia geometry type that integrates
natively with Makie renderers.

### 3D Visualization: GLMakie
Interactive camera, real-time updates via `Observable`s, per-material color and
transparency. `WGLMakie` supported as an alternative backend for Jupyter/web.

### 2D Cross-Section SVG Export: Luxor.jl
CairoMakie SVG converts all text to curves and produces non-editable output — unsuitable
for PowerPoint round-tripping. `Luxor.jl` (JuliaGraphics) generates clean, fully editable
vector SVG with proper text nodes, polygon fills, and labels. It uses Cairo internally
but exposes a drawing-oriented API:

```julia
Drawing(600, 400, :svg)
setcolor(material_color)
poly(cross_section_points, :fill)
label("SiO₂", coords)
finish()
svgstring()   # returns the SVG XML
```

Material cross-hatching (conventional notation: \\\\ for Si, /// for SiO₂, etc.) is
achieved by drawing a clipped repeating line pattern inside the polygon bounds, a standard
Luxor technique.

---

## Data Model

```julia
# src/model.jl   ← GDS types (unchanged from original plan)
# src/process.jl ← process simulation types

struct MaterialSpec
    name::Symbol
    color::RGBA{Float32}
    hatch_pattern::Symbol   # :none, :diagonal, :cross, :dot, :horizontal
end

# Built-in material palette (user can extend)
const MATERIALS = Dict{Symbol, MaterialSpec}(
    :silicon    => MaterialSpec(:silicon,   RGBA(0.6, 0.6, 0.7, 1.0), :diagonal),
    :sio2       => MaterialSpec(:sio2,      RGBA(0.8, 0.9, 1.0, 0.8), :none),
    :poly       => MaterialSpec(:poly,      RGBA(0.4, 0.4, 0.4, 1.0), :horizontal),
    :metal1     => MaterialSpec(:metal1,    RGBA(0.9, 0.8, 0.2, 1.0), :none),
    :photoresist=> MaterialSpec(:photoresist,RGBA(0.9, 0.5, 0.1, 0.6), :none),
)

struct WorldState
    solids::Vector{MaterialSolid}
    surface::SurfaceMap          # current top-of-stack height map
    step_name::String
    step_index::Int
end

struct ProcessResult
    gds::GDSLibrary
    steps::Vector{WorldState}    # one snapshot per named process step
    wafer_extent::BBox2D         # bounding box used as "full wafer" polygon
end
```

---

## Process Flow API

```julia
# src/process_api.jl

proc = ProcessFlow(gds_library)

# Declare the silicon substrate (extends downward from z=0)
substrate!(proc, :silicon; thickness=500.0)

# Blanket deposition — covers the entire wafer at the current surface height
deposit!(proc, :sio2, 0.002;  name="Gate oxide")

# Masked deposition — deposits only where the GDS mask polygon covers
deposit!(proc, :poly, 0.050;
    mask=gds_layer(1),
    tone=:positive,             # :positive = deposit where mask covers
    name="Poly gate dep.")

# Masked anisotropic etch — removes material in the unmasked region
etch!(proc, :poly;
    mask=gds_layer(1),
    tone=:positive,             # :positive = keep where mask covers
    depth=:all,                 # :all removes the full layer, or a Float64 value
    name="Poly gate etch")

# CMP — planarize to a target Z level
cmp!(proc; target_z=0.052, name="Post-poly CMP")

# Implant region (visual annotation; does not affect surface topology)
implant!(proc, :boron;
    mask=gds_layer(2),
    z_range=(-0.05, 0.0),
    name="S/D implant")

# Snapshot without process change (annotate current state)
snapshot!(proc, "After LDD spacer")

# Run the simulation — returns ProcessResult with all WorldState snapshots
result = simulate(proc)
```

### Tone Convention

| `tone`      | mask meaning                                |
|-------------|---------------------------------------------|
| `:positive` | operation applies where mask polygon covers |
| `:negative` | operation applies where mask is absent      |

### Surface Topology Handling

After each process step, the surface map is updated:

- **Deposit (blanket)**: raise all surface regions by `thickness`; add one new
  `MaterialSolid` spanning the full wafer extent from `old_z` to `old_z + thickness`.

- **Deposit (masked, tone=:positive)**:
  1. Clip the deposit footprint polygon to the mask: `footprint = wafer ∩ mask_polygon`
  2. The surface map is split: the footprint region rises by `thickness`; the rest stays
  3. Add new `MaterialSolid` for the footprint only
  4. Update `SurfaceMap` using Clipper difference/intersection

- **Etch (masked, anisotropic)**:
  1. Compute etch footprint: `footprint = wafer - mask_polygon` (for tone=:positive)
  2. For each existing solid intersecting the footprint, clip its XY polygon using
     Clipper difference to remove the etched region; if `depth=:all`, remove the entire
     solid in that region; otherwise reduce `z_top` by `depth`
  3. Update surface map in the etched region (drop by `depth` or to the revealed surface)

- **CMP**: for all solids where `z_top > target_z`, set `z_top = target_z`; remove
  zero-thickness solids; rebuild surface map as `target_z` everywhere above that level.

The `SurfaceMap` is computed from the solid list on demand (max of all `z_top` values per
XY region) rather than maintained incrementally, to avoid cumulative clipping errors.

---

## Phases

### Phase 1: GDS Loading (unchanged)

**Files**: `src/model.jl`, `src/parser.jl`

Same as the original plan: custom binary GDSII reader, IBM hex float conversion,
`GDSLibrary` / `Cell` / `Boundary` / `Path` / `CellRef` / `ArrayRef` types.
`load_gds(path)` → `GDSLibrary`.

Then `flatten(lib, top_cell)` → `Vector{FlatPolygon}` (resolved hierarchy, paths
expanded to closed polygons).

The flat polygon list is the source of mask shapes for process step operations.

### Phase 2: Process Simulation Engine

**Files**: `src/process_api.jl`, `src/process_sim.jl`, `src/polygon_ops.jl`

#### `polygon_ops.jl` — thin wrapper around Clipper.jl

```julia
# Convert between Float64 tuples and Clipper's integer points
const CLIPPER_SCALE = 1_000_000   # 1nm resolution at 1µm user units

function clip_difference(subject, clip)   # returns Vector{Vector{Tuple{Float64,Float64}}}
function clip_union(a, b)
function clip_intersection(a, b)
function polygon_area(pts)
function point_in_polygon(pt, polygon)   # for surface map queries
```

#### `process_sim.jl` — simulation loop

`simulate(proc::ProcessFlow)::ProcessResult`:
1. Initialise `WorldState` with the substrate solid and flat surface map at z=0
2. For each step in `proc.steps`:
   - Call the step's handler with current `WorldState` and the GDS flat polygons
   - Handler returns a new `WorldState`
   - Append to the `steps` vector
3. Return `ProcessResult`

### Phase 3: 3D Mesh Builder

**Files**: `src/mesh3d.jl`

Converts a `WorldState` into a renderable `Vector{(MaterialSpec, GeometryBasics.Mesh)}`.

For each `MaterialSolid`:
1. Triangulate `polygon` using EarCut.jl (holes detected by signed area / containment)
2. Build a closed prism mesh:
   - **Top** and **bottom** faces from triangulation (reversed winding for bottom)
   - **Side walls** from boundary edge quads
3. Output as `GeometryBasics.Mesh`

```julia
function build_meshes(state::WorldState)::Vector{Tuple{MaterialSpec, Mesh}}
```

### Phase 4: Interactive 3D Viewer

**Files**: `src/viz3d.jl`

The viewer presents the 3D structure with a step slider allowing the operator to step
through all captured `WorldState` snapshots.

```julia
function view3d(result::ProcessResult; backend=:gl)
```

#### Makie Observable architecture

```
step_index::Observable{Int}     ← driven by Slider
       │
       ▼
current_state = @lift result.steps[$step_index]
       │
       ▼
meshes = @lift build_meshes($current_state)
       │
       ▼
Makie mesh!() plot objects (one per material, updated reactively)
```

The figure layout:
```
┌─────────────────────────────────────────────────┐
│  [Step 3/12: Poly gate etch]                    │
│                                                 │
│        3D scene (camera: rotate/zoom)           │
│                                                 │
│                                                 │
├─────────────────────────────────────────────────┤
│  ◀  [●─────────────────────────] ▶   step 3/12 │
├─────────────────────────────────────────────────┤
│  [☑ silicon] [☑ sio2] [☑ poly]  ← layer toggle │
└─────────────────────────────────────────────────┘
```

Controls:
- **Slider**: scrub through process steps
- **◀ / ▶ buttons**: single step forward/backward
- **Layer toggles**: checkboxes per material (hide/show individually)
- **Opacity slider** per material (useful for seeing buried structures)
- **Camera**: GLMakie built-in mouse orbit/zoom

### Phase 5: Cross-Section Slicer

**Files**: `src/slicer.jl`

Computes a 2D cross-section of the 3D structure at an arbitrary plane.

#### Slice definition

```julia
abstract type SlicePlane end

struct XZSlice <: SlicePlane   # vertical cut perpendicular to X axis
    y::Float64                 # the Y coordinate of the cut
end

struct YZSlice <: SlicePlane   # vertical cut perpendicular to Y axis
    x::Float64
end

struct XYSlice <: SlicePlane   # horizontal cut (plan view at height z)
    z::Float64
end
```

#### Algorithm for `XZSlice` at `y = y0`

For each `MaterialSolid(material, polygon, z_bottom, z_top)`:
1. Find all intersections of the horizontal line `y = y0` with the polygon edges
2. Sort intersection x-coordinates; pair them as `[(x1,x2), (x3,x4), ...]` by odd-even
   rule (even-odd fill = inside the polygon)
3. For each interval `[x1, x2]`, emit a 2D cross-section polygon:
   `{(x1,z_bottom), (x2,z_bottom), (x2,z_top), (x1,z_top)}` — a rectangle
4. Merge adjacent rectangles of the same material at the same Z range (optional
   simplification)

Output: `Vector{CrossSectionRegion}`:
```julia
struct CrossSectionRegion
    material::Symbol
    polygon::Vector{Tuple{Float64,Float64}}   # 2D, axes are (x_or_y, z)
end
```

For curved polygons or diagonal cuts, the same algorithm generalises to arbitrary line
intersection with polygon edges.

```julia
function slice(state::WorldState, plane::SlicePlane)::Vector{CrossSectionRegion}
```

### Phase 6: 2D Cross-Section Renderer and SVG Export

**Files**: `src/viz2d.jl`

Renders a `Vector{CrossSectionRegion}` as a 2D diagram and exports to SVG.

#### Layout

A cross-section diagram is drawn in a coordinate frame where:
- Horizontal axis = scan direction (Y for an XZ slice, X for a YZ slice)
- Vertical axis = Z (process height), with z=0 at the wafer surface
- Substrate extends downward; deposited layers extend upward

#### Rendering with Luxor.jl

```julia
function render_crosssection(
    regions::Vector{CrossSectionRegion};
    width_px::Int = 800,
    height_px::Int = 400,
    show_labels::Bool = true,
    show_hatching::Bool = true,
    format::Symbol = :svg,   # :svg | :png | :pdf
)::String    # returns SVG XML or file path
```

Each material region is rendered as a filled polygon with:
- **Fill color** from the material's `MaterialSpec.color`
- **Cross-hatch pattern** (if `show_hatching=true`): drawn as clipped diagonal/horizontal
  lines matching the conventional notation for each material
- **Outline stroke**: thin black border between regions
- **Label**: material name placed at the centroid if the region is large enough

#### Multiple slices

```julia
function render_process_sequence(
    result::ProcessResult,
    plane::SlicePlane;
    steps::Union{Nothing, Vector{Int}} = nothing,  # nil = all steps
    output_dir::String = ".",
    prefix::String = "step",
)
# Produces step_01_gate_oxide.svg, step_02_poly_dep.svg, etc.
```

The output SVGs are sized for PowerPoint import (default 16:9 aspect, 1200×675 px
logical size) and can be dropped directly onto slides.

---

## Package Structure

```
semiflowviz/
├── Project.toml
├── src/
│   ├── SemiflowViz.jl         # module root
│   ├── model.jl               # GDSLibrary, Cell, Boundary, Path, …
│   ├── parser.jl              # load_gds(), IBM hex float conversion
│   ├── flatten.jl             # flatten(), transform composition, path expansion
│   ├── polygon_ops.jl         # Clipper.jl wrappers: difference, union, intersect
│   ├── process_api.jl         # ProcessFlow, deposit!, etch!, cmp!, …
│   ├── process_sim.jl         # simulate(), WorldState engine
│   ├── mesh3d.jl              # build_meshes(), prism extrusion, EarCut
│   ├── viz3d.jl               # view3d(), GLMakie interactive viewer
│   ├── slicer.jl              # slice(), XZSlice / YZSlice / XYSlice
│   └── viz2d.jl               # render_crosssection(), SVG/PNG export, Luxor
├── test/
│   ├── runtests.jl
│   ├── test_parser.jl
│   ├── test_flatten.jl
│   ├── test_polygon_ops.jl
│   ├── test_process_sim.jl
│   └── test_slicer.jl
└── examples/
    ├── nmos_transistor.jl     # simple NMOS cross-section flow
    └── metal_interconnect.jl  # via / dual-damascene stack example
```

### Project.toml Dependencies

```toml
[deps]
Clipper        = "…"   # 2D polygon boolean ops
EarCut         = "…"   # polygon triangulation for rendering
GeometryBasics = "…"   # 3D mesh types
Luxor          = "…"   # SVG/PNG 2D cross-section export
Makie          = "…"   # visualization framework (abstract)

[weakdeps]
GLMakie        = "…"   # native OS window (default interactive backend)
WGLMakie       = "…"   # Jupyter / browser backend
CairoMakie     = "…"   # raster/vector export

[extensions]
SemiflowVizGLMakieExt    = "GLMakie"
SemiflowVizWGLMakieExt   = "WGLMakie"
SemiflowVizCairoMakieExt = "CairoMakie"
```

---

## Implementation Order

| Step | Deliverable                                              | Depends on |
|------|----------------------------------------------------------|------------|
| 1    | `model.jl` + `parser.jl` (GDS binary reader)            | —          |
| 2    | `flatten.jl` (hierarchy + transforms + path expansion)  | 1          |
| 3    | `polygon_ops.jl` (Clipper wrappers + unit tests)        | —          |
| 4    | `process_api.jl` (DSL types, no simulation logic yet)   | —          |
| 5    | `process_sim.jl` — blanket deposit + substrate          | 3, 4       |
| 6    | `process_sim.jl` — masked deposit + anisotropic etch    | 5          |
| 7    | `process_sim.jl` — CMP + implant annotation             | 6          |
| 8    | `mesh3d.jl` — EarCut prism extrusion                    | —          |
| 9    | `viz3d.jl` — static 3D view of single WorldState        | 8          |
| 10   | `viz3d.jl` — step slider + layer toggles                | 9          |
| 11   | `slicer.jl` — XZSlice / YZSlice / XYSlice               | 5          |
| 12   | `viz2d.jl` — Luxor rendering, hatch, labels             | 11         |
| 13   | `viz2d.jl` — SVG export, batch process sequence         | 12         |
| 14   | End-to-end NMOS example                                 | 1–13       |

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| **Polygon fragmentation after many steps**: Clipper difference/union on complex shapes produces many tiny slivers | Simplify polygons after each step using Clipper's `SimplifyPolygon`; merge co-planar co-material solids |
| **Surface map complexity**: after 20+ steps with several masks, the surface map can have O(N²) polygon pieces | Recompute surface map lazily from the solid list only when needed for a new deposit step; consider bounding-box early-out |
| **Self-intersecting GDSII polygons**: malformed input files | Run Clipper `SimplifyPolygon` on all input polygons at load time |
| **Non-vertical (isotropic) etch topology**: not modelled in v1 | Document as out-of-scope; add a `clip_offset(-radius)` path for future isotropic mode using `ClipperOffset` |
| **GLMakie mesh update performance**: re-triangulating and updating hundreds of meshes per slider tick | Cache triangulated meshes per WorldState; only re-upload the GPU buffer when the step changes |
| **Luxor hatch patterns**: no built-in hatching | Implement as a clipped line grid: draw lines at 45° over the polygon bounding box, then clip to the polygon path |
| **PowerPoint SVG compatibility**: some SVG features not supported in Office | Use only basic SVG primitives (polygon, path, text); avoid gradients, filters, or advanced CSS |
