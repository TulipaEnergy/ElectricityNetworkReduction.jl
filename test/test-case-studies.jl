using ElectricityNetworkReduction
using Test
using CSV
using DataFrames

# 1. List of case studies to test
test_suites = [
    (
        name = "case_NL",
        file = "NL_HV_Network.xlsx",
        int_bus = false,
        pu = false,
        opt = "QP",
    ),
    (name = "case6", file = "case6.xlsx", int_bus = true, pu = true, opt = "QP"),
    (name = "case39", file = "case39.xlsx", int_bus = true, pu = true, opt = "QP"),
    (name = "case118", file = "case118.xlsx", int_bus = false, pu = false, opt = "QP"),
    (
        name = "case_ACTIVSg2000",
        file = "case_ACTIVSg2000.xlsx",
        int_bus = true,
        pu = true,
        opt = "QP",
    ),
]

@testset "Batch Network Reduction Tests" begin
    for case in test_suites
        @testset "Case Study: $(case.name)" begin

            # --- PREPARATION ---
            reset_config!() # Resets CONFIG to defaults
            CONFIG.case_study = case.name
            CONFIG.input_filename = case.file
            CONFIG.bus_names_as_int = case.int_bus
            CONFIG.in_pu = case.pu
            CONFIG.optimization_type = case.opt
            CONFIG.suffix = "TEST_$(case.opt)"

            input_dir = joinpath(INPUT_FOLDER, case.name)
            output_dir = joinpath(OUTPUT_FOLDER, case.name)
            mkpath(output_dir)

            # --- 1. RUN THE ANALYSIS ---
            @test_nowarn main_full_analysis(input_dir, output_dir)

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
