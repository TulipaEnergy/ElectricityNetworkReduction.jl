"""
    _convex_hull_2d(pts) -> Vector{Point2f}

Compute the 2-D convex hull via Andrew's monotone-chain algorithm.
Pure Julia, no dependencies.  Returns the hull vertices in counter-clockwise
order.  Falls back to the original point set for degenerate inputs (≤ 2 pts).
"""
function _convex_hull_2d(pts::Vector{Point2f})
    n = length(pts)
    n ≤ 2 && return pts
    sorted = sort(pts; by = p -> (p[1], p[2]))
    cross2d(O, A, B) = (A[1] - O[1]) * (B[2] - O[2]) - (A[2] - O[2]) * (B[1] - O[1])
    lower = Point2f[]
    for p in sorted
        while length(lower) ≥ 2 && cross2d(lower[end-1], lower[end], p) ≤ 0
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = Point2f[]
    for p in reverse(sorted)
        while length(upper) ≥ 2 && cross2d(upper[end-1], upper[end], p) ≤ 0
            pop!(upper)
        end
        push!(upper, p)
    end
    hull = vcat(lower[1:(end-1)], upper[1:(end-1)])
    return length(hull) ≥ 3 ? hull : pts
end

"""
    _draw_highres_highlight!(ax, nodes_df, cos_lat)

Overlay a semi-transparent convex-hull polygon on `ax` for every zone listed
in `CONFIG.high_res_zones`, using the geographic positions in `nodes_df`.
A single bold zone-code + "(high-res)" label is placed above the cluster.

Should be called BEFORE `graphplot!` so the network nodes render on top of
the shaded area.  No-op when `CONFIG.high_res_zones` is empty or when
coordinates are unavailable.
"""
function _draw_highres_highlight!(
    ax::Makie.AbstractAxis,
    nodes_df::DataFrame,
    cos_lat::Float64,
)
    isempty(CONFIG.high_res_zones) && return

    high_res_set = Set(string.(CONFIG.high_res_zones))
    pad = 0.35   # padding added in each cardinal direction (scaled-degree units)

    for z in sort(collect(high_res_set))
        hr = filter(r -> string(r.Zone) == z, eachrow(nodes_df))
        isempty(hr) && continue

        # Positions in the same scaled coordinate space as the axes
        pts = [Point2f(row.Latitude * cos_lat, row.Longitude) for row in hr]

        cx = sum(p[1] for p in pts) / length(pts)
        cy = sum(p[2] for p in pts) / length(pts)

        # Pad the point set with 4 cardinal sentinels so even a single-bus
        # high-res zone produces a visible polygon rather than a degenerate shape.
        padded = vcat(
            pts,
            [
                Point2f(cx + pad, cy),
                Point2f(cx - pad, cy),
                Point2f(cx, cy + pad),
                Point2f(cx, cy - pad),
            ],
        )
        hull = _convex_hull_2d(padded)

        # Semi-transparent amber fill + dashed border
        poly!(
            ax,
            hull;
            color = (:orange, 0.10),
            strokecolor = (:darkorange, 0.70),
            strokewidth = 1.8,
            linestyle = :dash,
        )

        # Single label just above the cluster — bold zone code + annotation
        label_y = maximum(p[2] for p in pts) + pad * 0.9
        text!(
            ax,
            z * " (high-res)";
            position = Point2f(cx, label_y),
            align = (:center, :bottom),
            fontsize = 10,
            color = :darkorange,
            font = :bold,
        )
    end
end

"""
    _gis_params(n_orig, n_red) -> NamedTuple

Compute size-tier parameters for CairoMakie/GraphMakie plots based on the
number of buses in the original and reduced networks.  All functions that
produce PNG output call this helper so visual quality scales automatically
from a 6-bus test case to a 6792-bus European grid.
"""
function _gis_params(n_orig::Int, n_red::Int = 0)
    # ── Comparison figure dimensions (two panels side-by-side) ──────────────
    cmp_w, cmp_h =
        n_orig ≤ 20 ? (1000, 800) :
        n_orig ≤ 100 ? (1600, 900) :
        n_orig ≤ 500 ? (2200, 1100) : n_orig ≤ 2000 ? (2800, 1200) : (3400, 1400)

    # ── Single-network figure dimensions ────────────────────────────────────
    single_w, single_h =
        n_orig ≤ 20 ? (800, 700) :
        n_orig ≤ 100 ? (1000, 800) :
        n_orig ≤ 500 ? (1300, 950) : n_orig ≤ 2000 ? (1500, 1100) : (1700, 1300)

    # ── Original-network node diameter ──────────────────────────────────────
    o_sz = Float32(
        n_orig ≤ 10 ? 14 : n_orig ≤ 50 ? 9 : n_orig ≤ 200 ? 6 : n_orig ≤ 1000 ? 4 : 3,
    )

    # ── Reduced-network node diameter ───────────────────────────────────────
    r_sz = Float32(n_red ≤ 5 ? 26 : n_red ≤ 10 ? 20 : n_red ≤ 20 ? 16 : n_red ≤ 50 ? 12 : 8)

    # ── Reduced-network label text size ─────────────────────────────────────
    r_txt = Int(n_red ≤ 5 ? 16 : n_red ≤ 10 ? 14 : n_red ≤ 20 ? 12 : n_red ≤ 50 ? 10 : 9)

    # ── Non-geographic layout: Stress preserves graph distances better than
    #    Spring for small/sparse topologies; Spring scales better for larger. ──
    nongeo = n_orig ≤ 50 ? GraphMakie.Stress(; seed = 42) : GraphMakie.Spring(; seed = 42)

    return (
        cmp_size = (cmp_w, cmp_h),
        single_size = (single_w, single_h),
        o_sz = o_sz,
        r_sz = r_sz,
        r_txt = r_txt,
        nongeo = nongeo,
    )
end

"""
    plot_network(g, node_info, lines_df; title, n_size, f_size, show_names)

Plot a network graph with nodes coloured by island (connected component).
Only called when `CONFIG.enable_plots = true`.

Three separate graphplot layers are drawn so each line type gets a reliable
single-colour call:

  • Gray  — AC lines
  • Red   — AC tie-lines
  • Blue  — DC interconnectors (curved, so parallel AC+DC pairs appear distinct)

Uses `Latitude`/`Longitude` columns for geo-layout if present in `node_info`;
otherwise uses a deterministic circular layout.
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
    n = nv(g)

    # ── Detect which columns hold the bus endpoint IDs ──────────────────────
    if hasproperty(lines_df, :From) && hasproperty(lines_df, :To)
        from_col, to_col = :From, :To
    elseif hasproperty(lines_df, :synth_line_from) && hasproperty(lines_df, :synth_line_to)
        from_col, to_col = :synth_line_from, :synth_line_to
    else
        from_col, to_col = nothing, nothing
    end

    node_id_to_vertex = Dict(node_info[i, :new_id] => i for i = 1:nrow(node_info))

    # ── Node positions ───────────────────────────────────────────────────────
    has_valid_coords =
        hasproperty(node_info, :Latitude) &&
        hasproperty(node_info, :Longitude) &&
        (sum(abs.(node_info.Latitude)) + sum(abs.(node_info.Longitude)) > 0)

    if has_valid_coords
        # The Excel file has swapped column names:
        #   node_info.Latitude  = actual east-west coordinate (longitude)
        #   node_info.Longitude = actual north-south coordinate (latitude)
        # Applying cos(mean_lat) scaling to x makes the aspect ratio match a
        # Mercator map (1° longitude ≈ cos(lat) × 111 km vs 1° latitude ≈ 111 km).
        y_pos = collect(Float64, node_info.Longitude)       # actual N-S (latitude)
        x_pos = collect(Float64, node_info.Latitude)        # actual E-W (longitude)
        cos_lat = cos(deg2rad(sum(y_pos) / length(y_pos)))
        x_pos = x_pos .* cos_lat
    else
        angles = n > 1 ? collect(range(π / 2, π / 2 + 2π * (1 - 1 / n); length = n)) : [0.0]
        x_pos = cos.(angles)
        y_pos = sin.(angles)
    end

    node_labels = show_names ? node_info.new_id : ""
    node_colors = hasproperty(node_info, :island) ? node_info.island : :steelblue

    if isnothing(from_col) || nrow(lines_df) == 0
        return graphplot(
            g,
            x = x_pos,
            y = y_pos,
            markercolor = node_colors,
            edgestrokecolor = :gray,
            names = node_labels,
            nodesize = n_size,
            names_size = f_size,
            curves = false,
            title = title,
        )
    end

    ac_pairs = Set{Tuple{Int,Int}}()
    tie_pairs = Set{Tuple{Int,Int}}()
    dc_pairs = Set{Tuple{Int,Int}}()

    for row in eachrow(lines_df)
        from_id = Int(getproperty(row, from_col))
        to_id = Int(getproperty(row, to_col))
        u = get(node_id_to_vertex, from_id, nothing)
        v = get(node_id_to_vertex, to_id, nothing)
        (isnothing(u) || isnothing(v)) && continue

        key = (min(u, v), max(u, v))

        is_dc =
            hasproperty(row, :IsDCLine) ? row.IsDCLine :
            hasproperty(row, :is_dc) ? row.is_dc : false
        is_tie = hasproperty(row, :IsTieLine) ? row.IsTieLine : false

        if is_dc
            push!(dc_pairs, key)
        elseif is_tie
            push!(tie_pairs, key)
        else
            push!(ac_pairs, key)
        end
    end

    function _build_graph(pairs)
        h = SimpleGraph(n)
        for (u, v) in pairs
            add_edge!(h, u, v)
        end
        return h
    end

    g_ac = _build_graph(ac_pairs)
    g_tie = _build_graph(tie_pairs)
    g_dc = _build_graph(dc_pairs)

    overlay_kw = (
        x = x_pos,
        y = y_pos,
        markercolor = node_colors,
        names = fill("", n),
        nodesize = n_size,
        names_size = 0,
    )

    p = graphplot(
        g_ac,
        x = x_pos,
        y = y_pos,
        markercolor = node_colors,
        edgestrokecolor = :gray,
        names = node_labels,
        nodesize = n_size,
        names_size = f_size,
        curves = false,
        title = title,
        aspect_ratio = :equal,
    )

    if ne(g_tie) > 0
        graphplot!(p, g_tie; overlay_kw..., edgestrokecolor = :red, curves = false)
    end

    if ne(g_dc) > 0
        graphplot!(
            p,
            g_dc;
            overlay_kw...,
            edgestrokecolor = :royalblue,
            edgelinewidth = 3,
            curves = true,
        )
    end

    return p
end

# ==============================================================================
# Lon/Lat Visualisation — network plotted directly on coordinate axes
# Backend: CairoMakie + GraphMakie
# ==============================================================================

"""
    _edge_info(g, node_info, lines_df) -> (edge_colors, edge_widths)

Build per-edge colour and width vectors (aligned with `Graphs.edges(g)`) from
line-type metadata in `lines_df`.

  :gray      — AC line
  :red       — AC tie-line
  :royalblue — DC interconnector (thicker)
"""
function _edge_info(g::SimpleGraph, node_info::DataFrame, lines_df::DataFrame)
    n_edges = ne(g)
    n_edges == 0 && return Symbol[], Float32[]

    if hasproperty(lines_df, :From) && hasproperty(lines_df, :To)
        from_col, to_col = :From, :To
    elseif hasproperty(lines_df, :synth_line_from) && hasproperty(lines_df, :synth_line_to)
        from_col, to_col = :synth_line_from, :synth_line_to
    else
        return fill(:gray, n_edges), fill(1.2f0, n_edges)
    end

    nid2v = Dict(node_info[i, :new_id] => i for i = 1:nrow(node_info))

    etype = Dict{Tuple{Int,Int},Symbol}()
    for row in eachrow(lines_df)
        u = get(nid2v, Int(getproperty(row, from_col)), nothing)
        v = get(nid2v, Int(getproperty(row, to_col)), nothing)
        (isnothing(u) || isnothing(v)) && continue
        key = (min(u, v), max(u, v))

        is_dc =
            hasproperty(row, :IsDCLine) ? row.IsDCLine :
            hasproperty(row, :is_dc) ? row.is_dc : false
        is_tie = hasproperty(row, :IsTieLine) ? row.IsTieLine : false

        if is_dc
            etype[key] = :dc
        elseif is_tie && get(etype, key, :ac) != :dc
            etype[key] = :tie
        elseif !haskey(etype, key)
            etype[key] = :ac
        end
    end

    colors = Vector{Symbol}(undef, n_edges)
    widths = Vector{Float32}(undef, n_edges)
    for (i, e) in enumerate(edges(g))
        key = (min(src(e), dst(e)), max(src(e), dst(e)))
        t = get(etype, key, :ac)
        colors[i] = t == :dc ? :royalblue : t == :tie ? :red : :gray
        widths[i] = Float32(t == :dc ? 2.5 : 1.2)
    end
    return colors, widths
end

"""
    _red_node_sizes(nodes_df, rep_sz, hr_sz) -> Vector{Float32}

Per-node size vector for the reduced network.
External zone representative nodes get `rep_sz` (large).
Individual buses inside high-resolution zones get `hr_sz` (small), so the
lines between them stay visible rather than being hidden under large markers.
Falls back to all-`rep_sz` when no high-res zones are configured.
"""
function _red_node_sizes(nodes_df::DataFrame, rep_sz::Float32, hr_sz::Float32)
    isempty(CONFIG.high_res_zones) && return fill(rep_sz, nrow(nodes_df))
    high_res_set = Set(string.(CONFIG.high_res_zones))
    return Float32[
        (string(row.Zone) in high_res_set) ? hr_sz : rep_sz for row in eachrow(nodes_df)
    ]
end

function _zone_colors(node_info::DataFrame)
    zones = unique(string.(node_info.Zone))
    # :tab10 gives 10 maximally distinct colors (blue, orange, green, red, purple,
    # brown, pink, gray, olive, cyan) — each index is a clearly different hue.
    # This ensures even 2–3 zones get visually distinct colors, unlike :tab20c
    # which groups 4 similar shades together (3 zones would all appear as blue).
    # For > 10 zones we cycle back through the same hues.
    cmap = Makie.to_colormap(:tab10)
    zone_to_col = Dict(z => cmap[mod1(i, length(cmap))] for (i, z) in enumerate(zones))
    return [zone_to_col[string(row.Zone)] for row in eachrow(node_info)]
end

"""
    _axis_limits(lons, lats; pad) -> (lon_lo, lon_hi, lat_lo, lat_hi)

Return axis limits with `pad` fractional padding on each side (minimum 1°).
"""
function _axis_limits(lons, lats; pad = 0.08)
    dlon = max(1.0, maximum(lons) - minimum(lons))
    dlat = max(1.0, maximum(lats) - minimum(lats))
    return (
        minimum(lons) - pad * dlon,
        maximum(lons) + pad * dlon,
        minimum(lats) - pad * dlat,
        maximum(lats) + pad * dlat,
    )
end

"""
    plot_network_gis(g, node_info, lines_df; title, show_names, node_sz) -> Figure

Plot the power network on a plain lon/lat axis.  Nodes are coloured by zone;
edges are coloured by type (gray = AC, red = tie-line, blue = DC).
No external GIS data is required.
"""
function plot_network_gis(
    g::SimpleGraph,
    node_info::DataFrame,
    lines_df::DataFrame;
    title::String = "Network",
    show_names::Bool = false,
    node_sz::Real = 0,      # 0 = auto-scale from _gis_params
)
    n = nv(g)
    p = _gis_params(n)
    sz = node_sz > 0 ? Float32(node_sz) : p.o_sz

    has_valid_coords =
        hasproperty(node_info, :Latitude) &&
        hasproperty(node_info, :Longitude) &&
        (sum(abs.(node_info.Latitude)) + sum(abs.(node_info.Longitude)) > 0)

    node_colors = _zone_colors(node_info)
    edge_colors, edge_widths = _edge_info(g, node_info, lines_df)

    nlabels = if show_names
        if hasproperty(node_info, :Zone)
            # In hybrid high-res mode, individual buses inside the high-res zone(s)
            # are left unlabelled — they are far too numerous to read and the plot is
            # for topology overview only.  External representative nodes still show
            # their zone code (e.g. "DE", "FR").
            high_res_set = Set(string.(CONFIG.high_res_zones))
            zone_count = Dict{String,Int}()
            [
                begin
                    z = string(row.Zone)
                    if !isempty(high_res_set) && z in high_res_set
                        ""           # high-res individual bus — suppress label
                    else
                        zone_count[z] = get(zone_count, z, 0) + 1
                        zone_count[z] == 1 ? z : z * "-" * string(zone_count[z])
                    end
                end for row in eachrow(node_info)
            ]
        elseif hasproperty(node_info, :old_name)
            string.(node_info.old_name)
        else
            string.(node_info.new_id)
        end
    else
        fill("", n)
    end

    # When showing names (reduced network), differentiate node sizes:
    # high-res zone buses use a smaller marker so their connecting lines stay visible.
    node_sz_vec = show_names ? _red_node_sizes(node_info, sz, max(3.0f0, sz * 0.45f0)) : sz

    fig = Figure(size = p.single_size)

    if has_valid_coords
        # Excel column names are swapped vs geographic convention:
        #   .Latitude  = actual E-W (longitude),  .Longitude = actual N-S (latitude)
        actual_lons = node_info.Latitude
        actual_lats = node_info.Longitude
        cos_lat = cos(deg2rad(sum(actual_lats) / length(actual_lats)))
        # Scale x by cos(mean_lat): 1° lon × cos(lat) ≈ 1° lat in km → Mercator-like aspect
        x_geo = actual_lons .* cos_lat
        y_geo = actual_lats
        positions =
            [Point2f(row.Latitude * cos_lat, row.Longitude) for row in eachrow(node_info)]
        x_lo, x_hi, y_lo, y_hi = _axis_limits(x_geo, y_geo)

        # Custom degree ticks so axes show real geographic values despite x scaling
        lon_ticks = range(
            ceil(minimum(actual_lons) / 10) * 10,
            floor(maximum(actual_lons) / 10) * 10;
            step = 10,
        )
        lat_ticks = range(
            ceil(minimum(actual_lats) / 10) * 10,
            floor(maximum(actual_lats) / 10) * 10;
            step = 10,
        )

        ax = Axis(
            fig[1, 1];
            title = title,
            titlesize = 18,
            xlabel = "Longitude",
            ylabel = "Latitude",
            aspect = DataAspect(),
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
            xticks = (
                collect(lon_ticks) .* cos_lat,
                [string(Int(round(v))) * "°" for v in lon_ticks],
            ),
            yticks = (collect(lat_ticks), [string(Int(round(v))) * "°" for v in lat_ticks]),
        )
        CairoMakie.xlims!(ax, x_lo, x_hi)
        CairoMakie.ylims!(ax, y_lo, y_hi)

        # Draw high-res zone highlights before nodes so nodes render on top
        _draw_highres_highlight!(ax, node_info, cos_lat)

        GraphMakie.graphplot!(
            ax,
            g;
            layout = _ -> positions,
            node_color = node_colors,
            node_size = node_sz_vec,
            edge_color = edge_colors,
            edge_width = edge_widths,
            nlabels = nlabels,
            nlabels_textsize = 9,
            nlabels_distance = 4,
            arrow_show = false,
        )
    else
        ax = Axis(
            fig[1, 1];
            title = title,
            titlesize = 18,
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
        )

        GraphMakie.graphplot!(
            ax,
            g;
            layout = p.nongeo,
            node_color = node_colors,
            node_size = node_sz_vec,
            edge_color = edge_colors,
            edge_width = edge_widths,
            nlabels = nlabels,
            nlabels_textsize = 9,
            nlabels_distance = 4,
            arrow_show = false,
        )
    end

    Legend(
        fig[2, 1],
        [
            PolyElement(color = :gray, strokecolor = :transparent),
            PolyElement(color = :red, strokecolor = :transparent),
            PolyElement(color = :royalblue, strokecolor = :transparent),
        ],
        ["AC Line", "AC Tie-Line", "DC Interconnector"];
        orientation = :horizontal,
        framevisible = false,
        labelsize = 13,
    )

    return fig
end

"""
    plot_original_vs_reduced_gis(g_orig, nodes_orig, lines_orig,
                                  g_red,  nodes_red,  lines_red;
                                  main_title) -> Figure

Side-by-side lon/lat comparison (3000×1200 px).
Left panel:  full original network (nodes unlabelled for clarity).
Right panel: reduced network (nodes labelled by name).
Both panels share the same lon/lat bounding box from the original network.
"""
function plot_original_vs_reduced_gis(
    g_orig::SimpleGraph,
    nodes_orig::DataFrame,
    lines_orig::DataFrame,
    g_red::SimpleGraph,
    nodes_red::DataFrame,
    lines_red::DataFrame;
    main_title::String = "Power Network Comparison",
)
    has_valid_coords =
        hasproperty(nodes_orig, :Latitude) &&
        hasproperty(nodes_orig, :Longitude) &&
        (sum(abs.(nodes_orig.Latitude)) + sum(abs.(nodes_orig.Longitude)) > 0)

    p = _gis_params(nv(g_orig), nv(g_red))

    fig = Figure(size = p.cmp_size)
    Label(fig[1, 1:2], main_title; fontsize = 22, tellwidth = false)

    ec_orig, ew_orig = _edge_info(g_orig, nodes_orig, lines_orig)
    ec_red, ew_red = _edge_info(g_red, nodes_red, lines_red)

    # Label reduced-network nodes by zone code.
    # High-res zone buses are unlabelled — the zone highlight polygon + its
    # single "ZZ (high-res)" caption carry all the necessary information.
    # External representative nodes still show their zone code ("DE", "FR", …).
    red_labels = if hasproperty(nodes_red, :Zone)
        high_res_set = Set(string.(CONFIG.high_res_zones))
        zone_count = Dict{String,Int}()
        [
            begin
                z = string(row.Zone)
                if !isempty(high_res_set) && z in high_res_set
                    ""          # high-res individual bus — label suppressed
                else
                    zone_count[z] = get(zone_count, z, 0) + 1
                    zone_count[z] == 1 ? z : z * "-" * string(zone_count[z])
                end
            end for row in eachrow(nodes_red)
        ]
    elseif hasproperty(nodes_red, :old_name)
        string.(nodes_red.old_name)
    else
        string.(nodes_red.new_id)
    end

    if has_valid_coords
        # Excel column names are swapped: .Latitude = actual E-W, .Longitude = actual N-S
        actual_lons = nodes_orig.Latitude
        actual_lats = nodes_orig.Longitude
        cos_lat = cos(deg2rad(sum(actual_lats) / length(actual_lats)))
        x_geo = actual_lons .* cos_lat

        x_lo, x_hi, y_lo, y_hi = _axis_limits(x_geo, actual_lats)

        pos_orig = [Point2f(r.Latitude * cos_lat, r.Longitude) for r in eachrow(nodes_orig)]
        pos_red = [Point2f(r.Latitude * cos_lat, r.Longitude) for r in eachrow(nodes_red)]

        # Shared degree tick marks for both panels
        lon_ticks = range(
            ceil(minimum(actual_lons) / 10) * 10,
            floor(maximum(actual_lons) / 10) * 10;
            step = 10,
        )
        lat_ticks = range(
            ceil(minimum(actual_lats) / 10) * 10,
            floor(maximum(actual_lats) / 10) * 10;
            step = 10,
        )
        xt = (
            collect(lon_ticks) .* cos_lat,
            [string(Int(round(v))) * "°" for v in lon_ticks],
        )
        yt = (collect(lat_ticks), [string(Int(round(v))) * "°" for v in lat_ticks])

        # ── Left: Original network ──────────────────────────────────────────
        ax1 = Axis(
            fig[2, 1];
            title = "Original Network",
            titlesize = 16,
            xlabel = "Longitude",
            ylabel = "Latitude",
            aspect = DataAspect(),
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
            xticks = xt,
            yticks = yt,
        )
        CairoMakie.xlims!(ax1, x_lo, x_hi)
        CairoMakie.ylims!(ax1, y_lo, y_hi)
        GraphMakie.graphplot!(
            ax1,
            g_orig;
            layout = _ -> pos_orig,
            node_color = _zone_colors(nodes_orig),
            node_size = p.o_sz,
            edge_color = ec_orig,
            edge_width = ew_orig,
            nlabels = fill("", nv(g_orig)),
            arrow_show = false,
        )

        # ── Right: Reduced network (full Europe) + high-res inset ──────────────
        ax2 = Axis(
            fig[2, 2];
            title = "Reduced Network",
            titlesize = 16,
            xlabel = "Longitude",
            ylabel = "Latitude",
            aspect = DataAspect(),
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
            xticks = xt,
            yticks = yt,
        )
        CairoMakie.xlims!(ax2, x_lo, x_hi)
        CairoMakie.ylims!(ax2, y_lo, y_hi)

        # Highlight high-res zones before nodes render on top
        _draw_highres_highlight!(ax2, nodes_red, cos_lat)

        GraphMakie.graphplot!(
            ax2,
            g_red;
            layout = _ -> pos_red,
            node_color = _zone_colors(nodes_red),
            node_size = _red_node_sizes(nodes_red, p.r_sz, p.o_sz * 1.8f0),
            edge_color = ec_red,
            edge_width = [w * 1.5f0 for w in ew_red],
            nlabels = red_labels,
            nlabels_textsize = p.r_txt,
            nlabels_distance = 5,
            arrow_show = false,
        )

    else
        # ── Left: Original network (Spring layout) ──────────────────────────
        ax1 = Axis(
            fig[2, 1];
            title = "Original Network",
            titlesize = 16,
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
        )
        GraphMakie.graphplot!(
            ax1,
            g_orig;
            layout = p.nongeo,
            node_color = _zone_colors(nodes_orig),
            node_size = p.o_sz,
            edge_color = ec_orig,
            edge_width = ew_orig,
            nlabels = fill("", nv(g_orig)),
            arrow_show = false,
        )

        # ── Right: Reduced network (non-geographic layout) ──────────────────
        ax2 = Axis(
            fig[2, 2];
            title = "Reduced Network",
            titlesize = 16,
            xgridvisible = false,
            ygridvisible = false,
            backgroundcolor = :white,
        )
        GraphMakie.graphplot!(
            ax2,
            g_red;
            layout = GraphMakie.Stress(; seed = 42),
            node_color = _zone_colors(nodes_red),
            node_size = _red_node_sizes(nodes_red, p.r_sz, p.o_sz * 1.8f0),
            edge_color = ec_red,
            edge_width = [w * 1.5f0 for w in ew_red],
            nlabels = red_labels,
            nlabels_textsize = p.r_txt,
            nlabels_distance = 5,
            arrow_show = false,
        )
    end

    Legend(
        fig[3, 1:2],
        [
            PolyElement(color = :gray, strokecolor = :transparent),
            PolyElement(color = :red, strokecolor = :transparent),
            PolyElement(color = :royalblue, strokecolor = :transparent),
        ],
        ["AC Line", "AC Tie-Line", "DC Interconnector"];
        orientation = :horizontal,
        framevisible = false,
        labelsize = 14,
    )

    return fig
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
    p1 = plot_network(
        g_orig,
        nodes_orig,
        lines_orig;
        title = "Original Network",
        n_size = 0.1,
        f_size = 0,
        show_names = false,
    )
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
