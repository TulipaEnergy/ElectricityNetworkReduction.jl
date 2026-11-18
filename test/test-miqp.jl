using ElectricityNetworkReduction, JuMP, SCIP, Test

@testset "MIQP relative objective and conservative binding" begin
    @test ElectricityNetworkReduction.Config().miqp_optimizer === SCIP.Optimizer
    # Two transfers share the same limiting branch. Conservativeness requires
    # both fitted TTCs <= 1, so the exact relative squared error is 0.25.
    targets = [1.0, 2.0]
    ptdf = Dict((1, 1) => 1.0, (2, 1) => 1.0)
    model, fitted, _ = ElectricityNetworkReduction._solve_miqp_model(
        targets,
        [(1, 2)],
        1:1,
        1:2,
        ptdf,
        [[1], [1]],
        [[1, 2]],
    )
    @test occursin("SCIP", solver_name(model))
    @test fitted ≈ [1.0, 1.0] atol = 1e-6
    @test objective_value(model) ≈ 0.25 atol = 1e-6
    @test all(fitted .<= targets .+ 1e-6)
    @test ElectricityNetworkReduction._capacity_values(model) ≈ [1.0] atol = 1e-6
    @test model.ext[:solver_diagnostics].binding_candidates_per_txn == 0
end

@testset "MIQP closure keeps weak branch ratings usable" begin
    ptdf = Dict((1, 1) => 1.0)
    full = Dict((1, 1) => 1.0, (1, 2) => 1e-8)
    model, fitted, _ = ElectricityNetworkReduction._solve_miqp_model(
        [1.0],
        [(1, 2), (2, 3)],
        1:2,
        1:1,
        ptdf,
        [[1]],
        [[1], Int[]];
        ptdf_full = full,
        relevant_lines_full_per_txn = [[1, 2]],
    )
    caps = ElectricityNetworkReduction._capacity_values(model)
    @test caps[2] > 0
    @test caps[2] ≈ fitted[1] * 1e-8 rtol = 1e-6
    @test minimum(caps[l] / full[(1, l)] for l = 1:2) ≈ fitted[1] atol = 1e-6
end
