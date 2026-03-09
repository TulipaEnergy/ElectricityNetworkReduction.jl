"""
    plot_network(g, node_info, lines_df; title, n_size, f_size, show_names)

Plot a network graph with nodes coloured by island (connected component).
Only called when `CONFIG.enable_plots = true`.
Uses `Latitude`/`Longitude` columns for geo-layout if present in `node_info`,
otherwise uses a spring layout.
"""
function plot_network(
    g::SimpleGraph,
    node_info,
    lines_df;
    title = "Network",
    n_size = 0.15,
    f_size = 6,
    show_names = true,
)
    # 1. Edge Color: Use Red for TieLines if available, else Gray
    edge_colors = if hasproperty(lines_df, :IsTieLine)
        [row.IsTieLine ? :red : :gray for row in eachrow(lines_df)]
    else
        :blue
    end
    # 2. Node Color: Use islands if detected
    node_colors = hasproperty(node_info, :island) ? node_info.island : :viridis

    # 3. Coordinates: Use Lat/Lon if they exist
    has_valid_coords =
        hasproperty(node_info, :Latitude) &&
        hasproperty(node_info, :Longitude) &&
        (sum(abs.(node_info.Latitude)) + sum(abs.(node_info.Longitude)) > 0)

    # Define names only if show_names is true
    node_labels = show_names ? node_info.new_id : ""

    if has_valid_coords
        return graphplot(
            g,
            x = node_info.Longitude,
            y = node_info.Latitude,
            markercolor = node_colors,
            edgestrokecolor = edge_colors,
            names = node_labels,
            nodesize = n_size,
            names_size = f_size,
            curves = false,
            title = title,
        )
    else
        return graphplot(
            g,
            markercolor = node_colors,
            edgestrokecolor = edge_colors,
            names = node_labels,
            nodesize = n_size,
            names_size = f_size,
            curves = false,
            title = title,
        )
    end
end

"""
    plot_original_vs_reduced(g_orig, nodes_orig, lines_orig, g_red, nodes_red, lines_red, output_path)

Plot original and reduced networks side-by-side (1400×700 px) and save to `output_path`.
Only called when `CONFIG.enable_plots = true`.
"""
function plot_original_vs_reduced(
    g_orig,
    nodes_orig,
    lines_orig,
    g_red,
    nodes_red,
    lines_red,
    output_path,
)
    # Plot 1: Original Network - Names disabled for a "dots and lines" look
    p1 = plot_network(
        g_orig,
        nodes_orig,
        lines_orig;
        title = "Original Network",
        n_size = 0.1,
        f_size = 0,
        show_names = false,
    )
    # Plot 2: Reduced Network - Names enabled for clarity
    p2 = plot_network(
        g_red,
        nodes_red,
        lines_red;
        title = "Reduced Network",
        n_size = 0.3,
        f_size = 6,
        show_names = true,
    )
    plt_combined = plot(p1, p2, layout = (1, 2), size = (1400, 700))
    savefig(plt_combined, output_path)
    return plt_combined
end
