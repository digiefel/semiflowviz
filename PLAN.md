# Implementation Plan: Semiconductor Process Flow Visualizer in Julia

## Vision

A Julia package that reads a GDSII mask layout, accepts a description of fabrication
process steps (deposition, etching), and builds a 3D material solid model incrementally.
The operator steps through the process and explores the structure in an interactive 3D
viewer. 2D cross-section slices can be taken at arbitrary planes and exported as SVG for
use in presentations.

## Scope

The tool operates on **individual cells** from a GDS file, not full chips. A cell is
selected after loading and its flattened mask polygons drive the process steps.

## Libraries

- **GDSII parsing**: custom binary reader (~400–600 lines). The format is simple
  sequential binary records. Avoids depending on `GDS.jl` (unclear maintenance) or
  `DeviceLayout.jl` (full CAD system, too heavy).
- **2D polygon booleans**: `Clipper.jl` — intersection, difference, union on integer
  coordinates (matches GDSII DB units natively).
- **3D interactive viewer**: `GLMakie` (or `WGLMakie` for browser). Step slider and
  material visibility driven by Makie `Observable`s.
- **SVG cross-section export**: `Luxor.jl` — produces clean, editable SVG with real text
  nodes. CairoMakie SVG converts text to curves, which is unusable in PowerPoint.

## Data Model

### GDS types

The GDS parser produces a `GDSLibrary` containing `Cell`s. Each `Cell` holds `Boundary`
(polygon), `Path`, `CellRef` (SREF), `ArrayRef` (AREF), and `TextElement` records.
`flatten(lib, cell_name)` resolves the hierarchy into a flat list of `(layer, datatype,
points)` tuples — the mask polygons used by process steps.

### Process types

Each material solid is stored as a **3D mesh** rather than a 2D polygon with Z bounds.
This is necessary to support conformal depositions and non-orthogonal sidewalls.

```julia
struct MaterialSolid
    material::Symbol          # :silicon, :sio2, :poly, :metal1, …
    mesh::TriMesh             # closed 3D triangulated surface
end
```

The exact definition of `TriMesh` (whether it wraps `GeometryBasics.Mesh`, a custom
half-edge structure, or something else) is TBD — it needs to support:
- Plane intersection (for the slicer)
- Surface normal queries (for conformal deposition offsets)
- Efficient update/replacement per process step

The world state after each process step is a `Vector{MaterialSolid}`. The full process
result is a sequence of these snapshots, one per named step.

### Material palette

A `Dict{Symbol, MaterialSpec}` maps material names to display color and optional
cross-hatch pattern for SVG rendering. Ships with defaults for common materials
(silicon, SiO₂, poly, metals, photoresist); user-extensible.

## Process API

```julia
proc = ProcessFlow(gds, "top_cell_name")

substrate!(proc, :silicon; thickness=500.0)

deposit!(proc, :sio2, 0.002;  name="Gate oxide")

deposit!(proc, :poly, 0.050;  name="Poly deposition")

etch!(proc, :poly;
    mask=gds_layer(1),
    tone=:positive,       # :positive = keep where mask covers
    name="Poly gate etch")

deposit!(proc, :sio2, 0.1; name="Spacer oxide")

result = simulate(proc)    # → ProcessResult (vector of WorldState snapshots)
```

The two core operations are `deposit!` and `etch!`. Both accept an optional `mask` (a GDS
layer reference) and `tone` (`:positive` = operation applies where mask covers,
`:negative` = where mask is absent).

## Simulation Engine

This is the hard part of the project.

The simulation engine applies each process step to the current `Vector{MaterialSolid}` and
produces the next snapshot. The key challenges are:

**Surface reconstruction**: to deposit conformally, we need to know the current top
surface. This is the union of the upper faces of all current solids. Extracting and
merging this from a collection of 3D meshes is non-trivial.

**3D boolean operations**: etching is geometrically a boolean difference — subtract the
etch volume (mask footprint extruded through the target material) from existing solids.
There is no well-maintained 3D mesh boolean library in Julia. Options include:
- Operate in 2D (polygon booleans via Clipper) and reconstruct 3D meshes from the
  resulting 2D regions — works well for anisotropic (vertical-wall) etches
- Implement or wrap a 3D CSG library for the general case
- Use a hybrid: 2D booleans for the footprint, 3D surface offsetting for conformal layers

**Conformal vs. planar deposition**: a blanket planar deposit is simple (flat slab at
the current max Z). A conformal deposit follows the surface topology with constant
thickness measured along the surface normal. The conformal case requires surface mesh
offsetting.

A practical starting point is the **2D-plus-extrusion** approach: use Clipper for all
mask boolean ops in 2D, then build 3D meshes by extruding the resulting polygons. This
handles vertical-wall anisotropic processes correctly and is sufficient for a first useful
version. Conformal and angled-wall support can be layered on once the 2D path works
end-to-end.

## Interactive 3D Viewer

GLMakie scene with:
- **Step slider** bound to an `Observable{Int}` — scrubbing rebuilds the displayed meshes
  from the corresponding `WorldState` snapshot
- **Material toggles** — hide/show per material
- **Opacity control** — for seeing buried structures
- **Camera** — GLMakie's built-in orbit/zoom

## Cross-Section Slicer

Takes a `WorldState` and a cut plane (vertical cut at a given X or Y coordinate, or
horizontal cut at a given Z) and returns a list of 2D material regions in the cross-section
coordinate frame. For solids stored as 3D meshes, this is a standard mesh-plane
intersection producing closed 2D contours per material.

The cross-section regions are rendered with Luxor.jl as filled polygons with material
colors, optional hatch patterns, and text labels, then exported as SVG. Output is sized
for direct PowerPoint import.

A batch mode produces one SVG per process step at a given cut plane — the direct
replacement for the manual slide-per-step workflow.

## Implementation Phases

1. **GDS loading**: binary parser, data model, hierarchy flattening with transform
   composition and path-to-polygon expansion
2. **Process API + simulation engine (2D path)**: Clipper-based 2D mask booleans,
   vertical-wall extrusion to 3D meshes, deposit and etch working end-to-end
3. **3D viewer**: GLMakie rendering of a `WorldState`, step slider, material toggles
4. **Slicer + SVG export**: mesh-plane intersection, Luxor cross-section rendering,
   batch export
5. **Conformal / angled geometry**: surface offsetting for conformal deposits,
   non-vertical etch profiles — extending the mesh representation beyond simple extrusion
