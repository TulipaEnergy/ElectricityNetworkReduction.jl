# --- MAIN ANALYSIS WORKFLOW ---

"""
    main_full_analysis(input_data_dir, output_data_dir)

Complete eleven-step network reduction analysis workflow:
1. Data loading and preprocessing (AC lines, tie-lines, transformers, DC lines, converters)
2. Island detection and original network plot (when `CONFIG.enable_plots = true`)
3. Y-bus assembly (AC only) and export of island diagnostics, bus ID map, line details
4. Representative node selection (auto by degree, or manual from Excel)
5. Virtual line filter and DC capacity map construction
6. Original network TTC/PTDF analysis (AC + additive DC, parallelised when `parallel_processing = true`)
7. Kron reduction of non-representative nodes
8. Reduced-network PTDF computation
9. Optimisation of equivalent line capacities (QP / LP / MIQP via JuMP + Ipopt / HiGHS)
10. Reduced network visualisation (when `CONFIG.enable_plots = true`)
11. TTC comparison and export of all results to CSV

Set `CONFIG.has_dc_lines = true` and provide a DCLines sheet in the Excel file
to enable DC line integration.

# Returns
Nothing. All results are written to CSV files in `output_data_dir`.

# Output Files
All filenames use `CONFIG.suffix` as a postfix:
- `Bus_ID_Map_<suffix>.csv`: Mapping of original bus names to sequential integer IDs
- `Island_Diagnostics_<suffix>.csv`: Per-island summary (size, zones, voltage levels, diagnosis)
- `Line_Details_<suffix>.csv`: Comprehensive line information (per-unit parameters)
- `TTC_Original_Network_<suffix>.csv`: Original network TTC values (AC + DC columns)
- `PTDF_Reduced_Network_<suffix>.csv`: Reduced network PTDF values
- `Equivalent_Capacities_<suffix>.csv`: Optimised synthetic line capacities, reactances, and DC flags
- `TTC_Comparison_<suffix>.csv`: Comparison of original vs equivalent TTC values
- `Network_Original_<suffix>.png`: Original network plot (only when `enable_plots = true`)
- `Network_Reduced_<suffix>.png`: Reduced network plot (only when `enable_plots = true`)
- `Network_Original_vs_Reduced_<suffix>.png`: Side-by-side comparison plot (only when `enable_plots = true`)
"""
function main_full_analysis(input_data_dir::String, output_data_dir::String)
    # ── Timing helpers ────────────────────────────────────────────────────────
    const_width = 68          # total console ruler width
    label_width = 52          # left column width for step labels
    _ruler() = println("─"^const_width)
    _thick_ruler() = println("═"^const_width)
    _fmt_time(s) = s >= 60 ? "$(round(s / 60, digits=1)) min" : "$(round(s, digits=2)) s"

    step_names = String[]
    step_times = Float64[]
    t_wall_start = time()

    function _log_step(label::String, elapsed::Float64)
        push!(step_names, label)
        push!(step_times, elapsed)
        dots = max(1, label_width - length(label) - 3)
        println(
            "  $(lpad(length(step_names), 2)). $(label) $("." ^ dots) $(_fmt_time(elapsed))",
        )
    end
    # ─────────────────────────────────────────────────────────────────────────

    _thick_ruler()
    println("  ElectricityNetworkReduction.jl")
    println("  Case : $(CONFIG.case_study)   |   Solver : $(CONFIG.optimisation_type)")
    println("  Input: $(CONFIG.input_filename)")
    _thick_ruler()
    println()

    file_path = joinpath(input_data_dir, CONFIG.input_filename)
    println("Loading data from: $file_path\n")

    # ── Step 1: Data loading & preprocessing ─────────────────────────────────
    local numbered_lines, numbered_tielines, node_info, bus_map, numbered_dclines, transformers_raw

    t1 = @elapsed begin
        raw_data = load_excel_data(file_path)
        clean_lines = clean_line_data(raw_data["lines"])
        tie_lines = process_tielines(raw_data["tielines"])
        dc_lines_raw = process_dclines(raw_data["dclines"], CONFIG.base)
        transformers_raw = process_transformers(raw_data["transformers"])

        # ── Converter remapping ──────────────────────────────────────────────
        # Build the DC-terminal → AC-bus map from the Converters sheet and
        # rewrite every DCLine endpoint in-place.  This must happen before
        # rename_buses so that (a) DC terminal buses are excluded from the
        # node list and (b) numeric ID assignment covers only AC buses.
        converters_raw = process_converters(raw_data["converters"])
        converter_map = build_converter_map(converters_raw)
        remap_dc_endpoints!(dc_lines_raw, converter_map)

        # Remove DC terminal buses from the node list before assigning numeric
        # IDs.  After remapping, DC terminals are no longer referenced by any
        # branch, so including them would add zero-row/column entries to the
        # Y-bus and risk singularity in the Kron reduction.
        dc_terminal_names = Set(keys(converter_map))
        ac_only_nodes = if isempty(dc_terminal_names)
            raw_data["nodes"]
        else
            n_before = nrow(raw_data["nodes"])
            filtered = filter(
                row -> !(uppercase(strip(string(row.Bus))) in dc_terminal_names),
                raw_data["nodes"],
            )
            n_removed = n_before - nrow(filtered)
            n_removed > 0 &&
                println("Filtered $(n_removed) DC terminal buses from node list.")
            filtered
        end

        numbered_lines, numbered_tielines, node_info = rename_buses(
            ac_only_nodes,
            raw_data["generators"],
            clean_lines,
            tie_lines,
            CONFIG.base,
        )

        bus_map =
            Dict{String,Int}(row.old_name => row.new_id for row in eachrow(node_info))
        numbered_dclines = rename_dc_buses(dc_lines_raw, bus_map)

        if !isempty(transformers_raw)
            clean_bus_names =
                CONFIG.bus_names_as_int ? x -> string.(x) :
                x -> uppercase.(strip.(string.(x)))
            transformers_raw[!, :From_node] =
                clean_bus_names(transformers_raw.From_node)
            transformers_raw[!, :To_node] = clean_bus_names(transformers_raw.To_node)

            for row in eachrow(transformers_raw)
                haskey(bus_map, row.From_node) || error(
                    "Transformer From_node '$(row.From_node)' not found in Nodes sheet.",
                )
                haskey(bus_map, row.To_node) || error(
                    "Transformer To_node '$(row.To_node)' not found in Nodes sheet.",
                )
            end

            if CONFIG.transformers_in_pu
                !hasproperty(transformers_raw, :Voltage_level) &&
                    (transformers_raw[!, :Voltage_level] = ones(nrow(transformers_raw)))
                convert_line_to_pu!(transformers_raw, CONFIG.base; in_pu = true)
            else
                hasproperty(transformers_raw, :Voltage_level) || error(
                    "Transformer sheet missing 'Voltage_level' column needed for ohm→pu " *
                    "conversion. Set CONFIG.transformers_in_pu = true if X is already in pu.",
                )
                convert_line_to_pu!(transformers_raw, CONFIG.base; in_pu = false)
            end

            transformers_raw[!, :From] =
                [bus_map[n] for n in transformers_raw.From_node]
            transformers_raw[!, :To] = [bus_map[n] for n in transformers_raw.To_node]

            numbered_lines = vcat(numbered_lines, transformers_raw, cols = :union)
            println("Transformers merged: total AC lines now $(nrow(numbered_lines)).")
        end

        if !isempty(numbered_dclines)
            println(
                "DC interconnectors: $(nrow(numbered_dclines)) lines mapped to numerical IDs.",
            )
        end
    end
    _log_step("Data loading & preprocessing", t1)

    # ── Step 2: Island detection & original network plot ─────────────────────
    local g_orig, all_orig_lines_plot
    t2 = @elapsed begin
        if CONFIG.enable_plots
            components, node_info, g_orig = detect_islands(
                numbered_lines,
                numbered_tielines,
                node_info,
                numbered_dclines,
            )
            all_orig_lines_plot = vcat(numbered_lines, numbered_tielines, cols = :union)
            if !isempty(numbered_dclines)
                all_orig_lines_plot =
                    vcat(all_orig_lines_plot, numbered_dclines, cols = :union)
            end
            fig_orig = plot_network_gis(
                g_orig,
                node_info,
                all_orig_lines_plot;
                title = "Original Network",
            )
            CairoMakie.save(
                joinpath(output_data_dir, "Network_Original_$(CONFIG.suffix).png"),
                fig_orig,
            )
        else
            g_orig = nothing
            all_orig_lines_plot = nothing
        end
    end
    _log_step("Island detection & original network plot", t2)

    # ── Step 3: Y-bus assembly & diagnostics ─────────────────────────────────
    local Ybus_original
    t3 = @elapsed begin
        Ybus_original = form_ybus_with_shunt(
            numbered_lines,
            numbered_tielines,
            node_info,
            CONFIG.base,
        )
        n_buses = size(Ybus_original, 1)
        println("Original Ybus (AC only): $n_buses×$n_buses")

        island_diag_df, _, _ = diagnose_islands(
            numbered_lines,
            numbered_tielines,
            node_info;
            dclines_df = numbered_dclines,
            top_n = 20,
        )
        export_island_diagnostics(
            island_diag_df,
            joinpath(output_data_dir, "Island_Diagnostics_$(CONFIG.suffix).csv"),
        )
        export_bus_id_map(
            node_info,
            joinpath(output_data_dir, "Bus_ID_Map_$(CONFIG.suffix).csv"),
        )
        export_detailed_line_info(
            numbered_lines,
            numbered_tielines,
            joinpath(output_data_dir, "Line_Details_$(CONFIG.suffix).csv"),
        )
    end
    _log_step("Y-bus assembly & diagnostics", t3)

    # ── Step 4: Representative node selection ─────────────────────────────────
    local rep_nodes_df, rep_node_ids, high_res_node_ids
    t4 = @elapsed begin
        rep_nodes_df, node_info = select_representative_nodes(
            Ybus_original,
            node_info,
            numbered_lines,
            numbered_tielines,
        )
        rep_node_ids = rep_nodes_df.new_id
        println("\nSelected Representative Nodes (Original IDs): $rep_node_ids")

        high_res_node_ids = let zones = Set(CONFIG.high_res_zones)
            if isempty(zones)
                Set{Int}()
            else
                Set{Int}(row.new_id for row in eachrow(node_info) if row.Zone in zones)
            end
        end
        if !isempty(high_res_node_ids)
            n_ext = length(rep_node_ids) - length(high_res_node_ids)
            println(
                "\nHigh-resolution zones: $(join(sort(CONFIG.high_res_zones), ", "))" *
                "  ($(length(high_res_node_ids)) full-res buses + $n_ext external reps)",
            )
        end
    end
    _log_step("Representative node selection", t4)

    # ── Step 5: Virtual line filter & DC capacity map ─────────────────────────
    local allowed_synth_pairs, dc_cap_map
    t5 = @elapsed begin
        println("\nValidating PTDF engine for all representative node transactions...")

        id_to_zone =
            Dict{Int,String}(row.new_id => row.Zone for row in eachrow(node_info))

        zone_direct_pairs = Set{Tuple{String,String}}()
        all_orig_lines = vcat(numbered_lines, numbered_tielines, cols = :union)
        for row in eachrow(all_orig_lines)
            zf = id_to_zone[row.From]
            zt = id_to_zone[row.To]
            if zf != zt
                push!(zone_direct_pairs, (min(zf, zt), max(zf, zt)))
            end
        end
        if !isempty(numbered_dclines)
            for row in eachrow(numbered_dclines)
                zf = id_to_zone[row.From]
                zt = id_to_zone[row.To]
                if zf != zt
                    push!(zone_direct_pairs, (min(zf, zt), max(zf, zt)))
                end
            end
        end
        println(
            "Direct inter-zone connections (AC + DC): $(length(zone_direct_pairs)) zone pairs.",
        )

        allowed_synth_pairs = Set{Tuple{Int,Int}}()
        n_rep = length(rep_node_ids)
        for i = 1:n_rep
            for j = (i+1):n_rep
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

        dc_cap_map = build_dc_capacity_map(
            numbered_dclines,
            node_info,
            rep_node_ids;
            lines_df = numbered_lines,
            tielines_df = numbered_tielines,
        )
    end
    _log_step("Virtual line filter & DC capacity map", t5)

    # ── Step 6: Original network TTC/PTDF analysis ───────────────────────────
    local ttc_results, line_capacities_pu
    t6 = @elapsed begin
        println("\n--- ORIGINAL NETWORK ANALYSIS ---")
        ttc_results, line_capacities_pu = calculate_all_ttc_results(
            Ybus_original,
            numbered_lines,
            numbered_tielines;
            dc_cap_map = dc_cap_map,
        )
        println(
            "Original network TTC analysis completed: $(nrow(ttc_results)) transactions.",
        )
    end
    _log_step("Original network TTC/PTDF analysis", t6)

    # ── Step 7: Kron reduction ────────────────────────────────────────────────
    local Y_kron
    t7 = @elapsed begin
        Y_kron = kron_reduce_ybus(Ybus_original, rep_node_ids)
    end
    _log_step("Kron reduction", t7)

    # ── Step 8: Reduced-network PTDF computation ──────────────────────────────
    local ptdf_reduced_results
    t8 = @elapsed begin
        ptdf_reduced_results = calculate_ptdfs_reduced(
            Y_kron,
            rep_node_ids;
            high_res_ids = high_res_node_ids,
        )
    end
    _log_step("Reduced-network PTDF computation", t8)

    # ── Step 9: Capacity optimisation ─────────────────────────────────────────
    local equivalent_capacities_df, ttc_equivalent
    t9 = @elapsed begin
        equivalent_capacities_df, ttc_equivalent = optimise_equivalent_capacities(
            ttc_results,
            ptdf_reduced_results;
            Type = CONFIG.optimisation_type,
            lambda = CONFIG.lambda,
            allow_virtual_lines = CONFIG.allow_virtual_lines,
            allowed_synth_pairs = allowed_synth_pairs,
            dc_cap_map = dc_cap_map,
            high_res_node_ids = high_res_node_ids,
            phys_line_caps = line_capacities_pu,
        )

        if !isnothing(equivalent_capacities_df)
            rep_id_to_local = Dict(id => i for (i, id) in enumerate(rep_node_ids))

            equivalent_capacities_df[!, :X_pu] = zeros(nrow(equivalent_capacities_df))
            equivalent_capacities_df[!, :is_dc] =
                fill(false, nrow(equivalent_capacities_df))

            for row in eachrow(equivalent_capacities_df)
                i = get(rep_id_to_local, row.synth_line_from, nothing)
                j = get(rep_id_to_local, row.synth_line_to, nothing)
                if isnothing(i) || isnothing(j)
                    continue
                end
                b_val = imag(Y_kron[i, j])
                row.X_pu = abs(b_val) > 1e-10 ? 1.0 / b_val : 0.0
            end

            if !isempty(dc_cap_map)
                for (key, cap) in dc_cap_map
                    push!(
                        equivalent_capacities_df,
                        (
                            synth_line_from = key[1],
                            synth_line_to = key[2],
                            C_eq_pu = cap,
                            X_pu = 0.0,
                            is_dc = true,
                        ),
                    )
                end
                println("$(length(dc_cap_map)) DC lines appended to equivalent capacities.")
            end
        end
    end
    _log_step("Capacity optimisation ($(CONFIG.optimisation_type))", t9)

    # ── Step 10: Reduced network visualisation ────────────────────────────────
    t10 = @elapsed begin
        if CONFIG.enable_plots && !isnothing(equivalent_capacities_df)
            rep_id_to_local_plot = Dict(id => i for (i, id) in enumerate(rep_node_ids))
            g_reduced = SimpleGraph(length(rep_node_ids))
            for row in eachrow(equivalent_capacities_df)
                u = get(rep_id_to_local_plot, row.synth_line_from, nothing)
                v = get(rep_id_to_local_plot, row.synth_line_to, nothing)
                (!isnothing(u) && !isnothing(v)) && add_edge!(g_reduced, u, v)
            end
            rep_node_info = filter(row -> row.new_id in rep_node_ids, node_info)
            _rep_order = Dict(id => i for (i, id) in enumerate(rep_node_ids))
            sort!(rep_node_info, :new_id, by = id -> _rep_order[id])

            fig_reduced = plot_network_gis(
                g_reduced,
                rep_node_info,
                equivalent_capacities_df;
                title = "Reduced Network",
                show_names = true,
            )
            CairoMakie.save(
                joinpath(output_data_dir, "Network_Reduced_$(CONFIG.suffix).png"),
                fig_reduced,
            )

            fig_comparison = plot_original_vs_reduced_gis(
                g_orig,
                node_info,
                all_orig_lines_plot,
                g_reduced,
                rep_node_info,
                equivalent_capacities_df,
            )
            CairoMakie.save(
                joinpath(
                    output_data_dir,
                    "Network_Original_vs_Reduced_$(CONFIG.suffix).png",
                ),
                fig_comparison,
            )
        end
    end
    _log_step("Reduced network visualisation", t10)

    # ── Step 11: TTC comparison & result export ───────────────────────────────
    local bus_name_map
    t11 = @elapsed begin
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

        if !isnothing(equivalent_capacities_df) && !isnothing(ttc_equivalent)
            println("\n--- TTC COMPARISON ---")

            comparison_df = innerjoin(
                ttc_rn_original,
                ttc_equivalent,
                on = [:transaction_from, :transaction_to],
                makeunique = true,
            )

            comparison_df[!, :TTC_Original_MW] = comparison_df.TTC_pu .* CONFIG.base
            comparison_df[!, :TTC_Equivalent_MW] =
                comparison_df.TTC_Equivalent_pu .* CONFIG.base
            comparison_df[!, :TTC_Mismatch_MW] = [
                isfinite(orig) ? (equiv - orig) : NaN for (orig, equiv) in
                zip(comparison_df.TTC_Original_MW, comparison_df.TTC_Equivalent_MW)
            ]
            comparison_df[!, :TTC_Error_Pct] = [
                isfinite(orig) && orig != 0.0 ? ((equiv - orig) / orig * 100) : NaN
                for (orig, equiv) in
                zip(comparison_df.TTC_Original_MW, comparison_df.TTC_Equivalent_MW)
            ]

            bus_name_map =
                Dict(row.new_id => row.old_name for row in eachrow(node_info))

            comparison_df[!, :From_node] =
                [bus_name_map[id] for id in comparison_df.transaction_from]
            comparison_df[!, :To_node] =
                [bus_name_map[id] for id in comparison_df.transaction_to]

            final_comparison = comparison_df[
                !,
                [
                    :From_node,
                    :To_node,
                    :TTC_Original_MW,
                    :TTC_Equivalent_MW,
                    :TTC_Mismatch_MW,
                    :TTC_Error_Pct,
                    :limiting_line_from,
                    :limiting_line_to,
                    :limiting_synth_line_from,
                    :limiting_synth_line_to,
                ],
            ]

            println("\n")
            println("FINAL TTC COMPARISON (Canonical RN-to-RN Transactions)")
            println("All values in MW on $(CONFIG.base) MVA base")
            println("\n")
            println(final_comparison)

            output_path_comparison =
                joinpath(output_data_dir, "TTC_Comparison_$(CONFIG.suffix).csv")
            CSV.write(output_path_comparison, final_comparison)
            println("\nTTC comparison exported to CSV: $output_path_comparison")
        else
            @error "Optimisation failed - cannot proceed with comparison"
            return nothing
        end

        if !isnothing(equivalent_capacities_df)
            ttc_export = copy(ttc_rn_original)
            ttc_export[!, :TTC_MW] = ttc_export.TTC_pu .* CONFIG.base
            ttc_export[!, :TTC_AC_MW] = ttc_export.TTC_AC_pu .* CONFIG.base
            ttc_export[!, :TTC_DC_MW] = ttc_export.TTC_DC_pu .* CONFIG.base

            output_path_ttc =
                joinpath(output_data_dir, "TTC_Original_Network_$(CONFIG.suffix).csv")
            CSV.write(
                output_path_ttc,
                ttc_export[
                    !,
                    [
                        :transaction_from,
                        :transaction_to,
                        :TTC_MW,
                        :TTC_AC_MW,
                        :TTC_DC_MW,
                        :limiting_line_from,
                        :limiting_line_to,
                    ],
                ],
            )
            println("Original TTC exported in MW to CSV: $output_path_ttc")
        end

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

        if !isnothing(equivalent_capacities_df)
            eq_cap_mw = copy(equivalent_capacities_df)

            eq_cap_mw[!, :capacity_MW] = eq_cap_mw.C_eq_pu .* CONFIG.base
            eq_cap_mw[!, :capacity_pu] = eq_cap_mw.C_eq_pu
            eq_cap_mw[!, :from_node] =
                [bus_name_map[id] for id in eq_cap_mw.synth_line_from]
            eq_cap_mw[!, :to_node] =
                [bus_name_map[id] for id in eq_cap_mw.synth_line_to]

            rename!(eq_cap_mw, :synth_line_from => :from, :synth_line_to => :to)

            output_path_eq_cap =
                joinpath(output_data_dir, "Equivalent_Capacities_$(CONFIG.suffix).csv")
            CSV.write(
                output_path_eq_cap,
                eq_cap_mw[
                    !,
                    [
                        :from,
                        :to,
                        :from_node,
                        :to_node,
                        :capacity_MW,
                        :capacity_pu,
                        :X_pu,
                        :is_dc,
                    ],
                ],
            )
            println("Equivalent capacities exported to: $output_path_eq_cap")
            println("Equivalent capacities exported (AC synthetic + DC lines).")
        end

        println("\nALL DATA EXPORTED IN MW ($(CONFIG.base) MVA BASE).")
    end
    _log_step("TTC comparison & result export", t11)

    # ── Timing summary ────────────────────────────────────────────────────────
    t_total = time() - t_wall_start
    println()
    _thick_ruler()
    println("  EXECUTION TIME SUMMARY")
    _ruler()
    for (i, (name, t)) in enumerate(zip(step_names, step_times))
        dots = max(1, label_width - length(name) - 3)
        pct = "$(lpad(round(100 * t / t_total, digits=1), 5))%"
        println("  $(lpad(i, 2)). $(name) $("." ^ dots) $(rpad(_fmt_time(t), 10))  $pct")
    end
    _ruler()
    println("  Total$(" " ^ (label_width - 2)) $(_fmt_time(t_total))")
    _thick_ruler()

    return nothing
end
