"""
    select_representative_nodes(Ybus::SparseMatrixCSC{ComplexF64}, node_info::DataFrame)

Select representative nodes using one of two modes controlled by CONFIG.rep_node_mode:

- "auto" (default): Select top `CONFIG.rep_node_k_per_zone` nodes per zone by
  degree, using incident capacity as a tie-breaker. If an AC island is left
  without a representative, add the best-ranked bus from that island.
- "manual_excel": Use nodes marked in column `IsRepresentative` in the Nodes sheet

If manual mode is selected but the column is missing, falls back to auto mode with a warning.
Always ensures :is_representative column exists in node_info.
"""
function select_representative_nodes(
    Ybus::SparseMatrixCSC{ComplexF64},
    node_info::DataFrame,
    numbered_lines::DataFrame,
    numbered_tielines::DataFrame,
)
    mode = CONFIG.rep_node_mode
    println("Representative node selection mode: $mode")

    # Ensure column exists (initialise to false if missing)
    if !hasproperty(node_info, :is_representative)
        node_info[!, :is_representative] = fill(false, nrow(node_info))
    end

    # ------------------------------------------------------------------
    # MANUAL EXCEL MODE
    # ------------------------------------------------------------------
    if mode == "manual_excel"
        col_name = "IsRepresentative"

        if !hasproperty(node_info, col_name)
            @warn "Column '$col_name' not found. Falling back to auto mode."
            mode = "auto"
        else
            # Flexible truthy check
            is_rep = map(node_info[!, col_name]) do v
                if ismissing(v)
                    false
                elseif v isa Bool
                    v
                elseif v isa Number
                    !iszero(v)
                else
                    s = lowercase(string(v))
                    s ∈ ("yes", "y", "true", "1")
                end
            end

            rep_mask = BitVector(is_rep)
            rep_nodes_df = node_info[rep_mask, :]

            if isempty(rep_nodes_df)
                @warn "No nodes marked as representative in column '$col_name'. Falling back to auto mode."
                mode = "auto"
            else
                println(
                    "Manual selection from Excel: $(nrow(rep_nodes_df)) representative nodes selected.",
                )

                # Mark selected nodes
                node_info[!, :is_representative] .= false
                node_info[rep_mask, :is_representative] .= true

                # Return minimal rep_nodes DataFrame
                rep_nodes = select(rep_nodes_df, :new_id, :old_name, :Zone, :Area)

                return rep_nodes, node_info
            end
        end
    end

    # ------------------------------------------------------------------
    # AUTO MODE (top-k by degree per zone)
    # ------------------------------------------------------------------
    if mode != "auto"
        error("Unknown rep_node_mode: '$mode'. Valid: \"auto\", \"manual_excel\"")
    end

    high_res = Set(CONFIG.high_res_zones)

    if !isempty(high_res)
        println(
            "High-resolution zones (ALL buses retained): $(join(sort(collect(high_res)), ", "))",
        )
        println("Selecting top $(CONFIG.rep_node_k_per_zone) node(s) per remaining zone...")
    else
        println("Selecting top $(CONFIG.rep_node_k_per_zone) node(s) per zone...")
    end
    println(
        "Criteria: 1. Interconnection Degree, 2. Total Incident Line Capacity (Tie-breaker)",
    )

    n_buses = size(Ybus, 1)
    degree = zeros(Int, n_buses)
    line_cap_sum = zeros(Float64, n_buses)

    # 1. Calculate Interconnection Degree
    B = -imag.(Matrix(Ybus))
    threshold = CONFIG.rep_node_degree_threshold
    for i = 1:n_buses
        degree[i] = count(j -> (j != i) && (abs(B[i, j]) > threshold), 1:n_buses)
    end

    # 2. Calculate Total Capacity of connected lines for each node
    all_physical_lines = vcat(numbered_lines, numbered_tielines, cols = :union)

    for row in eachrow(all_physical_lines)
        cap = hasproperty(row, :Capacity_pu) ? row.Capacity_pu : 0.0
        line_cap_sum[row.From] += cap
        line_cap_sum[row.To] += cap
    end

    rep_nodes = DataFrame(
        new_id = Int[],
        old_name = String[],
        zone = String[],
        area = String[],
        degree = Int[],
        total_line_cap = Float64[],
    )

    unique_zones = unique(node_info.Zone)
    k = CONFIG.rep_node_k_per_zone

    for zone in unique_zones
        zone_df = filter(row -> row.Zone == zone, node_info)
        if nrow(zone_df) == 0
            continue
        end

        zone_ids = zone_df.new_id

        if zone in high_res
            # High-resolution zone: retain ALL buses
            selected_ids = zone_ids
        else
            # Standard mode: top-k by degree then capacity
            sorted_idx =
                sortperm(collect(zip(degree[zone_ids], line_cap_sum[zone_ids])); rev = true)
            selected_idx = sorted_idx[1:min(k, length(sorted_idx))]
            selected_ids = zone_ids[selected_idx]
        end

        for sel_id in selected_ids
            node_idx = findfirst(==(sel_id), node_info.new_id)
            node_row = node_info[node_idx, :]

            push!(
                rep_nodes,
                (
                    new_id = sel_id,
                    old_name = node_row.old_name,
                    zone = node_row.Zone,
                    area = node_row.Area,
                    degree = degree[sel_id],
                    total_line_cap = line_cap_sum[sel_id],
                ),
            )

            node_info[node_idx, :is_representative] = true
        end
    end

    # ------------------------------------------------------------------
    # Guarantee at least one representative per AC connected component.
    # Selection above is per-zone; if a zone's top-k nodes all happen to
    # land in one AC island while another island shares the same zone
    # label, that island would otherwise get zero representatives and be
    # silently Kron-eliminated (see the multi-island regularisation in
    # kron_reduce_ybus).
    # ------------------------------------------------------------------
    g_ac = SimpleGraph(n_buses)
    for i = 1:n_buses, j = (i+1):n_buses
        abs(B[i, j]) > threshold && add_edge!(g_ac, i, j)
    end
    components = connected_components(g_ac)
    rep_id_set = Set(rep_nodes.new_id)
    n_forced = 0
    for comp in components
        if !any(id -> id in rep_id_set, comp)
            forced_id = first(
                sort(
                    collect(comp);
                    by = id -> (degree[id], line_cap_sum[id], -id),
                    rev = true,
                ),
            )
            node_idx = findfirst(==(forced_id), node_info.new_id)
            node_row = node_info[node_idx, :]

            push!(
                rep_nodes,
                (
                    new_id = forced_id,
                    old_name = node_row.old_name,
                    zone = node_row.Zone,
                    area = node_row.Area,
                    degree = degree[forced_id],
                    total_line_cap = line_cap_sum[forced_id],
                ),
            )
            node_info[node_idx, :is_representative] = true
            push!(rep_id_set, forced_id)
            n_forced += 1
        end
    end
    if n_forced > 0
        @warn "Zone-based selection left $(n_forced) AC island(s) without a representative " *
              "node. Added the best-ranked bus in each as a forced representative to " *
              "avoid silently eliminating the island in Kron reduction."
    end

    n_hires = count(r -> r.zone in high_res, eachrow(rep_nodes))
    n_ext = nrow(rep_nodes) - n_hires
    if !isempty(high_res)
        println(
            "Selected total $(nrow(rep_nodes)) representative nodes" *
            " ($n_hires high-res buses + $n_ext external representatives).",
        )
    else
        println("Selected total $(nrow(rep_nodes)) representative nodes.")
    end
    return rep_nodes, node_info
end
