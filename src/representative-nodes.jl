# --- REPRESENTATIVE NODE SELECTION FUNCTION ---

"""
    select_representative_nodes(Ybus, node_info)

Select a single representative node (RN) from each unique 'Zone' based
on the highest interconnection degree.

# Arguments
- `Ybus::SparseArrays.SparseMatrixCSC{ComplexF64}`: Network admittance matrix
- `node_info::DataFrames.DataFrame`: Node information DataFrame

# Returns
- `rep_nodes::DataFrames.DataFrame`: DataFrame with selected representative nodes
- `node_info::DataFrames.DataFrame`: Updated node_info with is_representative flag set
"""
function select_representative_nodes(
    Ybus::SparseArrays.SparseMatrixCSC{ComplexF64},
    node_info::DataFrames.DataFrame,
)
    println("Selecting representative nodes based on interconnection degree per Zone...")

    n_buses = size(Ybus, 1)
    degree = zeros(Int, n_buses)
    B = -LinearAlgebra.imag.(LinearAlgebra.Matrix(Ybus))

    for i = 1:n_buses
        # Count connections (where susceptance is non-zero)
        degree[i] = count(j -> (j != i) && (abs(B[i, j]) > 1e-8), 1:n_buses)
    end

    rep_nodes = DataFrames.DataFrame(
        new_id = Int[],
        old_name = String[],
        zone = String[],
        area = String[],
        degree = Int[],
    )

    unique_zones = DataFrames.unique(node_info.Zone)

    for zone in unique_zones
        zone_nodes = DataFrames.filter(row -> row.Zone == zone, node_info)
        node_ids = zone_nodes.new_id

        if isempty(node_ids)
            continue
        end

        zone_degrees = degree[node_ids]
        max_degree_idx_in_zone = argmax(zone_degrees)
        selected_id = node_ids[max_degree_idx_in_zone]

        node_idx = findfirst(node_info.new_id .== selected_id)
        node_row = node_info[node_idx, :]

        push!(
            rep_nodes,
            (
                selected_id,
                node_row.old_name,
                node_row.Zone,
                node_row.Area,
                degree[selected_id],
            ),
        )

        node_info[node_idx, :is_representative] = true
    end

    println(
        "Selected ",
        DataFrames.nrow(rep_nodes),
        " representative nodes (one per Zone).",
    )
    return rep_nodes, node_info
end
