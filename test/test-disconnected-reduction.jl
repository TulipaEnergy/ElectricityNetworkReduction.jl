using ElectricityNetworkReduction, DataFrames, SparseArrays, Test

@testset "Disconnected reduced transactions have no AC transfer" begin
    Y = sparse(-im * [1.0 -1 0 0; -1 1 0 0; 0 0 1 -1; 0 0 -1 1])
    ptdf = calculate_ptdfs_reduced(Y, [1, 2, 3, 4])
    @test !any(
        r -> r.transaction_from_orig == 2 && r.transaction_to_orig == 4,
        eachrow(ptdf),
    )
    target = DataFrame(
        transaction_from = [2],
        transaction_to = [4],
        TTC_pu = [1.0],
        TTC_AC_pu = [1.0],
        TTC_DC_pu = [0.0],
    )
    for mode in ("QP", "LP", "MIQP")
        _, result = optimise_equivalent_capacities(
            target,
            ptdf;
            Type = mode,
            rep_node_ids = [1, 2, 3, 4],
            reduced_ybus = Y,
        )
        @test result.TTC_Equivalent_pu == [0.0]
    end
    _, result = optimise_equivalent_capacities(
        target,
        ptdf;
        Type = "LP",
        rep_node_ids = [1, 2, 3, 4],
        reduced_ybus = Y,
        dc_cap_map = Dict((2, 4) => 0.4),
    )
    @test result.TTC_Equivalent_pu == [0.4]
end

@testset "DC-only reduced network needs no synthetic AC lines" begin
    Y = spzeros(ComplexF64, 2, 2)
    ptdf = calculate_ptdfs_reduced(Y, [1, 2])
    target = DataFrame(
        transaction_from = [1],
        transaction_to = [2],
        TTC_pu = [0.4],
        TTC_AC_pu = [Inf],
        TTC_DC_pu = [0.4],
    )
    for mode in ("QP", "LP", "MIQP")
        caps, result = optimise_equivalent_capacities(
            target,
            ptdf;
            Type = mode,
            rep_node_ids = [1, 2],
            reduced_ybus = Y,
            dc_cap_map = Dict((1, 2) => 0.4),
        )
        @test isempty(caps)
        @test result.TTC_Equivalent_pu == [0.4]
    end
end

@testset "Every retained bus may be high resolution" begin
    Y = sparse(-im * [1.0 -1 0; -1 2 -1; 0 -1 1])
    ids = [1, 2, 3]
    hires = Set(ids)
    ptdf = calculate_ptdfs_reduced(Y, ids; high_res_ids = hires)
    @test nrow(ptdf) > 0
    target = DataFrame(
        transaction_from = [1, 1, 2],
        transaction_to = [2, 3, 3],
        TTC_pu = [1.0, 1.0, 2.0],
        TTC_AC_pu = [1.0, 1.0, 2.0],
        TTC_DC_pu = zeros(3),
    )
    for mode in ("QP", "LP", "MIQP")
        caps, result = optimise_equivalent_capacities(
            target,
            ptdf;
            Type = mode,
            rep_node_ids = ids,
            reduced_ybus = Y,
            high_res_node_ids = hires,
            phys_line_caps = Dict((1, 2) => 1.0, (2, 3) => 2.0),
        )
        @test sort(caps.C_eq_pu) ≈ [1.0, 2.0]
        @test result.TTC_Equivalent_pu ≈ target.TTC_pu
    end
end
