using ElectricityNetworkReduction
using DataFrames
using SparseArrays
using Test

# DC Laplacian wrapped as -im * B, the convention used by form_dc_ybus.
function dc_network(n, branches)
    B = zeros(n, n)
    for (i, j, b) in branches
        B[i, i] += b
        B[j, j] += b
        B[i, j] -= b
        B[j, i] -= b
    end
    return sparse(-im * B)
end

@testset "Kron reduction keeping every bus" begin
    Y = dc_network(3, [(1, 2, 2.0), (2, 3, 4.0), (1, 3, 1.0)])
    @test kron_reduce_ybus(Y, [1, 2, 3]) == Y
    @test kron_reduce_ybus(Y, [3, 1, 2]) == Y[[3, 1, 2], [3, 1, 2]]
    @test_throws ErrorException kron_reduce_ybus(Y, [1, 1, 2])
end

@testset "Virtual-line filter keeps a consistent network" begin
    # Bus ids 10, 20, 30; only (10, 20) and (20, 30) are allowed.
    Y = dc_network(3, [(1, 2, 2.0), (2, 3, 4.0), (1, 3, 1.0)])
    Yf = filter_reduced_network(Y, [10, 20, 30], Set([(10, 20), (20, 30)]))
    B = -imag(Matrix(Yf))
    @test B[1, 3] == 0 && B[3, 1] == 0                  # virtual line removed
    @test B[1, 2] == -2.0 && B[2, 3] == -4.0            # kept lines unchanged
    @test maximum(abs, sum(B; dims = 2)) < 1e-12        # still a DC Laplacian

    # Nothing allowed → unfiltered network is kept
    @test (@test_logs (:warn,) match_mode = :any filter_reduced_network(
        Y,
        [10, 20, 30],
        Set{Tuple{Int,Int}}(),
    )) == Y
end

@testset "Equivalent TTC is min C/|PTDF| for every optimisation type" begin
    # Triangle network; PTDFs from the package's own reduced-network routine.
    Y = dc_network(3, [(1, 2, 2.0), (2, 3, 4.0), (1, 3, 1.0)])
    ptdf = calculate_ptdfs_reduced(Y, [1, 2, 3])
    ttc_original = DataFrame(
        transaction_from = [1, 1, 2],
        transaction_to = [2, 3, 3],
        TTC_pu = [1.0, 2.0, 1.5],
        TTC_AC_pu = [1.0, 2.0, 1.5],
        TTC_DC_pu = [0.0, 0.0, 0.0],
    )

    for type in ("QP", "LP", "MIQP")
        caps, ttc_eq = optimise_equivalent_capacities(ttc_original, ptdf; Type = type)
        cap = Dict(
            minmax(r.synth_line_from, r.synth_line_to) => r.C_eq_pu for r in eachrow(caps)
        )
        for r in eachrow(ttc_eq)
            rows = filter(
                p ->
                    p.transaction_from_orig == r.transaction_from &&
                    p.transaction_to_orig == r.transaction_to &&
                    abs(p.PTDF_value) > 1e-6,
                ptdf,
            )
            expected = minimum(
                cap[minmax(p.synth_line_from, p.synth_line_to)] / abs(p.PTDF_value) for
                p in eachrow(rows)
            )
            @test r.TTC_Equivalent_pu ≈ expected rtol = 1e-9
        end
    end
end

@testset "TTC reporting without finite transactions" begin
    ttc = DataFrame(
        transaction_from = [1],
        transaction_to = [2],
        TTC_pu = [Inf],
        TTC_AC_pu = [Inf],
        TTC_DC_pu = [0.0],
    )
    result = ElectricityNetworkReduction.create_ttc_results_from_optimisation([Inf], ttc)
    @test result.TTC_Equivalent_pu == [Inf]
end

@testset "Converter ratings limit DC capacity" begin
    reset_config!()
    CONFIG.bus_names_as_int = true
    dclines = DataFrame(
        From_node = [1001, 1001, 1003],
        To_node = [1002, 1002, 1004],
        Capacity_MW = [100, 100, 500],
    )
    dclines[!, :Capacity_pu] = dclines.Capacity_MW ./ 100
    converters = DataFrame(
        Converter_id = ["C1", "C2", "C3", "C4"],
        From_node = [1001, 1002, 1003, 1004],
        To_node = [1, 4, 2, 4],
        Voltage_level = [230, 230, 230, 230],
        Capacity_MW = [150, 120, 300, 1000],
    )

    process_converters(converters)   # cleans names, as in the pipeline
    apply_converter_limits!(dclines, converters, 100.0)
    @test dclines.Capacity_MW == [100.0, 100.0, 300.0]   # line 3 limited by C3
    @test dclines.Capacity_pu == [1.0, 1.0, 3.0]

    remap_dc_endpoints!(dclines, build_converter_map(converters))
    @test dclines.From_node == ["1", "1", "2"]           # Int bus names remapped
    @test dclines.To_node == ["4", "4", "4"]
    dclines[!, :From] = parse.(Int, dclines.From_node)
    dclines[!, :To] = parse.(Int, dclines.To_node)

    node_info = DataFrame(new_id = 1:5, Zone = ["A", "A", "B", "B", "C"])
    dc_cap_map = build_dc_capacity_map(
        dclines,
        node_info,
        [1, 4];
        lines_df = DataFrame(From = [1, 2], To = [2, 5]),
        tielines_df = DataFrame(From = [3], To = [4]),
    )
    # All three lines map to representative pair (1, 4): 100 + 100 + 300 MW.
    # The two parallel cables share C1 (150 MW) on the bus-1 side, so that
    # side carries at most C1 + C3 = 450 MW (the bus-4 side allows
    # C2 + C4 = 1120 MW). The pair is capped at 450 MW.
    @test dc_cap_map[(1, 4)] ≈ 4.5
    reset_config!()
end

@testset "Manual selection keeps high-res zones and island coverage" begin
    reset_config!()
    CONFIG.rep_node_mode = "manual_excel"
    CONFIG.high_res_zones = ["A"]
    # Islands {1, 2, 3} and {4, 5}; only bus 3 is flagged in the Excel column.
    node_info = DataFrame(
        new_id = 1:5,
        old_name = string.(1:5),
        Zone = ["A", "A", "B", "B", "C"],
        Area = fill("X", 5),
        IsRepresentative = [false, false, true, false, false],
    )
    lines = DataFrame(
        From = [1, 2, 4],
        To = [2, 3, 5],
        X_pu = [0.1, 0.1, 0.1],
        Capacity_pu = [1.0, 1.0, 1.0],
    )
    Y = form_dc_ybus(lines, DataFrame(), node_info, 100.0)
    reps, _ = (@test_logs (:warn,) match_mode = :any select_representative_nodes(
        Y,
        node_info,
        lines,
        DataFrame(),
    ))
    ids = Set(reps.new_id)
    @test issubset(Set([1, 2, 3]), ids)          # high-res zone A + manual bus 3
    @test length(ids) == 4 && !isempty(intersect(ids, Set([4, 5])))   # island forced
    reset_config!()
end
