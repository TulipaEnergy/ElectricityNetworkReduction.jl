"""
    diagnose_islands(lines_df, tielines_df, node_info; dclines_df, top_n)

Analyse AC-only connected components and print a diagnostic report to help
distinguish between physically-real islands and data-gap artefacts (e.g.
missing transformers between voltage levels in the same zone).

Returns a summary DataFrame (one row per island, sorted largest-first) and
the raw `components` / `node_comp` vectors for further use.

# Columns in the returned DataFrame
- `island_id`: internal component index
- `n_buses`: number of buses in the island
- `zones`: semicolon-separated list of zones with bus counts, e.g. "DE(43);FR(12)"
- `voltage_kv`: semicolon-separated sorted unique voltage levels
- `dc_bridge`: true if a DC line links this island to another
- `diagnosis`: "SUSPECT", "DC-ONLY", "SINGLETON", or "REAL"
- `suspect_zones`: zones that triggered SUSPECT (empty otherwise)

# Arguments
- `lines_df`, `tielines_df`: AC branch DataFrames (must have `:From`, `:To`)
- `node_info`: bus metadata (must have `:new_id`, `:Zone`, `:baseKV`)
- `dclines_df`: DC branch DataFrame (optional; used to flag DC-bridge islands)
- `top_n`: print only the `top_n` largest islands in the terminal (0 = all)
"""
function diagnose_islands(
    lines_df::DataFrame,
    tielines_df::DataFrame,
    node_info::DataFrame;
    dclines_df::DataFrame = DataFrame(),
    top_n::Int = 0,
)
    # --- 1. Build AC-only graph ---
    all_ac = vcat(lines_df, tielines_df, cols = :union)
    n = nrow(node_info)
    g_ac = SimpleGraph(n)
    for row in eachrow(all_ac)
        hasproperty(row, :From) &&
            hasproperty(row, :To) &&
            add_edge!(g_ac, Int(row.From), Int(row.To))
    end
    components = connected_components(g_ac)

    # --- 2. Build DC adjacency (island-level) ---
    node_comp = zeros(Int, n)
    for (ci, comp) in enumerate(components)
        node_comp[comp] .= ci
    end
    dc_bridges = Set{Tuple{Int,Int}}()
    for row in eachrow(dclines_df)
        (hasproperty(row, :From) && hasproperty(row, :To)) || continue
        ci = node_comp[Int(row.From)]
        cj = node_comp[Int(row.To)]
        ci != cj && push!(dc_bridges, (min(ci, cj), max(ci, cj)))
    end
    dc_connected = Set(vcat([[a, b] for (a, b) in dc_bridges]...))

    # --- 3. Build lookup: new_id → node_info row ---
    id_to_row = Dict{Int,DataFrameRow}(row.new_id => row for row in eachrow(node_info))

    # --- 4. Build summary rows, sorted largest-first ---
    sorted = sort(collect(enumerate(components)), by = x -> -length(x[2]))

    rows = []
    for (rank, (ci, comp)) in enumerate(sorted)
        buses = [id_to_row[b] for b in comp if haskey(id_to_row, b)]

        zones_count = Dict{String,Int}()
        kv_per_zone = Dict{String,Set{Float64}}()
        for bus in buses
            z = string(bus.Zone)
            kv = Float64(bus.baseKV)
            zones_count[z] = get(zones_count, z, 0) + 1
            push!(get!(kv_per_zone, z, Set{Float64}()), kv)
        end

        all_kvs = sort(collect(union(values(kv_per_zone)...)))
        is_dc_con = ci in dc_connected
        multi_kv_z = sort([z for (z, kvs) in kv_per_zone if length(kvs) > 1])

        if !isempty(multi_kv_z)
            diagnosis = "SUSPECT"
        elseif is_dc_con
            diagnosis = "DC-ONLY"
        elseif length(comp) == 1
            diagnosis = "SINGLETON"
        else
            diagnosis = "REAL"
        end

        zones_str =
            join(["$z($(zones_count[z]))" for z in sort(collect(keys(zones_count)))], ";")
        kv_str = join(string.(all_kvs), ";")

        push!(
            rows,
            (
                island_id = ci,
                rank = rank,
                n_buses = length(comp),
                zones = zones_str,
                voltage_kv = kv_str,
                dc_bridge = is_dc_con,
                diagnosis = diagnosis,
                suspect_zones = join(multi_kv_z, ";"),
            ),
        )
    end

    summary_df = DataFrame(rows)

    # --- 5. Print terminal report ---
    n_show = (top_n == 0 || top_n >= length(sorted)) ? length(sorted) : top_n

    println("\n" * "="^70)
    println(
        "ISLAND DIAGNOSTIC REPORT  (AC-only connectivity, $(length(components)) islands)",
    )
    println("="^70)

    for row in eachrow(summary_df[1:n_show, :])
        println(
            "\n  Island #$(row.island_id)  [rank $(row.rank) / $(length(sorted))]" *
            "  — $(row.n_buses) buses",
        )
        println("  Zones      : " * replace(row.zones, ";" => ", "))
        println("  Voltage kV : " * replace(row.voltage_kv, ";" => ", "))
        println("  DC bridge  : $(row.dc_bridge)")
        diag_str =
            row.diagnosis == "SUSPECT" ?
            "SUSPECT (multi-kV in zone: $(replace(row.suspect_zones, ";" => ", ")))" :
            row.diagnosis
        println("  Diagnosis  : $diag_str")
    end

    if n_show < length(sorted)
        remaining = length(sorted) - n_show
        singleton_count = count(r -> r.diagnosis == "SINGLETON", eachrow(summary_df))
        println(
            "\n  ... $remaining smaller islands not shown ($singleton_count singletons total)",
        )
    end
    println("="^70)

    return summary_df, components, node_comp
end

"""
    export_island_diagnostics(summary_df, output_path)

Write the island diagnostic summary DataFrame to a CSV file.
"""
function export_island_diagnostics(summary_df::DataFrame, output_path::String)
    CSV.write(output_path, summary_df)
    println("Island diagnostics exported to CSV: $output_path")
end

"""
    detect_islands(lines_df, tielines_df, node_info, dclines_df)

Build the original-network graph (AC + DC edges) and label each node with its
connected-component island index. DC lines are included as graph edges so that
DC-only connections appear in the plot and island detection is correct.
"""
function detect_islands(
    lines_df::DataFrame,
    tielines_df::DataFrame,
    node_info::DataFrame,
    dclines_df::DataFrame = DataFrame(),
)
    # Combine AC lines for connectivity
    all_lines = vcat(lines_df, tielines_df, cols = :union)

    n_nodes = nrow(node_info)
    g = SimpleGraph(n_nodes)

    for row in eachrow(all_lines)
        if hasproperty(row, :From) && hasproperty(row, :To)
            add_edge!(g, Int(row.From), Int(row.To))
        end
    end

    # Add DC lines as edges (they contribute to connectivity but not to Y-bus)
    for row in eachrow(dclines_df)
        if hasproperty(row, :From) && hasproperty(row, :To)
            add_edge!(g, Int(row.From), Int(row.To))
        end
    end

    components = connected_components(g)
    island_labels = zeros(Int, n_nodes)
    for (i, comp) in enumerate(components)
        island_labels[comp] .= i
    end

    node_info[!, :island] = island_labels
    println("\nIsland Detection: Found $(length(components)) island(s)")
    return components, node_info, g
end
