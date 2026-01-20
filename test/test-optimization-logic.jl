using NetworkReduction
using Test
using DataFrames

@testset "Optimization Logic: LP, QP, and MIQP" begin
    # Make sure PTDF entries are not filtered out by epsilon
    NetworkReduction.CONFIG.ptdf_epsilon = 1e-9

    # 1) Minimal synthetic TTC input
    ttc_orig = DataFrame(
        transaction_from = [1, 1],
        transaction_to = [2, 3],
        TTC_pu = [100.0, 150.0],
    )

    # 2) Minimal synthetic PTDF results
    ptdf_results = DataFrame(
        transaction_from_orig = [1, 1, 1, 1],
        transaction_to_orig = [2, 2, 3, 3],
        synth_line_from = [1, 2, 1, 2],
        synth_line_to = [2, 3, 2, 3],
        PTDF_value = [0.6, 0.4, 0.3, 0.7],
    )

    opt_variants = [
        (type = "QP", desc = "Quadratic Programming (Smooth matching)"),
        (type = "LP", desc = "Linear Programming (Max throughput)"),
        (type = "MIQP", desc = "MILP (Binding line logic)"),
    ]

    for variant in opt_variants
        @testset "$(variant.desc)" begin
            caps, ttc_res = optimize_equivalent_capacities(
                ttc_orig,
                ptdf_results;
                Type = variant.type,
                lambda = 0.001,
                bigM_factor = 5.0,
            )

            @test caps isa DataFrame
            @test ttc_res isa DataFrame
            @test nrow(ttc_res) == nrow(ttc_orig)

            # Capacities must be non-negative (handle different column names)
            if hasproperty(caps, :C_eq_pu)
                @test all(caps.C_eq_pu .>= 0)
            elseif hasproperty(caps, :capacity_pu)
                @test all(caps.capacity_pu .>= 0)
            elseif hasproperty(caps, :capacity_MW)
                @test all(caps.capacity_MW .>= 0)
            else
                @test false
            end
        end
    end

    # 3) Error handling branch coverage
    @testset "Invalid solver type" begin
        @test_throws ErrorException optimize_equivalent_capacities(
            ttc_orig,
            ptdf_results;
            Type = "NON_EXISTENT_SOLVER",
        )
    end
end
