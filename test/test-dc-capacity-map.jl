using ElectricityNetworkReduction
using DataFrames
using Test

@testset "component-aware DC capacity mapping" begin
    node_info = DataFrame(new_id = 1:5, Zone = ["A", "A", "A", "B", "B"])
    lines = DataFrame(From = [1], To = [2])
    tielines = DataFrame(From = [4], To = [5])
    dclines = DataFrame(
        From = [1, 2, 3, 3],
        To = [2, 3, 4, 5],
        Capacity_pu = [1.0, 2.0, 3.0, 4.0],
    )

    dc_cap_map = build_dc_capacity_map(
        dclines,
        node_info,
        [1, 3, 4];
        lines_df = lines,
        tielines_df = tielines,
    )

    @test length(dc_cap_map) == 2
    @test !haskey(dc_cap_map, (1, 1))
    @test dc_cap_map[(1, 3)] == 2.0
    @test dc_cap_map[(3, 4)] == 7.0
end
