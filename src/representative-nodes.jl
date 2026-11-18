"""
    select_representative_nodes(Ybus::SparseMatrixCSC{ComplexF64}, node_info::DataFrame)

Select representative nodes using one of two modes controlled by CONFIG.rep_node_mode:

- "auto" (default): Select top `CONFIG.rep_node_k_per_zone` nodes per zone by
  degree, using incident capacity as a tie-breaker.
- "manual_excel": Use nodes marked in column `IsRepresentative` in the Nodes sheet

In both modes, every bus of a zone in `CONFIG.high_res_zones` is retained, and
any AC island left without a representative gets its best-ranked bus added.

If manual mode is selected but the column is missing or empty, falls back to
auto mode with a warning. Always ensures :is_representative column exists in node_info.
"""
function select_representative_nodes(
    Ybus::SparseMatrixCSC{ComplexF64},
    node_info::DataFrame,
    numbered_lines::DataFrame,
    numbered_tielines::DataFrame,
)
    mode = CONFIG.rep_node_mode
    println("Representative node selection mode: $mode")
    mode in ("auto", "manual_excel") ||
        error("Unknown rep_node_mode: '$mode'. Valid: \"auto\", \"manual_excel\"")

    high_res = Set(CONFIG.high_res_zones)

    # ------------------------------------------------------------------
    # Ranking data shared by both modes: interconnection degree, then total
    # incident line capacity as a tie-breaker.
    # ------------------------------------------------------------------
    n_buses = size(Ybus, 1)
    degree = zeros(Int, n_buses)
    line_cap_sum = zeros(Float64, n_buses)

    B = -imag.(Matrix(Ybus))
    threshold = CONFIG.rep_node_degree_threshold
    for i = 1:n_buses
        degree[i] = count(j -> (j != i) && (abs(B[i, j]) > threshold), 1:n_buses)
    end

    all_physical_lines = vcat(numbered_lines, numbered_tielines, cols = :union)
    for row in eachrow(all_physical_lines)
        cap = hasproperty(row, :Capacity_pu) ? row.Capacity_pu : 0.0
        line_cap_sum[row.From] += cap
        line_cap_sum[row.To] += cap
    end

    # ------------------------------------------------------------------
    # MANUAL EXCEL MODE: read the flagged nodes (falls back to auto)
    # ------------------------------------------------------------------
    manual_ids = nothing
    if mode == "manual_excel"
        col_name = "IsRepresentative"

        if !hasproperty(node_info, col_name)
            @warn "Column '$col_name' not found. Falling back to auto mode."
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

            if !any(is_rep)
                @warn "No nodes marked as representative in column '$col_name'. Falling back to auto mode."
            else
                manual_ids = node_info.new_id[BitVector(is_rep)]
                println(
                    "Manual selection from Excel: $(length(manual_ids)) representative nodes selected.",
                )
            end
        end
    end

    if !isempty(high_res)
        println(
            "High-resolution zones (ALL buses retained): $(join(sort(collect(high_res)), ", "))",
        )
    end

    # ------------------------------------------------------------------
    # Per-zone selection: high-res zones keep every bus; other zones use the
    # manual flags, or the top-k ranked buses in auto mode.
    # ------------------------------------------------------------------
    if isnothing(manual_ids)
        println(
            "Selecting top $(CONFIG.rep_node_k_per_zone) node(s) per " *
            (isempty(high_res) ? "zone..." : "remaining zone..."),
        )
        println(
            "Criteria: 1. Interconnection Degree, 2. Total Incident Line Capacity (Tie-breaker)",
        )
    end

    selected_ids = Int[]
    k = CONFIG.rep_node_k_per_zone
    for zone in unique(node_info.Zone)
        zone_ids = node_info.new_id[node_info.Zone .== zone]
        isempty(zone_ids) && continue

        if zone in high_res
            append!(selected_ids, zone_ids)
        elseif !isnothing(manual_ids)
            append!(selected_ids, filter(in(manual_ids), zone_ids))
        else
            sorted_idx =
                sortperm(collect(zip(degree[zone_ids], line_cap_sum[zone_ids])); rev = true)
            append!(selected_ids, zone_ids[sorted_idx[1:min(k, length(sorted_idx))]])
        end
    end
    unique!(selected_ids)

    rep_nodes = DataFrame(
        new_id = Int[],
        old_name = String[],
        zone = String[],
        area = String[],
        degree = Int[],
        total_line_cap = Float64[],
    )
    node_info[!, :is_representative] = fill(false, nrow(node_info))

    function _add_rep!(id)
        node_idx = findfirst(==(id), node_info.new_id)
        node_row = node_info[node_idx, :]
        push!(
            rep_nodes,
            (
                new_id = id,
                old_name = string(node_row.old_name),
                zone = string(node_row.Zone),
                area = string(node_row.Area),
                degree = degree[id],
                total_line_cap = line_cap_sum[id],
            ),
        )
        node_info[node_idx, :is_representative] = true
    end
    foreach(_add_rep!, selected_ids)

    # ------------------------------------------------------------------
    # Guarantee at least one representative per AC connected component.
    # Selection above is per-zone; if a zone's top-k nodes all happen to
    # land in one AC island while another island shares the same zone
    # label (or manual flags miss an island entirely), that island would
    # otherwise get zero representatives and be silently Kron-eliminated
    # (see the multi-island regularisation in kron_reduce_ybus).
    # ------------------------------------------------------------------
    g_ac = SimpleGraph(n_buses)
    for i = 1:n_buses, j = (i+1):n_buses
        abs(B[i, j]) > threshold && add_edge!(g_ac, i, j)
    end
    rep_id_set = Set(rep_nodes.new_id)
    n_forced = 0
    for comp in connected_components(g_ac)
        if !any(id -> id in rep_id_set, comp)
            forced_id = first(
                sort(
                    collect(comp);
                    by = id -> (degree[id], line_cap_sum[id], -id),
                    rev = true,
                ),
            )
            _add_rep!(forced_id)
            push!(rep_id_set, forced_id)
            n_forced += 1
        end
    end
    if n_forced > 0
        @warn "Representative selection left $(n_forced) AC island(s) without a representative " *
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
