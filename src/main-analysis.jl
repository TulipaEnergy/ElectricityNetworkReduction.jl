# --- MAIN ANALYSIS WORKFLOW ---

"""
    main_full_analysis()

Complete network reduction analysis workflow including:
1. Data loading and preprocessing
2. Original network PTDF/TTC analysis
3. Representative node selection
4. Kron reduction
5. Reduced network analysis
6. Optimization of equivalent capacities
7. Results comparison and export

# Returns
Tuple containing:
- ptdf_results: Original network PTDF calculations
- ttc_results: Original network TTC calculations
- ptdf_reduced_results: Reduced network PTDF calculations
- equivalent_capacities_df: Optimized equivalent capacities

# Data Directory
By default uses: C:\\Users\\nomyk\\Desktop\\Julia\\NL_Data
Modify the data_dir variable to change the location.

# Output Files
- Bus_ID_Map_QP.csv: Mapping of bus names to numerical IDs
- Line_Details_QP.csv: Comprehensive line information
- Representative_Nodes_QP.csv: Selected representative nodes
- TTC_Original_Network_QP.csv: Original network TTC values
- PTDF_Reduced_Network_QP.csv: Reduced network PTDF values
- Equivalent_Capacities_QP.csv: Optimized synthetic line capacities
- TTC_Comparison_QP.csv: Comparison of original vs equivalent TTC values
"""
function main_full_analysis()
    println("="^50)
    println("STARTING FULL NETWORK PTDF, TTC, AND REDUCTION ANALYSIS (Canonical Direction)")
    println("="^50)

    # NOTE: Need to provide the correct file path for the data!
    data_dir = raw"C:\Users\nomyk\Desktop\Julia\NL_Data"
    file_path = joinpath(data_dir, "NL_HV_Network.xlsx")

    # Create the directory if it doesn't exist
    mkpath(data_dir)

    println("Loading data from: $file_path")

    # --- Data Loading and Setup ---
    raw_data = load_excel_data(file_path)
    clean_lines = clean_line_data(raw_data["lines"])
    tie_lines = process_tielines(raw_data["tielines"])
    Sbase = 100.0   # MVA

    numbered_lines, numbered_tielines, node_info = rename_buses(
        raw_data["nodes"],
        raw_data["generators"],
        clean_lines,
        tie_lines,
        Sbase,
    )

    Ybus_original =
        form_ybus_with_shunt(numbered_lines, numbered_tielines, node_info, Sbase)
    n_buses = size(Ybus_original, 1)
    println("Original Ybus matrix created: $n_buses×$n_buses")

    # --- EXPORT: Bus Map and Line Info (Step 1) ---
    export_bus_id_map(node_info, joinpath(data_dir, "Bus_ID_Map_QP.csv"))
    export_detailed_line_info(
        numbered_lines,
        numbered_tielines,
        joinpath(data_dir, "Line_Details_QP.csv"),
    )

    # --- 1. REPRESENTATIVE NODE SELECTION ---
    rep_nodes_df, node_info = select_representative_nodes(Ybus_original, node_info)
    rep_node_ids = rep_nodes_df.new_id
    println("\nSelected Representative Nodes (Original IDs): $rep_node_ids")

    # --- 2. ORIGINAL NETWORK ANALYSIS  ---
    println("\n--- 2. ORIGINAL NETWORK PTDF/TTC CALCULATION (Canonical) ---")
    ptdf_results, line_capacities_pu =
        calculate_all_ptdfs_original(Ybus_original, numbered_lines, numbered_tielines)
    ttc_results = calculate_ttc_from_ptdfs(ptdf_results, line_capacities_pu)

    # --- 3. KRON REDUCTION & REDUCED PTDF CALCULATION ---
    println("\n--- 3. KRON REDUCTION & REDUCED PTDF CALCULATION (Canonical) ---")
    Y_kron = kron_reduce_ybus(Ybus_original, rep_node_ids)
    ptdf_reduced_results = calculate_ptdfs_reduced(Y_kron, rep_node_ids)

    # --- DEBUGGING: Check data before optimization ---
    debug_optimization_data(ttc_results, ptdf_reduced_results)

    # --- 4. OPTIMIZATION FOR EQUIVALENT CAPACITIES (Using QP) ---
    equivalent_capacities_df =
        optimize_equivalent_capacities_qp(ttc_results, ptdf_reduced_results)

    # Filter original TTCs to only include canonical RN-to-RN transactions for comparison
    rn_orig_ids = DataFrames.unique(
        DataFrames.vcat(
            ptdf_reduced_results.transaction_from_orig,
            ptdf_reduced_results.transaction_to_orig,
        ),
    )
    ttc_rn_original = DataFrames.filter(
        row ->
            (row.transaction_from in rn_orig_ids) &&
                (row.transaction_to in rn_orig_ids) &&
                (row.transaction_from < row.transaction_to),
        ttc_results,
    )

    # --- 5. EQUIVALENT TTC CALCULATION & COMPARISON ---
    if !isnothing(equivalent_capacities_df)
        println("\n--- 5. EQUIVALENT TTC CALCULATION & COMPARISON ---")

        ttc_equivalent =
            calculate_ttc_equivalent(ptdf_reduced_results, equivalent_capacities_df)

        # Join the two DataFrames for comparison
        comparison_df = DataFrames.innerjoin(
            ttc_rn_original,
            ttc_equivalent,
            on = [:transaction_from, :transaction_to],
            makeunique = true,
        )

        # Calculate Mismatch and Error
        comparison_df[!, :TTC_Mismatch_pu] =
            comparison_df.TTC_Equivalent_pu .- comparison_df.TTC_pu
        comparison_df[!, :TTC_Error_Pct] =
            (comparison_df.TTC_Mismatch_pu ./ comparison_df.TTC_pu) .* 100
        comparison_df[!, :TTC_Error_Pct] =
            [isnan(x) ? 0.0 : x for x in comparison_df.TTC_Error_Pct]

        # Merge with bus names for readability
        bus_name_map =
            Dict(row.new_id => row.old_name for row in DataFrames.eachrow(node_info))

        comparison_df[!, :From_Name] =
            [bus_name_map[id] for id in comparison_df.transaction_from]
        comparison_df[!, :To_Name] =
            [bus_name_map[id] for id in comparison_df.transaction_to]

        # Select and reorder columns for final output
        final_comparison = comparison_df[
            !,
            [
                :From_Name,
                :To_Name,
                :TTC_pu, # Original TTC
                :TTC_Equivalent_pu,
                :TTC_Mismatch_pu,
                :TTC_Error_Pct,
                :limiting_line_from, # Limiting line in original network
                :limiting_synth_line_from, # Limiting line in equivalent network
            ],
        ]

        DataFrames.rename!(final_comparison, :TTC_pu => :TTC_Original_pu)

        println("\n="^50)
        println("FINAL TTC COMPARISON (Canonical RN-to-RN Transactions)")
        println("="^50)
        println(final_comparison)

        # Export comparison
        output_path_comparison = joinpath(data_dir, "TTC_Comparison_QP.csv")
        CSV.write(output_path_comparison, final_comparison)
        println("\nTTC comparison exported to CSV: $output_path_comparison")
    else
        @error "QP optimization failed - cannot proceed with comparison"
        return nothing
    end

    # --- Final Exports ---
    output_path_repnodes = joinpath(data_dir, "Representative_Nodes_QP.csv")
    CSV.write(output_path_repnodes, rep_nodes_df)

    output_path_ttc = joinpath(data_dir, "TTC_Original_Network_QP.csv")
    CSV.write(output_path_ttc, ttc_rn_original) # Exporting only the canonical RN transactions

    output_path_ptdf_reduced = joinpath(data_dir, "PTDF_Reduced_Network_QP.csv")
    CSV.write(output_path_ptdf_reduced, ptdf_reduced_results)

    if !isnothing(equivalent_capacities_df)
        output_path_eq_cap = joinpath(data_dir, "Equivalent_Capacities_QP.csv")  # Renamed to indicate QP
        CSV.write(output_path_eq_cap, equivalent_capacities_df)
        println("Equivalent capacities exported to CSV: $output_path_eq_cap")
    end

    println("\nALL DATA EXPORTED.")

    return ptdf_results, ttc_results, ptdf_reduced_results, equivalent_capacities_df
end
