# SemiFlowViz

A Julia package for generating 2D and 3D diagrams from GDSII semiconductor layout files.

## Overview

SemiFlowViz loads GDSII files (the standard binary format for IC layout data) and provides
tools for extracting geometry, generating meshes, and creating visualizations of
semiconductor device structures.

## Features (Phase 1 — Current)

- **GDSII Loading**: Parse `.gds` files via [DeviceLayout.jl](https://github.com/aws-cqc/DeviceLayout.jl)
- **Cell Inspection**: List cells, layers, and bounding boxes
- **Polygon Extraction**: Extract polygon geometry organized by GDS layer, with optional reference flattening

## Quick Start

```julia
using SemiFlowViz

# Load a GDSII file
cells = load_gds("my_layout.gds")

# List all cells
println(list_cells(cells))

# Inspect layers in a cell
println(list_layers(cells["top_cell"]))

# Extract polygons (optionally filter by layer, flatten references)
polygons = extract_polygons(cells["top_cell"]; layers=[1, 2], flatten_refs=true)

# Get bounding box
(min_xy, max_xy) = cell_bounding_box(cells["top_cell"])
```

## Roadmap

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full development plan:

1. ✅ **Phase 1**: Project setup & GDSII loading
2. 🔲 **Phase 2**: 2D visualization (CairoMakie)
3. 🔲 **Phase 3**: Mesh generation (Gmsh)
4. 🔲 **Phase 4**: 3D visualization (GLMakie)
5. 🔲 **Phase 5**: Polish & integration

## Installation

```julia
using Pkg
Pkg.develop(path="path/to/semiflowviz")
```

## Testing

```julia
using Pkg
Pkg.test("SemiFlowViz")
```
