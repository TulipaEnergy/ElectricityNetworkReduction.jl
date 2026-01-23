using NetworkReduction
using Test
using DataFrames

# --- 1. CONFIG TESTING ---

@testset "Config Testing" begin
    @test isdefined(NetworkReduction, :CONFIG)
    @test NetworkReduction.CONFIG isa NetworkReduction.Config

    # These must match your actual defaults; adjust if needed
    @test NetworkReduction.CONFIG.base == 100.0

    @test_nowarn NetworkReduction.print_config()
end


# --- 2. OPTIMIZATION VARIANTS ---
@testset "Optimization Logic: LP, QP, and MIQP" begin
    # Ensure PTDF entries aren't dropped
    NetworkReduction.CONFIG.ptdf_epsilon = 1e-9

    ttc_orig = DataFrame(
        transaction_from = [1, 1],
        transaction_to = [2, 3],
        TTC_pu = [100.0, 150.0],
    )

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
            caps, ttc_res = NetworkReduction.optimize_equivalent_capacities(
                ttc_orig,
                ptdf_results;
                Type = variant.type,
                lambda = 0.001,
                bigM_factor = 5.0,
            )

            @test caps isa DataFrame
            @test ttc_res isa DataFrame
            @test nrow(ttc_res) == nrow(ttc_orig)

            # capacities must be non-negative (handle possible column names)
            if hasproperty(caps, :C_eq_pu)
                @test all(caps.C_eq_pu .>= 0)
            elseif hasproperty(caps, :capacity_pu)
                @test all(caps.capacity_pu .>= 0)
            elseif hasproperty(caps, :capacity_MW)
                @test all(caps.capacity_MW .>= 0)
            else
                @test false  # schema changed unexpectedly
            end
        end
    end
end
