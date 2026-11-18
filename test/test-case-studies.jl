using ElectricityNetworkReduction
using Test
using CSV
using DataFrames
using LinearAlgebra

const CASE_DEFAULTS = (
    int_bus = false,
    pu = false,
    opt = "QP",
    has_dc = false,
    has_transformers = false,
    has_converters = false,
    allow_virtual_lines = false,
    rep_mode = "auto",
    high_res = String[],
    full_resolution = false,
    # Reference cases also exercise plotting. All outputs use temporary folders.
    reference = true,
    label = "",
)
case_study(name; kw...) =
    merge(CASE_DEFAULTS, (name = name, file = "$name.xlsx"), (; kw...))

# Case studies run by the batch test. case_EU is deliberately excluded because
# it is too large for routine testing; run it manually via main_full_analysis
# with its input folder in test/inputs/case_EU.
test_suites = [
    case_study("case_NL"),
    case_study("case6"; int_bus = true, pu = true),
    case_study("case39"; int_bus = true, pu = true),
    case_study("case118"),
    case_study("case_ACTIVSg2000"; int_bus = true, pu = true),
    # case6 extended with DC lines (one DC-only island), converters (one pair
    # capped by a shared converter) and transformers.
    case_study(
        "case6_dc";
        int_bus = true,
        pu = true,
        has_dc = true,
        has_transformers = true,
        has_converters = true,
    ),
    # Variants covering the other optimisation types and selection modes.
    case_study("case6"; int_bus = true, pu = true, opt = "LP", reference = false),
    case_study("case6"; int_bus = true, pu = true, opt = "MIQP", reference = false),
    case_study("case39"; int_bus = true, pu = true, opt = "LP", reference = false),
    case_study("case39"; int_bus = true, pu = true, opt = "MIQP", reference = false),
    case_study("case118"; opt = "MIQP", reference = false),
    case_study("case_NL"; opt = "MIQP", reference = false),
    case_study(
        "case6_dc";
        int_bus = true,
        pu = true,
        opt = "MIQP",
        has_dc = true,
        has_transformers = true,
        has_converters = true,
        reference = false,
    ),
    case_study(
        "case_NL";
        opt = "MIQP",
        rep_mode = "manual_excel",
        high_res = ["Zeeland"],
        reference = false,
        label = "_MANUAL_HR",
    ),
    case_study(
        "case6";
        int_bus = true,
        pu = true,
        full_resolution = true,
        reference = false,
        label = "_FULL_RES",
    ),
    case_study(
        "case118";
        allow_virtual_lines = true,
        reference = false,
        label = "_VIRTUAL",
    ),
    case_study(
        "case_NL";
        rep_mode = "manual_excel",
        high_res = ["Zeeland"],
        reference = false,
        label = "_MANUAL_HR",
    ),
]

"""
    exported_network_ttc(output_dir, suffix)

Independent check of the reported equivalent TTC. Rebuilds the exported
equivalent network from `Equivalent_Capacities` (reactances and capacities of
the AC synthetic lines), solves DC power flow on it for every representative
transaction and returns `TTC = min C/|flow| + DC` keyed by `(from, to)` bus id,
in pu. Shares no code with the pipeline's own TTC evaluation.
"""
function exported_network_ttc(
    output_dir,
    suffix;
    eps = CONFIG.optimisation_type == "MIQP" ? 1e-10 : CONFIG.ptdf_epsilon,
)
    rd(f) = CSV.read(joinpath(output_dir, "$(f)_$(suffix).csv"), DataFrame)
    eq = rd("Equivalent_Capacities")
    orig = rd("TTC_Original_Network")
    ac = filter(r -> !r.is_dc && r.X_pu != 0, eq)

    nodes = sort(unique(vcat(orig.transaction_from, orig.transaction_to)))
    idx = Dict(n => i for (i, n) in enumerate(nodes))
    n = length(nodes)
    lines = [(idx[r.from], idx[r.to], 1 / r.X_pu, r.capacity_pu) for r in eachrow(ac)]

    # AC islands of the exported network (one grounded bus each)
    adj = [Int[] for _ = 1:n]
    for (i, j, _, _) in lines
        push!(adj[i], j)
        push!(adj[j], i)
    end
    comp = zeros(Int, n)
    for s = 1:n
        comp[s] == 0 || continue
        comp[s] = s
        queue = [s]
        while !isempty(queue)
            u = popfirst!(queue)
            for v in adj[u]
                comp[v] == 0 && (comp[v] = s; push!(queue, v))
            end
        end
    end

    B = zeros(n, n)
    for (i, j, b, _) in lines
        B[i, i] += b
        B[j, j] += b
        B[i, j] -= b
        B[j, i] -= b
    end
    for i = 1:n
        comp[i] == i && (B[i, i] += 1.0)   # ground the first bus of each island
    end
    F = lu(B)

    ttc = Dict{Tuple{Int,Int},Float64}()
    for r in eachrow(orig)
        a, b = r.transaction_from, r.transaction_to
        dc = r.TTC_DC_MW / CONFIG.base
        if !isfinite(r.TTC_AC_MW)
            ttc[(a, b)] = dc > 0 ? dc : Inf
            continue
        end
        ac_ttc = 0.0   # no AC path in the exported network
        if comp[idx[a]] == comp[idx[b]]
            p = zeros(n)
            p[idx[a]], p[idx[b]] = 1.0, -1.0
            θ = F \ p
            limits = [
                cap / abs(bij * (θ[i] - θ[j])) for
                (i, j, bij, cap) in lines if abs(bij * (θ[i] - θ[j])) > eps
            ]
            isempty(limits) || (ac_ttc = minimum(limits))
        end
        ttc[(a, b)] = ac_ttc + dc
    end
    return ttc
end

@testset "Batch Network Reduction Tests" begin
    for case in test_suites
        input_path = joinpath(INPUT_FOLDER, case.name, case.file)

        # Skip case studies whose input data is not present (e.g. private datasets)
        if !isfile(input_path)
            @info "Skipping $(case.name): input file not found at $input_path"
            continue
        end

        @testset "Case Study: $(case.name) $(case.opt)$(case.label)" begin

            # --- PREPARATION ---
            reset_config!() # Resets CONFIG to defaults
            CONFIG.case_study = case.name
            CONFIG.input_filename = case.file
            CONFIG.bus_names_as_int = case.int_bus
            CONFIG.in_pu = case.pu
            CONFIG.optimisation_type = case.opt
            CONFIG.suffix = "TEST_$(case.opt)$(case.label)"
            CONFIG.has_dc_lines = case.has_dc
            CONFIG.has_transformers = case.has_transformers
            CONFIG.has_converters = case.has_converters
            CONFIG.allow_virtual_lines = case.allow_virtual_lines
            CONFIG.rep_node_mode = case.rep_mode
            CONFIG.high_res_zones = case.high_res
            if case.full_resolution
                CONFIG.high_res_zones =
                    string.(unique(load_excel_data(input_path)["nodes"].Zone))
            end
            CONFIG.enable_plots =
                case.reference && get(ENV, "ENR_TEST_PLOTS", "true") == "true"

            input_dir = joinpath(INPUT_FOLDER, case.name)
            # Validation must not overwrite the versioned reference results in
            # test/outputs, unless they are deliberately refreshed.
            update_reference =
                case.reference &&
                get(ENV, "ENR_UPDATE_REFERENCE_OUTPUTS", "false") == "true"
            output_dir = update_reference ? joinpath(OUTPUT_FOLDER, case.name) : mktempdir()

            # --- 1. RUN THE ANALYSIS ---
            @test begin
                main_full_analysis(input_dir, output_dir)
                true
            end

            # --- 2. EQUIVALENT CAPACITIES STRUCTURAL CHECK ---
            @testset "Equivalent Capacities Check" begin
                path = joinpath(output_dir, "Equivalent_Capacities_$(CONFIG.suffix).csv")
                @test isfile(path)
                df = CSV.read(path, DataFrame)
                @test size(df, 1) > 0

                # Check column names
                @test hasproperty(df, :from) || hasproperty(df, :synth_line_from)
                @test hasproperty(df, :capacity_MW) || hasproperty(df, :capacity_pu)

                # Check for the "Zero TTC" issue
                if hasproperty(df, :capacity_MW)
                    @test any(df.capacity_MW .> 1e-5) # Fails if ALL are zero
                    @test all(df.capacity_MW .>= 0.0)
                end
                case.has_dc && @test any(df.is_dc)
            end

            # --- 3. TTC COMPARISON CHECK ---
            @testset "TTC Comparison Check" begin
                path = joinpath(output_dir, "TTC_Comparison_$(CONFIG.suffix).csv")
                @test isfile(path)
                df = CSV.read(path, DataFrame)
                @test size(df, 1) > 0

                if hasproperty(df, :TTC_Equivalent_MW)
                    @test all(df.TTC_Equivalent_MW .>= 0.0)
                    @test !all(df.TTC_Equivalent_MW .== 0.0) # Check that results aren't all zero
                end
                if case.opt == "MIQP"
                    @test hasproperty(df, :in_calibration)
                    calibrated = filter(:in_calibration => identity, df)
                    @test all(
                        r ->
                            r.TTC_Equivalent_MW <=
                            r.TTC_Original_MW + 1e-6 * max(1.0, r.TTC_Original_MW),
                        eachrow(calibrated),
                    )
                    @test isfile(
                        joinpath(output_dir, "Solver_Diagnostics_$(CONFIG.suffix).csv"),
                    )
                end

                # Fit quality is a reduction trade-off, not a universal pass/fail
                # threshold. Correctness and export consistency remain enforced.
                if hasproperty(df, :TTC_Original_MW) &&
                   hasproperty(df, :TTC_Equivalent_MW) &&
                   hasproperty(df, :TTC_Error_Pct)
                    finite = filter(
                        row ->
                            isfinite(row.TTC_Original_MW) && row.TTC_Original_MW > 1e-6,
                        df,
                    )
                    if nrow(finite) > 0
                        @test all(isfinite, finite.TTC_Equivalent_MW)
                        @info "TTC approximation error" case = case.name mode = case.opt maximum_pct =
                            maximum(abs, finite.TTC_Error_Pct) mean_pct =
                            sum(abs, finite.TTC_Error_Pct) / nrow(finite)
                    end
                end
            end

            # --- 4. EXPORTED NETWORK CONSISTENCY ---
            # The reported equivalent TTC must be what the exported network
            # (reactances + capacities) actually delivers.
            @testset "Exported Network Consistency" begin
                comparison = CSV.read(
                    joinpath(output_dir, "TTC_Comparison_$(CONFIG.suffix).csv"),
                    DataFrame,
                )
                id_map = CSV.read(
                    joinpath(output_dir, "Bus_ID_Map_$(CONFIG.suffix).csv"),
                    DataFrame,
                )
                name_to_id = Dict(string(r.old_name) => r.new_id for r in eachrow(id_map))
                independent = exported_network_ttc(output_dir, CONFIG.suffix)

                n_mismatch = 0
                for r in eachrow(comparison)
                    a = name_to_id[string(r.From_node)]
                    b = name_to_id[string(r.To_node)]
                    expected = independent[(min(a, b), max(a, b))] * CONFIG.base
                    isapprox(r.TTC_Equivalent_MW, expected; rtol = 1e-6, atol = 1e-6) ||
                        (n_mismatch += 1)
                end
                @test n_mismatch == 0
            end

            # --- 5. ORIGINAL TTC FILE CHECK ---
            @testset "Original TTC Check" begin
                path = joinpath(output_dir, "TTC_Original_Network_$(CONFIG.suffix).csv")
                @test isfile(path)
                df = CSV.read(path, DataFrame)
                @test size(df, 1) > 0
                @test hasproperty(df, :TTC_MW) || hasproperty(df, :TTC_pu)
            end
        end
    end
end
