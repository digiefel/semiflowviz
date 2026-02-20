export load_gds, list_cells, list_layers, extract_polygons, cell_bounding_box

"""
    load_gds(filepath::AbstractString; verbose=false) -> Dict{String, Cell}

Load a GDSII file and return a dictionary mapping cell names to `Cell` objects.

# Arguments
- `filepath`: Path to the `.gds` file.
- `verbose`: If `true`, print detailed parsing information.

# Returns
A `Dict{String, Cell}` where keys are cell names and values are `Cell` objects
containing polygons, references, and text annotations.

# Example
```julia
cells = load_gds("layout.gds")
```
"""
function load_gds(filepath::AbstractString; verbose::Bool=false)
    isfile(filepath) || throw(ArgumentError("File not found: $filepath"))
    endswith(lowercase(filepath), ".gds") ||
        @warn "File does not have .gds extension: $filepath"
    return FileIO.load(filepath; verbose=verbose)
end

"""
    list_cells(cells::Dict{String, <:Cell}) -> Vector{String}

Return a sorted list of cell names from a loaded GDSII file.

# Example
```julia
cells = load_gds("layout.gds")
names = list_cells(cells)
```
"""
function list_cells(cells::Dict{String, <:Cell})
    return sort(collect(keys(cells)))
end

"""
    list_layers(cell::Cell) -> Vector{Int}

Return a sorted list of unique GDS layer numbers present in a cell.
Only considers direct elements of the cell, not referenced sub-cells.

# Example
```julia
cells = load_gds("layout.gds")
layers = list_layers(cells["top"])
```
"""
function list_layers(cell::Cell)
    meta = element_metadata(cell)
    isempty(meta) && return Int[]
    layer_nums = unique(map(m -> gdslayer(m), meta))
    return sort(layer_nums)
end

"""
    extract_polygons(cell::Cell; layers=nothing, flatten_refs=false) -> Dict{Int, Vector{Vector{Tuple{Float64, Float64}}}}

Extract polygons from a cell, organized by GDS layer number.

Each polygon is represented as a vector of `(x, y)` coordinate tuples.

# Arguments
- `cell`: The `Cell` to extract polygons from.
- `layers`: Optional collection of layer numbers to filter. If `nothing`, all layers are returned.
- `flatten_refs`: If `true`, resolve all cell references (SRef/ARef) into polygons first.

# Returns
A `Dict` mapping layer numbers to vectors of polygons, where each polygon is a
`Vector{Tuple{Float64, Float64}}`.

# Example
```julia
cells = load_gds("layout.gds")
polys = extract_polygons(cells["top"]; layers=[1, 2], flatten_refs=true)
for (layer, polygons) in polys
    println("Layer \$layer: \$(length(polygons)) polygons")
end
```
"""
function extract_polygons(cell::Cell; layers=nothing, flatten_refs::Bool=false)
    if flatten_refs
        cell = copy(cell)
        flatten!(cell)
    end

    result = Dict{Int, Vector{Vector{Tuple{Float64, Float64}}}}()
    elems = elements(cell)
    meta = element_metadata(cell)

    for (poly, m) in zip(elems, meta)
        layer_num = gdslayer(m)

        if !isnothing(layers) && !(layer_num in layers)
            continue
        end

        pts = points(poly)
        coords = [(Float64(ustrip(getx(p))), Float64(ustrip(gety(p)))) for p in pts]

        if !haskey(result, layer_num)
            result[layer_num] = Vector{Tuple{Float64, Float64}}[]
        end
        push!(result[layer_num], coords)
    end

    return result
end

"""
    cell_bounding_box(cell::Cell) -> Tuple{Tuple{Float64, Float64}, Tuple{Float64, Float64}}

Compute the bounding box of all elements in a cell.

# Returns
A tuple `((min_x, min_y), (max_x, max_y))` in the cell's coordinate units
(stripped to Float64).

Returns `((0.0, 0.0), (0.0, 0.0))` if the cell has no elements.

# Example
```julia
cells = load_gds("layout.gds")
(min_xy, max_xy) = cell_bounding_box(cells["top"])
```
"""
function cell_bounding_box(cell::Cell)
    elems = elements(cell)
    isempty(elems) && return ((0.0, 0.0), (0.0, 0.0))

    ll = lowerleft(bounds(elems[1]))
    ur = upperright(bounds(elems[1]))
    min_x = Float64(ustrip(getx(ll)))
    min_y = Float64(ustrip(gety(ll)))
    max_x = Float64(ustrip(getx(ur)))
    max_y = Float64(ustrip(gety(ur)))

    for poly in elems[2:end]
        ll = lowerleft(bounds(poly))
        ur = upperright(bounds(poly))
        min_x = min(min_x, Float64(ustrip(getx(ll))))
        min_y = min(min_y, Float64(ustrip(gety(ll))))
        max_x = max(max_x, Float64(ustrip(getx(ur))))
        max_y = max(max_y, Float64(ustrip(gety(ur))))
    end

    return ((min_x, min_y), (max_x, max_y))
end
