@testset " $(CONFIG.case_study) results tests" begin
    case_name = CONFIG.case_study
    input_dir = joinpath(INPUT_FOLDER, case_name)
    output_dir = joinpath(OUTPUT_FOLDER, case_name)

    #--- 1. RUN THE ANALYSIS ---
    main_full_analysis(input_dir, output_dir)

    # --- 2. EQUIVALENT CAPACITIES STRUCTURAL CHECK ---
    @testset "Equivalent Capacities Structure Check" begin
        generated_path = joinpath(output_dir, "Equivalent_Capacities_$(CONFIG.suffix).csv")

        # 2a. Test if the output file was successfully created
        @test isfile(generated_path)

        # Read the generated file
        generated = CSV.read(generated_path, DataFrame)

        # 2b. Test if the DataFrame is not empty (ensures data was generated)
        @test size(generated, 1) > 0

        # 2c. Test for the presence of crucial columns (Schema check)
        # Updated column names based on your MW conversion
        @test hasproperty(generated, :from) || hasproperty(generated, :synth_line_from)
        @test hasproperty(generated, :to) || hasproperty(generated, :synth_line_to)
        @test hasproperty(generated, :capacity_MW) ||
              hasproperty(generated, :capacity_pu) ||
              hasproperty(generated, :C_eq_pu)

        # 2d. Test for value constraints (e.g., all capacities must be non-negative)
        # Check based on available column names
        if hasproperty(generated, :capacity_MW)
            @test all(generated.capacity_MW .>= 0.0)
        elseif hasproperty(generated, :capacity_pu)
            @test all(generated.capacity_pu .>= 0.0)
        elseif hasproperty(generated, :C_eq_pu)
            @test all(generated.C_eq_pu .>= 0.0)
        end
    end

    # --- 3. TTC COMPARISON STRUCTURAL CHECK ---
    @testset "TTC Comparison Structure Check" begin
        generated_path = joinpath(output_dir, "TTC_Comparison_$(CONFIG.suffix).csv")

        # 3a. Test if the output file was successfully created
        @test isfile(generated_path)

        # Read the generated file
        generated = CSV.read(generated_path, DataFrame)

        # 3b. Test if the DataFrame is not empty
        @test size(generated, 1) > 0

        # 3c. Test for the presence of crucial columns
        # Updated column names based on your MW conversion
        @test hasproperty(generated, :From_Name)
        @test hasproperty(generated, :To_Name)
        @test hasproperty(generated, :TTC_Original_MW) ||
              hasproperty(generated, :TTC_Original_pu)
        @test hasproperty(generated, :TTC_Equivalent_MW) ||
              hasproperty(generated, :TTC_Equivalent_pu)

        # 3d. Test for value constraints (e.g., TTCs must be non-negative)
        if hasproperty(generated, :TTC_Original_MW)
            @test all(generated.TTC_Original_MW .>= 0.0)
        elseif hasproperty(generated, :TTC_Original_pu)
            @test all(generated.TTC_Original_pu .>= 0.0)
        end

        if hasproperty(generated, :TTC_Equivalent_MW)
            @test all(generated.TTC_Equivalent_MW .>= 0.0)
        elseif hasproperty(generated, :TTC_Equivalent_pu)
            @test all(generated.TTC_Equivalent_pu .>= 0.0)
        end

        # Optional: Check if equivalent TTC doesn't exceed original (can be commented out)
        # if hasproperty(generated, :TTC_Original_MW) && hasproperty(generated, :TTC_Equivalent_MW)
        #     @test all(generated.TTC_Equivalent_MW .<= generated.TTC_Original_MW .* 1.01)  # Allow 1% tolerance
        # end
    end

    # --- 4. ORIGINAL TTC FILE CHECK ---
    @testset "Original TTC File Check" begin
        generated_path = joinpath(output_dir, "TTC_Original_Network_$(CONFIG.suffix).csv")

        # 4a. Test if the output file was successfully created
        @test isfile(generated_path)

        # Read the generated file
        generated = CSV.read(generated_path, DataFrame)

        # 4b. Test if the DataFrame is not empty
        @test size(generated, 1) > 0

        # 4c. Test for the presence of crucial columns
        @test hasproperty(generated, :transaction_from)
        @test hasproperty(generated, :transaction_to)
        @test hasproperty(generated, :TTC_MW) || hasproperty(generated, :TTC_pu)

        # 4d. Test for value constraints
        if hasproperty(generated, :TTC_MW)
            @test all(generated.TTC_MW .>= 0.0)
        elseif hasproperty(generated, :TTC_pu)
            @test all(generated.TTC_pu .>= 0.0)
        end
    end
end
