# SemiFlowViz Implementation Plan

## Goal

Build a Julia application that loads GDSII (Graphic Data System II) files and generates
2D and 3D diagrams suitable for mesh generation, targeting semiconductor device visualization.

---

## Library Research

### GDSII Parsing

| Library | Source | Status | Notes |
|---|---|---|---|
| **DeviceLayout.jl** | [aws-cqc/DeviceLayout.jl](https://github.com/aws-cqc/DeviceLayout.jl) | Registered (v1.9.0) | Full GDSII read/write via `src/backends/gds.jl`. Includes polygons, cells, references, coordinate systems, and units. Maintained by AWS. MIT License. |
| **GDS.jl** | [shobhan126/GDS.jl](https://github.com/shobhan126/GDS.jl) | Unregistered | Minimal GDSII reader. Parses record headers, structures, boundaries, paths, and references. Good reference for understanding the binary format but incomplete. |

**Recommendation:** Use **DeviceLayout.jl** for GDSII parsing. It is the most mature Julia GDSII
library, is registered in the General registry, actively maintained, and provides a complete
data model (cells, polygons, paths, references, coordinate transforms, units).

### Mesh Generation

| Library | Source | Notes |
|---|---|---|
| **Gmsh.jl** | Julia wrapper for [Gmsh](https://gmsh.info/) | Official Julia API for Gmsh. Supports 2D/3D mesh generation from geometry. Used by DeviceLayout.jl (compat `0.3.1`). Available via `gmsh_jll`. |
| **Meshes.jl** | [JuliaGeometry/Meshes.jl](https://github.com/JuliaGeometry/Meshes.jl) | Computational geometry in Julia (451 stars). Provides meshing algorithms, polygon operations, and geometry types. |
| **FerriteGmsh.jl** | [Ferrite-FEM/FerriteGmsh.jl](https://github.com/Ferrite-FEM/FerriteGmsh.jl) | Bridge between Gmsh meshes and Ferrite FEM framework. Useful if FEM simulation is needed later. |

**Recommendation:** Use **Gmsh.jl** as the primary mesh generator. It handles both 2D surface
meshes and 3D volume meshes, supports polygon input from GDSII, and integrates well with
DeviceLayout.jl. Use **Meshes.jl** for intermediate polygon/geometry operations.

### Visualization

| Library | Source | Notes |
|---|---|---|
| **Makie.jl** | [MakieOrg/Makie.jl](https://github.com/MakieOrg/Makie.jl) | Powerful 2D/3D visualization framework (2700+ stars). Backends: CairoMakie (static 2D), GLMakie (interactive 3D), WGLMakie (web). |
| **Cairo.jl** | Julia wrapper for Cairo | Used by DeviceLayout.jl for basic 2D rendering. Lightweight option for 2D-only output. |

**Recommendation:** Use **CairoMakie** for 2D diagrams and **GLMakie** for interactive 3D views.
Both share the Makie API, so code can target both backends easily.

### GDSII Format Overview

GDSII is a binary database format used in the semiconductor industry for IC layout data.
Key concepts:

- **Library**: Top-level container with units and metadata
- **Cell/Structure**: Named collection of geometric elements and references to other cells
- **Boundary**: Closed polygon (the primary geometric primitive)
- **Path**: Open polyline with width (used for wires/traces)
- **SRef/ARef**: Single/Array references to other cells (with transforms)
- **Layer/Datatype**: Integer pair identifying which fabrication layer a shape belongs to
- **Units**: User units and database units (typically nanometers)

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    SemiFlowViz.jl                    │
├──────────────┬──────────────┬───────────────────────┤
│  GDSLoader   │  MeshBuilder │  Visualizer           │
│              │              │                       │
│  Load GDSII  │  Convert     │  2D: CairoMakie       │
│  Parse cells │  polygons to │  3D: GLMakie           │
│  Extract     │  Gmsh geo    │                       │
│  polygons    │  Generate    │  Render layers         │
│  by layer    │  2D/3D mesh  │  Color by layer        │
│              │              │  Export images          │
└──────┬───────┴──────┬───────┴───────────┬───────────┘
       │              │                   │
  DeviceLayout.jl   Gmsh.jl          Makie.jl
```

---

## Phased Implementation Plan

### Phase 1: Project Setup & GDSII Loading (Current)

**Goal:** Load a GDSII file and extract polygon geometry organized by layer.

- [x] Research available Julia libraries
- [x] Initialize Julia project (`Project.toml`)
- [x] Create `src/SemiFlowViz.jl` — main module
- [x] Create `src/gds_loader.jl` — GDSII file loading using DeviceLayout.jl
  - `load_gds(filepath)` → parsed library structure
  - `extract_polygons(cell; layers=nothing)` → Dict of layer → polygon list
  - `list_cells(library)` → cell names
  - `list_layers(cell)` → unique layers present
  - `cell_bounding_box(cell)` → (min_xy, max_xy)
- [x] Create `test/runtests.jl` — basic tests
- [x] Create a small sample GDSII file for testing (via DeviceLayout.jl)

### Phase 2: 2D Visualization

**Goal:** Render 2D layer-by-layer diagrams from loaded GDSII data.

- [ ] Create `src/visualizer.jl` — 2D polygon rendering
  - `plot_cell_2d(cell; layers, colors)` → Makie figure
  - `save_plot(figure, path)` → export to PNG/SVG/PDF
- [ ] Layer coloring scheme (configurable color map per layer number)
- [ ] Support for rendering individual layers or all layers overlaid
- [ ] Add cell reference flattening (resolve SRef/ARef into polygons)

### Phase 3: Mesh Generation

**Goal:** Convert GDSII polygons into 2D surface meshes and 3D extruded meshes.

- [ ] Create `src/mesh_builder.jl` — polygon-to-mesh conversion
  - `build_mesh_2d(polygons; resolution)` → 2D triangulated mesh via Gmsh
  - `build_mesh_3d(polygons; layer_stack)` → extruded 3D mesh via Gmsh
- [ ] Define layer stack configuration (layer → z_min, z_max, material)
- [ ] Boolean operations on polygons (merge overlapping shapes per layer)
- [ ] Export meshes to standard formats (VTK, MSH, STL)

### Phase 4: 3D Visualization

**Goal:** Interactive 3D rendering of the extruded semiconductor structure.

- [ ] Create `src/visualizer_3d.jl` — 3D mesh rendering
  - `plot_mesh_3d(mesh; colors)` → interactive GLMakie scene
  - Camera controls, layer toggle, cross-section views
- [ ] Material/layer color mapping
- [ ] Cross-section and slice views

### Phase 5: Polish & Integration

- [ ] CLI interface for batch processing
- [ ] Configuration file for layer stack definitions
- [ ] Documentation (Documenter.jl)
- [ ] CI/CD pipeline (GitHub Actions)
- [ ] Performance optimization for large layouts

---

## Dependencies (Phase 1)

| Package | Version | Purpose |
|---|---|---|
| DeviceLayout | ~1.9 | GDSII file parsing, polygon/cell data model |

### Future Dependencies

| Package | Purpose |
|---|---|
| Gmsh | 2D/3D mesh generation |
| CairoMakie | 2D diagram rendering |
| GLMakie | 3D interactive visualization |
| Meshes | Intermediate geometry operations |
| Colors | Layer color schemes |
