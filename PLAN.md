# Implementation Plan: GDSII to 2D/3D Diagram Generator in Julia

## Overview

This document describes the architecture and phased implementation plan for a Julia package
that reads GDSII layout files and generates interactive 2D and 3D diagrams. The primary
pipeline is:

```
GDSII file → parse → internal model → flatten hierarchy → triangulate → render
```

---

## Library Choices

### GDSII Parsing: Custom Implementation

**Decision**: Write a minimal custom binary parser rather than using `GDS.jl`
(shobhan126/GDS.jl) or `DeviceLayout.jl`.

**Rationale**:
- `GDS.jl` has unknown maintenance status and limited documentation
- `DeviceLayout.jl` (aws-cqc) is actively maintained but designed as a full quantum
  circuit CAD system — its API is oriented around design authoring, not reading arbitrary
  files for visualization
- The GDSII binary record format is straightforward and well-documented; a minimal reader
  is ~400–600 lines of Julia
- A custom parser gives full control over the internal data model and avoids pulling in
  a heavy transitive dependency tree

The format consists of sequential binary records, each with a 2-byte length, 2-byte record
type/datatype tag, and variable-length payload. There are seven element types to handle:
BOUNDARY (polygon), PATH (wire), SREF (cell instance), AREF (cell array), TEXT, NODE, BOX.

### Polygon Triangulation: Triangulate.jl + EarCut.jl

- **`Triangulate.jl`** — wrapper for Shewchuk's Triangle library. Used for high-quality
  constrained Delaunay triangulation (CDT) with quality constraints (minimum angle,
  maximum area). Ideal for simulation-quality meshes and polygons with holes.
- **`EarCut.jl`** — wrapper for Mapbox's earcut.hpp. Fast ear-clipping triangulation for
  simple convex/concave polygons without holes. Good default for visualization.

Use EarCut.jl as the default fast path; fall back to Triangulate.jl when quality mesh
output is requested or when polygons have interior holes.

### Geometry Representation: GeometryBasics.jl

- Standard Julia geometry primitive types (`Point`, `Polygon`, `Mesh`, `TriangleFace`)
- Integrates natively with Makie.jl rendering
- Used as the output type for the mesh pipeline

### Visualization: Makie.jl

| Backend     | Use case                                  |
|-------------|-------------------------------------------|
| `GLMakie`   | Interactive 2D/3D in a native OS window   |
| `WGLMakie`  | Interactive 2D/3D in Jupyter / browser    |
| `CairoMakie`| High-quality vector/raster export (PNG/SVG/PDF) |

The visualization layer will be backend-agnostic; callers choose the backend by importing
it before calling the display functions.

---

## Internal Data Model

```julia
# src/model.jl

struct GDSTransform
    magnification::Float64   # default 1.0
    angle::Float64           # degrees, default 0.0
    reflect_x::Bool          # x-axis reflection before rotation
    origin::Tuple{Float64, Float64}
end

const IDENTITY_TRANSFORM = GDSTransform(1.0, 0.0, false, (0.0, 0.0))

struct Boundary
    layer::Int
    datatype::Int
    xy::Vector{Tuple{Float64, Float64}}  # closed polygon (first == last)
end

struct Path
    layer::Int
    datatype::Int
    pathtype::Int            # 0 = flush, 1 = round, 2 = square extended
    width::Float64
    xy::Vector{Tuple{Float64, Float64}}
end

struct CellRef              # SREF
    cell_name::String
    transform::GDSTransform
end

struct ArrayRef             # AREF
    cell_name::String
    transform::GDSTransform
    rows::Int
    cols::Int
    row_spacing::Tuple{Float64, Float64}
    col_spacing::Tuple{Float64, Float64}
end

struct TextElement
    layer::Int
    texttype::Int
    text::String
    transform::GDSTransform
end

struct Cell
    name::String
    boundaries::Vector{Boundary}
    paths::Vector{Path}
    cell_refs::Vector{CellRef}
    array_refs::Vector{ArrayRef}
    texts::Vector{TextElement}
end

struct GDSLibrary
    name::String
    user_unit::Float64       # meters per user unit
    db_unit::Float64         # meters per database unit
    cells::Dict{String, Cell}
end
```

### Coordinate System

GDSII coordinates are stored as integer database units. The `db_unit` field (typically
`1e-9` m, i.e. 1 nm) converts to physical units. The parser will store coordinates as
`Float64` in database units; consumers multiply by `db_unit` to get meters, or by
`user_unit / db_unit` to get the user-defined unit (often micrometers).

---

## Phases

### Phase 1: GDSII Binary Parser

**Files**: `src/parser.jl`

Implement a streaming binary reader that walks the record sequence and populates the
`GDSLibrary` model.

#### Record Reading

```
Each record:
  bytes 0–1: record length (including the 4-byte header)
  bytes 2–3: {record_type (1 byte), data_type (1 byte)}
  bytes 4–(length-1): payload
```

Data types and their Julia mappings:

| Data type code | GDSII type       | Julia type      |
|----------------|------------------|-----------------|
| `0x00`         | No data          | —               |
| `0x01`         | Bit array        | `UInt16`        |
| `0x02`         | 2-byte int       | `Int16`         |
| `0x03`         | 4-byte int       | `Int32`         |
| `0x05`         | 8-byte real      | special (below) |
| `0x06`         | ASCII string     | `String`        |

GDSII 8-byte reals are a non-IEEE format (IBM hex floating point). A conversion function
must be implemented:

```julia
function gds_real_to_float64(bytes::NTuple{8, UInt8})::Float64
    sign = (bytes[1] & 0x80) != 0 ? -1.0 : 1.0
    exp  = Int(bytes[1] & 0x7F) - 64       # excess-64 base-16 exponent
    mantissa = 0.0
    for i in 2:8
        mantissa = (mantissa + bytes[i]) / 256.0
    end
    return sign * mantissa * 16.0^exp
end
```

#### Record Types to Handle

| Record       | Action                                                    |
|--------------|-----------------------------------------------------------|
| `HEADER`     | Validate version (should be 600)                          |
| `BGNLIB`     | Start library                                             |
| `LIBNAME`    | Store library name                                        |
| `UNITS`      | Read two 8-byte GDS reals: user_unit, db_unit             |
| `ENDLIB`     | Finish                                                    |
| `BGNSTR`     | Start a new `Cell`                                        |
| `STRNAME`    | Set cell name                                             |
| `ENDSTR`     | Finalize current cell, insert into library                |
| `BOUNDARY`   | Begin polygon element                                     |
| `PATH`       | Begin path element                                        |
| `SREF`       | Begin cell reference                                      |
| `AREF`       | Begin array reference                                     |
| `TEXT`       | Begin text element                                        |
| `ENDEL`      | End current element, push to cell                         |
| `LAYER`      | Set layer on current element                              |
| `DATATYPE`   | Set datatype on current element                           |
| `WIDTH`      | Set width on current path                                 |
| `PATHTYPE`   | Set pathtype on current path                              |
| `XY`         | Read coordinate list (pairs of Int32)                     |
| `SNAME`      | Set referenced structure name                             |
| `COLROW`     | Set cols and rows for AREF                                |
| `STRANS`     | Set transform flags (bit 15 = x-reflect)                  |
| `MAG`        | Set magnification                                         |
| `ANGLE`      | Set rotation angle                                        |
| `STRING`     | Set text content                                          |
| `TEXTTYPE`   | Set texttype on text element                              |

#### Public API

```julia
load_gds(path::AbstractString)::GDSLibrary
load_gds(io::IO)::GDSLibrary
```

### Phase 2: Hierarchy Flattening

**Files**: `src/flatten.jl`

The GDSII cell hierarchy must be resolved into a flat list of `(layer, polygon_points)`
pairs for rendering and meshing. Flattening respects the `GDSTransform` on each reference.

#### Transform Application

A `GDSTransform` encodes: magnification `m`, rotation angle `θ` (degrees), x-reflection
`r`, and translation origin `(tx, ty)`.

Applied to a point `(x, y)`:
1. Scale: `(mx, my)`
2. If `reflect_x`: negate y → `(mx, -my)`
3. Rotate by `θ`: standard 2D rotation matrix
4. Translate: add `(tx, ty)`

#### Path Expansion

A GDSII PATH with width `w` is expanded into a closed polygon by offsetting each segment
perpendicularly by `w/2`. Endcap style is determined by `pathtype`. This produces a
`Boundary`-equivalent polygon on the same layer.

#### Flat Geometry Output

```julia
struct FlatPolygon
    layer::Int
    datatype::Int
    points::Vector{Tuple{Float64, Float64}}  # in user units (micrometers typically)
end

function flatten(lib::GDSLibrary, top_cell::String)::Vector{FlatPolygon}
```

**Algorithm**:
- Recursive DFS starting at `top_cell`
- Maintain a cumulative `GDSTransform` stack (composed via matrix multiplication)
- For AREF: iterate over all `rows × cols` instances, computing per-instance translations
- Memoize flattened child cells in their own coordinate frame, then transform the result
  (avoids re-flattening shared cells)
- Detect cyclic references and error

### Phase 3: 2D Visualization

**Files**: `src/viz2d.jl`

Render all flat polygons grouped by layer as a 2D diagram using Makie.

#### Layer Color Map

Assign a deterministic color to each layer using a categorical color palette (e.g., 20
distinct colors cycling for layer indices). Support a user-provided `Dict{Int, RGBA}`
override.

#### Drawing

```julia
function draw2d(
    polygons::Vector{FlatPolygon};
    layer_colors::Dict{Int, Any} = auto_colors(polygons),
    visible_layers::Union{Nothing, Set{Int}} = nothing,
    backend = :gl,  # :gl | :wgl | :cairo
)::Figure
```

For each layer (in ascending order, so higher layers draw on top):
- Convert polygon point list to `GeometryBasics.Polygon`
- Use `Makie.poly!(ax, polygon; color=..., strokewidth=0.5, strokecolor=:black)`

Add a layer legend keyed by layer number. Support axis labels in micrometers.

#### Export

```julia
save_2d(path::AbstractString, polygons::Vector{FlatPolygon}; kwargs...)
```

Infer format from extension: `.png`, `.svg`, `.pdf` → use `CairoMakie`.

### Phase 4: 3D Mesh Generation

**Files**: `src/mesh3d.jl`

Generate a 3D solid mesh for each layer by triangulating 2D polygons and extruding them
between a bottom and top Z coordinate.

#### Layer Stack Definition

```julia
struct LayerSpec
    layer::Int
    datatype::Int           # -1 matches any
    z_min::Float64          # in same units as XY (e.g., micrometers)
    z_max::Float64
end

const DEFAULT_LAYER_STACK = LayerSpec[]  # empty → equal-spaced synthetic stack
```

The user provides a `Vector{LayerSpec}` that maps layer numbers to physical Z extents
(e.g., derived from a process design kit). If no stack is provided, layers are assigned
synthetic 1 µm thick slabs stacked at 1 µm intervals.

#### Triangulation

For each `FlatPolygon`:
1. Optionally remove duplicate or near-duplicate vertices
2. Use `EarCut.jl` for simple polygons (no holes, convex or concave)
3. Use `Triangulate.jl` with `"pa$(area)q20Q"` flags for complex polygons or those
   containing holes (holes are identified by containment testing with even-odd rule)
4. Output: `faces::Vector{Tuple{Int,Int,Int}}` indexing into `points`

#### Solid Extrusion

Given triangulated top face (points in XY, indices in `faces`), build the 3D solid:

1. **Top face**: emit each triangle as `(p[i], p[j], p[k])` at `z = z_max`
2. **Bottom face**: emit each triangle with reversed winding `(p[k], p[j], p[i])` at
   `z = z_min`
3. **Side walls**: walk the polygon boundary edges; for each edge `(a, b)`, emit two
   triangles forming the quad `(a_bot, b_bot, b_top, a_top)`:
   - Triangle 1: `(a_bot, b_bot, b_top)`
   - Triangle 2: `(a_bot, b_top, a_top)`

Output as `GeometryBasics.Mesh`.

```julia
function build_mesh(
    polygons::Vector{FlatPolygon},
    layer_stack::Vector{LayerSpec};
    quality::Bool = false,
)::Vector{Tuple{LayerSpec, GeometryBasics.Mesh}}
```

### Phase 5: 3D Visualization

**Files**: `src/viz3d.jl`

Render all layer meshes in a single interactive Makie 3D scene.

```julia
function draw3d(
    meshes::Vector{Tuple{LayerSpec, GeometryBasics.Mesh}};
    layer_colors::Dict{Int, Any} = auto_colors_3d(meshes),
    visible_layers::Union{Nothing, Set{Int}} = nothing,
    backend = :gl,
)::Figure
```

For each mesh:
```julia
mesh!(ax, m; color=color, transparency=false, shading=true)
```

Enable `Makie` 3D axis features: rotation, zoom, axis labels (X µm, Y µm, Z µm).

---

## Package Structure

```
semiflowviz/
├── Project.toml
├── src/
│   ├── SemiflowViz.jl      # module root, re-exports public API
│   ├── model.jl             # GDSLibrary, Cell, Boundary, etc.
│   ├── parser.jl            # load_gds()
│   ├── flatten.jl           # flatten(), path expansion, transform composition
│   ├── mesh3d.jl            # build_mesh(), LayerSpec
│   ├── viz2d.jl             # draw2d(), save_2d()
│   └── viz3d.jl             # draw3d()
├── test/
│   ├── runtests.jl
│   ├── test_parser.jl
│   ├── test_flatten.jl
│   └── test_mesh.jl
└── examples/
    ├── simple_inverter.jl   # end-to-end example with a small embedded GDS
    └── layer_stack.jl       # example with custom LayerSpec
```

### Project.toml Dependencies

```toml
[deps]
EarCut = "..."
GeometryBasics = "..."
Makie = "..."
Triangulate = "..."

[weakdeps]
CairoMakie = "..."
GLMakie = "..."
WGLMakie = "..."
```

CairoMakie/GLMakie/WGLMakie are weak dependencies so the package does not force a GUI
backend on users who only want mesh output.

---

## Implementation Order

| Step | Deliverable                                               | Key dependency          |
|------|-----------------------------------------------------------|-------------------------|
| 1    | `model.jl` — type definitions                            | none                    |
| 2    | `parser.jl` — binary reader, GDS real conversion         | none                    |
| 3    | Parser tests with a hand-crafted minimal GDS binary       | Step 2                  |
| 4    | `flatten.jl` — transform math, path expansion, DFS       | Steps 1–2               |
| 5    | Flatten tests: SREF, AREF, nested cells                  | Step 4                  |
| 6    | `viz2d.jl` — polygon rendering, layer colors             | Steps 4, Makie          |
| 7    | `mesh3d.jl` — triangulation, extrusion                   | Steps 4, EarCut/Triangulate, GeometryBasics |
| 8    | `viz3d.jl` — 3D scene, layer stack                       | Steps 7, Makie          |
| 9    | End-to-end example with a real GDS file                  | Steps 6–8               |
| 10   | Export: PNG/SVG/PDF for 2D, OBJ/STL for 3D               | Steps 6–8               |

---

## Key Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| GDSII files with deep cell hierarchies causing slow flatten | Cache flattened sub-cells in their local frame; apply transforms at reference site only |
| Large files (millions of polygons) overwhelming the renderer | Implement level-of-detail thinning (skip sub-pixel polygons) and optional layer filtering |
| Polygons with holes (e.g., ring structures) breaking ear-clip | Detect holes via containment; route to Triangulate.jl with hole points |
| Non-simple polygons (self-intersecting) from malformed GDS | Pre-process with polygon clipping (Clipper via Clipper2.jl if needed) |
| GDS files using GDSII version 3/5 (older variants) | Validate HEADER record version; emit clear error for unsupported versions |
| IBM hex float precision loss | Implement exact 64-bit conversion; add unit tests against known values |
