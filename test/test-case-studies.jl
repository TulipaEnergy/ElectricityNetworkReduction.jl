using ElectricityNetworkReduction
using Test
using CSV
using DataFrames

# 1. Fast case studies, run on every test invocation (including PR CI).
fast_test_suites = [
    (
        name = "case_NL",
        file = "case_NL.xlsx",
        int_bus = false,
        pu = false,
        opt = "QP",
        has_dc = false,
        has_transformers = false,
        has_converters = false,
    ),
    (
        name = "case6",
        file = "case6.xlsx",
        int_bus = true,
        pu = true,
        opt = "QP",
        has_dc = false,
        has_transformers = false,
        has_converters = false,
    ),
    (
        name = "case39",
        file = "case39.xlsx",
        int_bus = true,
        pu = true,
        opt = "QP",
        has_dc = false,
        has_transformers = false,
        has_converters = false,
    ),
    (
        name = "case118",
        file = "case118.xlsx",
        int_bus = false,
        pu = false,
        opt = "QP",
        has_dc = false,
        has_transformers = false,
        has_converters = false,
    ),
]

# 2. Larger/slower case studies. These are already validated and passing but
# take too long to run on every PR, so they only run when
# NETWORKREDUCTION_RUN_SLOW_TESTS=true (set automatically on pushes to main).
slow_test_suites = [
    (
        name = "case_ACTIVSg2000",
        file = "case_ACTIVSg2000.xlsx",
        int_bus = true,
        pu = true,
        opt = "QP",
        has_dc = false,
        has_transformers = false,
        has_converters = false,
    ),
    (
        name = "case_EU",
        file = "case_EU.xlsx",
        int_bus = false,
        pu = false,
        opt = "QP",
        has_dc = true,
        has_transformers = true,
        has_converters = true,
    ),
]

const RUN_SLOW_TESTS = get(ENV, "NETWORKREDUCTION_RUN_SLOW_TESTS", "false") == "true"

test_suites = RUN_SLOW_TESTS ? vcat(fast_test_suites, slow_test_suites) : fast_test_suites

if !RUN_SLOW_TESTS
    @info "Skipping slow case studies ($(join([c.name for c in slow_test_suites], ", "))); set NETWORKREDUCTION_RUN_SLOW_TESTS=true to include them."
end

@testset "Batch Network Reduction Tests" begin
    for case in test_suites
        input_path = joinpath(INPUT_FOLDER, case.name, case.file)

        # Skip case studies whose input data is not present (e.g. private datasets)
        if !isfile(input_path)
            @info "Skipping $(case.name): input file not found at $input_path"
            continue
        end

        @testset "Case Study: $(case.name)" begin

            # --- PREPARATION ---
            reset_config!() # Resets CONFIG to defaults
            CONFIG.case_study = case.name
            CONFIG.input_filename = case.file
            CONFIG.bus_names_as_int = case.int_bus
            CONFIG.in_pu = case.pu
            CONFIG.optimisation_type = case.opt
            CONFIG.suffix = "TEST_$(case.opt)"
            CONFIG.has_dc_lines = case.has_dc
            CONFIG.has_transformers = case.has_transformers
            CONFIG.has_converters = case.has_converters

            input_dir = joinpath(INPUT_FOLDER, case.name)
            output_dir = joinpath(OUTPUT_FOLDER, case.name)
            mkpath(output_dir)

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

                # --- Quality gate: the reduced network must actually preserve TTC,
                # not just produce nonzero/nonnegative numbers. This is the check
                # that would have caught the PTDF key-ordering bug and the
                # zero-pin constraint conflict (both silently produced
                # near-zero or wildly wrong equivalent TTC while still passing the
                # structural checks above).
                if hasproperty(df, :TTC_Original_MW) &&
                   hasproperty(df, :TTC_Equivalent_MW) &&
                   hasproperty(df, :TTC_Error_Pct)
                    finite = filter(
                        row ->
                            isfinite(row.TTC_Original_MW) && row.TTC_Original_MW > 1e-6,
                        df,
                    )
                    if nrow(finite) > 0
                        # No transaction with a real original TTC should collapse to
                        # ~zero in the reduced network.
                        n_collapsed =
                            count(row -> row.TTC_Equivalent_MW < 1e-6, eachrow(finite))
                        @test n_collapsed == 0

                        # Overall fit quality: QP/LP/MIQP all target closely matching
                        # the original TTC, so a well-functioning reduction should be
                        # within a few percent, not tens or hundreds of percent off.
                        @test maximum(abs.(finite.TTC_Error_Pct)) < 5.0
                    end
                end
            end

            # --- 4. ORIGINAL TTC FILE CHECK ---
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
