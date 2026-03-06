"""
    detect_islands(lines_df::DataFrame, tielines_df::DataFrame, node_info::DataFrame)
"""
function detect_islands(lines_df::DataFrame, tielines_df::DataFrame, node_info::DataFrame)
    # Combine lines for original connectivity
    all_lines = vcat(lines_df, tielines_df, cols = :union)

    n_nodes = nrow(node_info)
    g = SimpleGraph(n_nodes)

    for row in eachrow(all_lines)
        # Use numerical IDs assigned during preprocessing
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
