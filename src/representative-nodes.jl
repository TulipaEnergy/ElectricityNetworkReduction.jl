"""
    select_representative_nodes(Ybus::SparseMatrixCSC{ComplexF64}, node_info::DataFrame)

Select representative nodes using one of two modes controlled by CONFIG.rep_node_mode:

- "auto" (default): Select top `CONFIG.rep_node_k_per_zone` highest-degree nodes per zone
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

    # Ensure column exists (initialize to false if missing)
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

    println("Selecting top $(CONFIG.rep_node_k_per_zone) node(s) per zone...")
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
    # Combine all physical connections to iterate through them
    all_physical_lines = vcat(numbered_lines, numbered_tielines, cols = :union)

    for row in eachrow(all_physical_lines)
        # Add capacity to both the 'From' and 'To' node indices
        cap = hasproperty(row, :Capacity) ? row.Capacity : 0.0
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

        # 3. Enhanced Sorting Logic
        # zip() creates tuples of (degree, total_line_capacity)
        # sortperm with rev=true sorts primarily by degree, then by capacity
        sorted_idx =
            sortperm(collect(zip(degree[zone_ids], line_cap_sum[zone_ids])); rev = true)

        selected_idx = sorted_idx[1:min(k, length(sorted_idx))]
        selected_ids = zone_ids[selected_idx]

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

    println("Selected total $(nrow(rep_nodes)) representative nodes.")
    return rep_nodes, node_info
end
