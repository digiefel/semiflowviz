using Test
using SemiFlowViz
using DeviceLayout
using FileIO

# Helper: create a minimal GDS file for testing using DeviceLayout
function create_test_gds(filepath::String)
    c = Cell("test_cell", DeviceLayout.nm)

    # Add a rectangle on layer 1
    rect = Rectangle(1000.0DeviceLayout.nm, 500.0DeviceLayout.nm)
    render!(c, rect, GDSMeta(1, 0))

    # Add a polygon on layer 2
    poly = Polygon(
        Point(0.0DeviceLayout.nm, 0.0DeviceLayout.nm),
        Point(100.0DeviceLayout.nm, 0.0DeviceLayout.nm),
        Point(100.0DeviceLayout.nm, 200.0DeviceLayout.nm),
        Point(0.0DeviceLayout.nm, 200.0DeviceLayout.nm)
    )
    render!(c, poly, GDSMeta(2, 0))

    # Add another polygon on layer 1
    rect2 = Rectangle(200.0DeviceLayout.nm, 300.0DeviceLayout.nm)
    render!(c, rect2, GDSMeta(1, 0))

    # Create a second cell
    c2 = Cell("sub_cell", DeviceLayout.nm)
    render!(c2, Rectangle(50.0DeviceLayout.nm, 50.0DeviceLayout.nm), GDSMeta(3, 0))

    # Save
    save(filepath, c, c2)
    return filepath
end

@testset "SemiFlowViz" begin
    # Create a temporary GDS file for testing
    test_gds = tempname() * ".gds"
    create_test_gds(test_gds)

    @testset "load_gds" begin
        cells = load_gds(test_gds)
        @test cells isa Dict{String, <:Cell}
        @test length(cells) >= 2
        @test haskey(cells, "test_cell")
        @test haskey(cells, "sub_cell")
    end

    @testset "load_gds errors" begin
        @test_throws ArgumentError load_gds("nonexistent_file.gds")
    end

    @testset "list_cells" begin
        cells = load_gds(test_gds)
        names = list_cells(cells)
        @test names isa Vector{String}
        @test "test_cell" in names
        @test "sub_cell" in names
        @test issorted(names)
    end

    @testset "list_layers" begin
        cells = load_gds(test_gds)
        layers = list_layers(cells["test_cell"])
        @test layers isa Vector{Int}
        @test 1 in layers
        @test 2 in layers
        @test issorted(layers)

        layers_sub = list_layers(cells["sub_cell"])
        @test 3 in layers_sub
    end

    @testset "extract_polygons" begin
        cells = load_gds(test_gds)
        cell = cells["test_cell"]

        # Extract all layers
        polys = extract_polygons(cell)
        @test polys isa Dict{Int, Vector{Vector{Tuple{Float64, Float64}}}}
        @test haskey(polys, 1)
        @test haskey(polys, 2)
        @test length(polys[1]) == 2  # two shapes on layer 1
        @test length(polys[2]) == 1  # one shape on layer 2

        # Filter by layer
        polys_l1 = extract_polygons(cell; layers=[1])
        @test haskey(polys_l1, 1)
        @test !haskey(polys_l1, 2)
        @test length(polys_l1[1]) == 2

        # Each polygon should be a vector of (x, y) tuples
        for (layer, layer_polys) in polys
            for p in layer_polys
                @test p isa Vector{Tuple{Float64, Float64}}
                @test length(p) >= 3  # at least a triangle
            end
        end
    end

    @testset "cell_bounding_box" begin
        cells = load_gds(test_gds)
        cell = cells["test_cell"]

        (min_xy, max_xy) = cell_bounding_box(cell)
        @test min_xy isa Tuple{Float64, Float64}
        @test max_xy isa Tuple{Float64, Float64}
        @test max_xy[1] >= min_xy[1]
        @test max_xy[2] >= min_xy[2]
    end

    @testset "cell_bounding_box empty cell" begin
        empty_cell = Cell("empty", DeviceLayout.nm)
        (min_xy, max_xy) = cell_bounding_box(empty_cell)
        @test min_xy == (0.0, 0.0)
        @test max_xy == (0.0, 0.0)
    end

    # Cleanup
    rm(test_gds; force=true)
end
