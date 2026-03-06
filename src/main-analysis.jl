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
- ttc_results: Original network TTC calculations
- ptdf_reduced_results: Reduced network PTDF calculations
- equivalent_capacities_df: Optimized equivalent capacities

# Data Directory
Modify the input_data_dir and output_data_dir variables to change the location.

# Output Files
- Bus_ID_Map_QP.csv: Mapping of bus names to numerical IDs
- Line_Details_QP.csv: Comprehensive line information
- Representative_Nodes_QP.csv: Selected representative nodes
- TTC_Original_Network_QP.csv: Original network TTC values
- PTDF_Reduced_Network_QP.csv: Reduced network PTDF values
- Equivalent_Capacities_QP.csv: Optimized synthetic line capacities
- TTC_Comparison_QP.csv: Comparison of original vs equivalent TTC values
"""
function main_full_analysis(input_data_dir::String, output_data_dir::String)
    println("="^50)
    println("STARTING FULL NETWORK PTDF, TTC, AND REDUCTION ANALYSIS (Canonical Direction)")
    println("="^50)

    # NOTE: Need to provide the correct file path for the data!
    file_path = joinpath(input_data_dir, CONFIG.input_filename)

    println("Loading data from: $file_path")

    # --- Data Loading and Setup ---
    raw_data = load_excel_data(file_path)
    clean_lines = clean_line_data(raw_data["lines"])
    tie_lines = process_tielines(raw_data["tielines"])

    numbered_lines, numbered_tielines, node_info = rename_buses(
        raw_data["nodes"],
        raw_data["generators"],
        clean_lines,
        tie_lines,
        CONFIG.base,
    )
    # --- 1: Island Detection & Original Plot ---
    components, node_info, g_orig =
        detect_islands(numbered_lines, numbered_tielines, node_info)

    all_orig_lines = vcat(numbered_lines, numbered_tielines, cols = :union)

    # Just create the plot object (do not display)
    plt_orig = plot_network(g_orig, node_info, all_orig_lines; title = "Original Network")

    # Y-bus
    Ybus_original =
        form_ybus_with_shunt(numbered_lines, numbered_tielines, node_info, CONFIG.base)
    n_buses = size(Ybus_original, 1)
    println("Original Ybus matrix created: $n_buses×$n_buses")

    # --- EXPORT: Bus Map and Line Info  ---
    export_bus_id_map(
        node_info,
        joinpath(output_data_dir, "Bus_ID_Map_$(CONFIG.suffix).csv"),
    )
    export_detailed_line_info(
        numbered_lines,
        numbered_tielines,
        joinpath(output_data_dir, "Line_Details_$(CONFIG.suffix).csv"),
    )

    # --- 1. REPRESENTATIVE NODE SELECTION ---
    rep_nodes_df, node_info = select_representative_nodes(
        Ybus_original,
        node_info,
        numbered_lines,
        numbered_tielines,
    )
    rep_node_ids = rep_nodes_df.new_id
    println("\nSelected Representative Nodes (Original IDs): $rep_node_ids")

    println("\nValidating PTDF engine for all representative node transactions...")

    # === VIRTUAL LINE FILTER ===
    # Computes exactly which synthetic lines to keep when allow_virtual_lines = false.
    id_to_zone = Dict{Int,String}(row.new_id => row.Zone for row in eachrow(node_info))

    zone_direct_pairs = Set{Tuple{String,String}}()
    all_orig_lines = vcat(numbered_lines, numbered_tielines, cols = :union)
    for row in eachrow(all_orig_lines)
        zf = id_to_zone[row.From]
        zt = id_to_zone[row.To]
        if zf != zt
            push!(zone_direct_pairs, (min(zf, zt), max(zf, zt)))
        end
    end
    println(
        "Direct inter-zone physical connections detected: $(length(zone_direct_pairs)) zone pairs.",
    )

    # Allowed pairs = intra-zone (always) + inter-zone with direct tie
    allowed_synth_pairs = Set{Tuple{Int,Int}}()
    n_rep = length(rep_node_ids)
    for i = 1:n_rep
        for j = i+1:n_rep
            u, v = rep_node_ids[i], rep_node_ids[j]
            zu, zv = id_to_zone[u], id_to_zone[v]
            if zu == zv || (zu != zv && (min(zu, zv), max(zu, zv)) in zone_direct_pairs)
                push!(allowed_synth_pairs, (min(u, v), max(u, v)))
            end
        end
    end
    println(
        "Allowed synthetic line pairs when allow_virtual_lines=false: $(length(allowed_synth_pairs))",
    )
    println("   (all intra-zone + only direct inter-zone)")

    # --- 2. ORIGINAL NETWORK ANALYSIS  ---
    # Computes TTC for the full original network (needed for optimization)
    println("\n--- 2. ORIGINAL NETWORK ANALYSIS ---")
    ttc_results, line_capacities_pu =
        calculate_all_ttc_results(Ybus_original, numbered_lines, numbered_tielines)

    println("Original network TTC analysis completed: $(nrow(ttc_results)) transactions.")

    # --- 3. KRON REDUCTION & REDUCED PTDF CALCULATION ---
    Y_kron = kron_reduce_ybus(Ybus_original, rep_node_ids)
    ptdf_reduced_results = calculate_ptdfs_reduced(Y_kron, rep_node_ids)

    # --- 4. OPTIMIZATION FOR EQUIVALENT CAPACITIES ---
    equivalent_capacities_df, ttc_equivalent = optimize_equivalent_capacities(
        ttc_results,
        ptdf_reduced_results;
        Type = CONFIG.optimization_type,
        lambda = CONFIG.lambda,
        allow_virtual_lines = CONFIG.allow_virtual_lines,
        allowed_synth_pairs = allowed_synth_pairs,
    )

    # --- Extract Reactance from Y_kron ---
    if !isnothing(equivalent_capacities_df)
        # Create local mapping to access Y_kron indices
        rep_id_to_local = Dict(id => i for (i, id) in enumerate(rep_node_ids))

        # Initialize the X_pu column
        equivalent_capacities_df[!, :X_pu] = zeros(nrow(equivalent_capacities_df))

        for row in eachrow(equivalent_capacities_df)
            # Map original IDs back to matrix indices
            i = rep_id_to_local[row.synth_line_from]
            j = rep_id_to_local[row.synth_line_to]

            # The off-diagonal element Y[i,j] is equal to -1/X_ij (the susceptance)
            b_val = imag(Y_kron[i, j])

            # Reactance X = -1 / B (absolute value used to ensure positive reactance for lines)
            row.X_pu = abs(b_val) > 1e-10 ? 1.0 / b_val : 0.0
        end
    end

    # --- Reduced Network Plot ---

    if !isnothing(equivalent_capacities_df)
        # 1. Create mapping for representative nodes
        rep_id_to_local = Dict(id => i for (i, id) in enumerate(rep_node_ids))

        # 2. Build graph using synthetic properties
        g_reduced = SimpleGraph(length(rep_node_ids))
        for row in eachrow(equivalent_capacities_df)
            u = rep_id_to_local[row.synth_line_from]
            v = rep_id_to_local[row.synth_line_to]
            add_edge!(g_reduced, u, v)
        end

        # 3. Plot reduced network using only synth properties
        rep_node_info = filter(row -> row.new_id in rep_node_ids, node_info)
        plt_red = plot_network(
            g_reduced,
            rep_node_info,
            equivalent_capacities_df;
            title = "Reduced Network",
        )
    end

    # --- Side-by-side visualization: Original vs Reduced ---
    plt_comparison = plot_original_vs_reduced(
        g_orig,
        node_info,
        all_orig_lines,
        g_reduced,
        rep_node_info,
        equivalent_capacities_df,
    )

    savefig(
        plt_comparison,
        joinpath(output_data_dir, "Network_Original_vs_Reduced_$(CONFIG.suffix).png"),
    )

    # Filter original TTCs to only include canonical RN-to-RN transactions for comparison
    rn_orig_ids = unique(
        vcat(
            ptdf_reduced_results.transaction_from_orig,
            ptdf_reduced_results.transaction_to_orig,
        ),
    )
    ttc_rn_original = filter(
        row ->
            (row.transaction_from in rn_orig_ids) &&
                (row.transaction_to in rn_orig_ids) &&
                (row.transaction_from < row.transaction_to),
        ttc_results,
    )

    # --- 5. EQUIVALENT TTC CALCULATION & COMPARISON ---
    if !isnothing(equivalent_capacities_df) && !isnothing(ttc_equivalent)
        println("\n--- 5. TTC COMPARISON ---")

        # Join the two DataFrames for comparison
        comparison_df = innerjoin(
            ttc_rn_original,
            ttc_equivalent,
            on = [:transaction_from, :transaction_to],
            makeunique = true,
        )

        # CONVERT PER-UNIT TO MW (100 MVA base)
        comparison_df[!, :TTC_Original_MW] = comparison_df.TTC_pu .* CONFIG.base
        comparison_df[!, :TTC_Equivalent_MW] =
            comparison_df.TTC_Equivalent_pu .* CONFIG.base

        # Calculate Mismatch in MW
        comparison_df[!, :TTC_Mismatch_MW] =
            comparison_df.TTC_Equivalent_MW .- comparison_df.TTC_Original_MW

        # Calculate Percentage Error (still in %)
        comparison_df[!, :TTC_Error_Pct] =
            (comparison_df.TTC_Mismatch_MW ./ comparison_df.TTC_Original_MW) .* 100
        comparison_df[!, :TTC_Error_Pct] =
            [isnan(x) ? 0.0 : x for x in comparison_df.TTC_Error_Pct]

        # Merge with bus names for readability
        bus_name_map = Dict(row.new_id => row.old_name for row in eachrow(node_info))

        comparison_df[!, :From_node] =
            [bus_name_map[id] for id in comparison_df.transaction_from]
        comparison_df[!, :To_node] =
            [bus_name_map[id] for id in comparison_df.transaction_to]

        # Select and reorder columns for final output (MW columns)
        final_comparison = comparison_df[
            !,
            [
                :From_node,
                :To_node,
                :TTC_Original_MW,           # In MW
                :TTC_Equivalent_MW,         # In MW
                :TTC_Mismatch_MW,           # In MW
                :TTC_Error_Pct,             # In %
                :limiting_line_from,        # Limiting line in original network
                :limiting_line_to,          # Original network limiting 'to' node
                :limiting_synth_line_from,  # Limiting line in equivalent network
                :limiting_synth_line_to,    # Equivalent network limiting 'to' node
            ],
        ]

        println("\n")
        println("FINAL TTC COMPARISON (Canonical RN-to-RN Transactions)")
        println("All values in MW on 100 MVA base")
        println("\n")
        println(final_comparison)

        # Export comparison
        output_path_comparison =
            joinpath(output_data_dir, "TTC_Comparison_$(CONFIG.suffix).csv")
        CSV.write(output_path_comparison, final_comparison)
        println("\nTTC comparison exported to CSV: $output_path_comparison")
    else
        @error "Optimization failed - cannot proceed with comparison"
        return nothing
    end

    # Export TTC in MW
    if !isnothing(equivalent_capacities_df)
        ttc_rn_original_mw = copy(ttc_rn_original)
        ttc_rn_original_mw[!, :TTC_MW] = ttc_rn_original_mw.TTC_pu .* CONFIG.base
        ttc_rn_original_mw = ttc_rn_original_mw[
            !,
            [
                :transaction_from,
                :transaction_to,
                :TTC_MW,
                :limiting_line_from,
                :limiting_line_to,
            ],
        ]

        output_path_ttc =
            joinpath(output_data_dir, "TTC_Original_Network_$(CONFIG.suffix).csv")
        CSV.write(output_path_ttc, ttc_rn_original_mw)
        println("Original TTC exported in MW to CSV: $output_path_ttc")
    end

    # Add names for both the synthetic line and the transaction buses
    ptdf_reduced_results[!, :line_from_name] =
        [bus_name_map[id] for id in ptdf_reduced_results.synth_line_from]
    ptdf_reduced_results[!, :line_to_name] =
        [bus_name_map[id] for id in ptdf_reduced_results.synth_line_to]
    ptdf_reduced_results[!, :txn_from_name] =
        [bus_name_map[id] for id in ptdf_reduced_results.transaction_from_orig]
    ptdf_reduced_results[!, :txn_to_name] =
        [bus_name_map[id] for id in ptdf_reduced_results.transaction_to_orig]

    output_path_ptdf_reduced =
        joinpath(output_data_dir, "PTDF_Reduced_Network_$(CONFIG.suffix).csv")
    CSV.write(output_path_ptdf_reduced, ptdf_reduced_results)


    # Export equivalent capacities in MW
    if !isnothing(equivalent_capacities_df)
        eq_cap_mw = copy(equivalent_capacities_df)

        # Convert C_eq_pu to MW
        eq_cap_mw[!, :capacity_MW] = eq_cap_mw.C_eq_pu .* CONFIG.base
        eq_cap_mw[!, :capacity_pu] = eq_cap_mw.C_eq_pu

        # Add original names
        eq_cap_mw[!, :from_node] = [bus_name_map[id] for id in eq_cap_mw.synth_line_from]
        eq_cap_mw[!, :to_node] = [bus_name_map[id] for id in eq_cap_mw.synth_line_to]

        # Rename and reorder columns, including X_pu
        rename!(eq_cap_mw, :synth_line_from => :from, :synth_line_to => :to)

        final_export_df = eq_cap_mw[
            !,
            [:from, :to, :from_node, :to_node, :capacity_MW, :capacity_pu, :X_pu],
        ]

        output_path_eq_cap =
            joinpath(output_data_dir, "Equivalent_Capacities_$(CONFIG.suffix).csv")
        CSV.write(output_path_eq_cap, final_export_df)
        println("Equivalent capacities exported to: $output_path_eq_cap")
    end

    println("\nALL DATA EXPORTED IN MW (100 MVA BASE).")

    return
    ttc_results,
    ptdf_reduced_results,
    equivalent_capacities_df,
    ttc_equivalent,
    components,
    node_info,
    plt_comparison
end
