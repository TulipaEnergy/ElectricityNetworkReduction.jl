# --- Data Loading and Cleaning Functions ---

"""
    load_excel_data(file_path::String)

Load network data from Excel file with multiple sheets.
Returns a dictionary containing DataFrames for lines, tielines, nodes, and generators.
"""
function load_excel_data(file_path::String)
    xf = XLSX.readxlsx(file_path)

    data = Dict(
        "lines" => DataFrame(XLSX.gettable(xf["Lines"])),
        "tielines" => DataFrame(XLSX.gettable(xf["Tielines"])),
        "nodes" => DataFrame(XLSX.gettable(xf["Nodes"])),
        "generators" => DataFrame(XLSX.gettable(xf["Generators"])),
    )

    if CONFIG.has_dc_lines
        sheet_name = CONFIG.dc_lines_sheet
        if sheet_name in XLSX.sheetnames(xf)
            data["dclines"] = DataFrame(XLSX.gettable(xf[sheet_name]))
            println(
                "DC lines loaded: $(nrow(data["dclines"])) entries from sheet '$(sheet_name)'.",
            )
        else
            @warn "CONFIG.has_dc_lines = true but sheet '$(sheet_name)' not found. " *
                  "Proceeding without DC lines."
            data["dclines"] = _empty_dclines_df()
        end
    else
        data["dclines"] = _empty_dclines_df()
    end

    if CONFIG.has_transformers
        sheet_name = CONFIG.transformers_sheet
        if sheet_name in XLSX.sheetnames(xf)
            data["transformers"] = DataFrame(XLSX.gettable(xf[sheet_name]))
            println(
                "Transformers loaded: $(nrow(data["transformers"])) entries from sheet '$(sheet_name)'.",
            )
        else
            @warn "CONFIG.has_transformers = true but sheet '$(sheet_name)' not found. " *
                  "Proceeding without transformers."
            data["transformers"] = _empty_transformers_df()
        end
    else
        data["transformers"] = _empty_transformers_df()
    end

    if CONFIG.has_converters
        sheet_name = CONFIG.converters_sheet
        if sheet_name in XLSX.sheetnames(xf)
            data["converters"] = DataFrame(XLSX.gettable(xf[sheet_name]))
            println(
                "Converters loaded: $(nrow(data["converters"])) entries from sheet '$(sheet_name)'.",
            )
        else
            @warn "CONFIG.has_converters = true but sheet '$(sheet_name)' not found. " *
                  "Proceeding without converters."
            data["converters"] = _empty_converters_df()
        end
    else
        data["converters"] = _empty_converters_df()
    end

    close(xf)
    return data
end

function _empty_dclines_df()
    return DataFrame(
        From_node = String[],
        To_node = String[],
        Capacity_MW = Float64[],
        EIC_Code = String[],
    )
end

function _empty_transformers_df()
    return DataFrame(
        From_node = String[],
        To_node = String[],
        X = Float64[],
        Capacity_MW = Float64[],
    )
end

function _empty_converters_df()
    return DataFrame(
        Converter_id = String[],
        From_node = String[],
        To_node = String[],
        Voltage_level = Float64[],
        Capacity_MW = Float64[],
    )
end

"""
    clean_line_data(lines_df::DataFrame)

Clean line data by removing self-loops and assigning fake EIC codes to missing entries.
"""
function clean_line_data(lines_df::DataFrame)
    lines_df[!, :IsTieLine] .= false
    lines_df[!, :IsDCLine] .= false
    clean_df = filter(row -> row.From_node != row.To_node, lines_df)

    missing_eic = findall(x -> ismissing(x) || x == "-", clean_df.EIC_Code)
    for (i, idx) in enumerate(missing_eic)
        clean_df[idx, :EIC_Code] = "Fake_$i"
    end
    return clean_df
end

"""
    process_tielines(tielines_df::DataFrame)

Process tie-lines by sorting, removing duplicates, and handling missing EIC codes.
"""
function process_tielines(tielines_df::DataFrame)
    tielines_df[!, :IsTieLine] .= true
    tielines_df[!, :IsDCLine] .= false
    sorted_tielines = sort(tielines_df, :Length_km, rev = true)

    # Assign fake EIC codes to missing/placeholder entries BEFORE de-duplicating
    # by EIC_Code. Otherwise multiple distinct tie-lines that all happen to have
    # a missing or "-" code look identical to `unique()` and collapse into one
    # branch, silently corrupting topology.
    missing_eic = findall(x -> ismissing(x) || x == "-", sorted_tielines.EIC_Code)
    for (i, idx) in enumerate(missing_eic)
        sorted_tielines[idx, :EIC_Code] = "Fake_Tie_$i"
    end

    unique_tielines = unique(sorted_tielines, :EIC_Code)
    filtered_tielines = filter(row -> row.From_node != row.To_node, unique_tielines)

    return filtered_tielines
end

"""
    convert_line_to_pu!(lines_df::DataFrame, Sbase::Float64; in_pu::Bool=false)

Convert line parameters to per-unit values based on system base power.
If `in_pu` is true, assumes R, X, B are already in per-unit and only converts capacity.
"""
function convert_line_to_pu!(
    lines_df::DataFrame,
    Sbase::Float64;
    in_pu::Bool = CONFIG.in_pu,
)
    if in_pu
        # Parameters already in per-unit, just rename columns
        lines_df[!, :R_pu] = lines_df.R
        lines_df[!, :X_pu] = lines_df.X
        lines_df[!, :B_pu] = lines_df.B
    else
        # Convert from ohms to per-unit
        lines_df[!, :R_pu] =
            [r / ((v^2) / Sbase) for (r, v) in zip(lines_df.R, lines_df.Voltage_level)]
        lines_df[!, :X_pu] =
            [x / ((v^2) / Sbase) for (x, v) in zip(lines_df.X, lines_df.Voltage_level)]
        lines_df[!, :B_pu] = [
            (b * 1e-6) * ((v^2) / Sbase) for
            (b, v) in zip(lines_df.B, lines_df.Voltage_level)
        ]
    end

    lines_df[!, :Capacity_pu] = lines_df.Capacity_MW ./ Sbase
    return lines_df
end
"""
    rename_buses(nodes_df, generators_df, lines_df, tie_lines_df, Sbase)

Rename buses, create numerical mapping, convert to per-unit,
and **preserve the IsRepresentative column** from Excel.
"""
function rename_buses(
    nodes_df::DataFrame,
    generators_df::DataFrame,
    lines_df::DataFrame,
    tie_lines_df::DataFrame,
    Sbase::Float64 = CONFIG.base,
    in_pu::Bool = CONFIG.in_pu,
    bus_as_int::Bool = CONFIG.bus_names_as_int,
)

    # ------------------------------------------------------------------
    # Bus name cleaning
    # ------------------------------------------------------------------
    if bus_as_int
        clean_bus_names = x -> string.(x)
    else
        clean_bus_names = x -> uppercase.(strip.(string.(x)))
    end

    transform!(nodes_df, :Bus => clean_bus_names => :Bus)
    transform!(generators_df, :Bus => clean_bus_names => :Bus)

    for df in [lines_df, tie_lines_df]
        if !isempty(df)
            df[!, :From_node] = clean_bus_names(df.From_node)
            df[!, :To_node] = clean_bus_names(df.To_node)
        end
    end

    lines_df = convert_line_to_pu!(lines_df, Sbase; in_pu = in_pu)
    tie_lines_df = convert_line_to_pu!(tie_lines_df, Sbase; in_pu = in_pu)

    # ------------------------------------------------------------------
    # Build bus map
    # ------------------------------------------------------------------
    bus_map =
        Dict{String,Int}(bus_name => idx for (idx, bus_name) in enumerate(nodes_df.Bus))

    # ------------------------------------------------------------------
    # Create node_data with IsRepresentative preserved
    # ------------------------------------------------------------------
    node_data = DataFrame(
        old_name = String[],
        new_id = Int[],
        PD_pu = Float64[],
        QD_pu = Float64[],
        GS_pu = Float64[],
        BS_pu = Float64[],
        Vm_pu = Float64[],
        Va_rad = Float64[],
        baseKV = Float64[],
        bus_type = Int[],
        Area = String[],
        Zone = String[],
        is_representative = Bool[],         # internal flag (used by the model)
        IsRepresentative = Bool[],          # preserved from Excel
        Latitude = Float64[],
        Longitude = Float64[],
    )

    function power_to_pu(value)
        ismissing(value) ? 0.0 : Float64(value) / Sbase
    end

    function convert_to_string(value)
        ismissing(value) ? "" : string(value)
    end

    for (idx, bus_row) in enumerate(eachrow(nodes_df))
        bus_name = bus_row.Bus

        # --- Parse IsRepresentative from Excel ---
        is_rep_excel = false
        if hasproperty(bus_row, :IsRepresentative) && !ismissing(bus_row.IsRepresentative)
            v = bus_row.IsRepresentative
            is_rep_excel =
                (v === true || v == 1 || lowercase(string(v)) ∈ ("yes", "y", "true", "1"))
        end

        # --- Latitude / Longitude protection ---
        lat_val =
            hasproperty(bus_row, :Latitude) && !ismissing(bus_row.Latitude) ?
            Float64(bus_row.Latitude) : 0.0
        lon_val =
            hasproperty(bus_row, :Longitude) && !ismissing(bus_row.Longitude) ?
            Float64(bus_row.Longitude) : 0.0

        new_row = (
            old_name = bus_name,
            new_id = idx,
            PD_pu = power_to_pu(bus_row.PD),
            QD_pu = power_to_pu(bus_row.QD),
            # GS/BS follow the same `in_pu` convention as line R/X/B: when
            # in_pu=false they are physical shunt MW/MVAr at V=1.0pu (the
            # MATPOWER convention) and must be divided by Sbase; when
            # in_pu=true they are already per-unit.
            GS_pu = ismissing(bus_row.GS) ? 0.0 :
                    (in_pu ? Float64(bus_row.GS) : Float64(bus_row.GS) / Sbase),
            BS_pu = ismissing(bus_row.BS) ? 0.0 :
                    (in_pu ? Float64(bus_row.BS) : Float64(bus_row.BS) / Sbase),
            Vm_pu = ismissing(bus_row.Vm) ? 1.0 : Float64(bus_row.Vm),
            Va_rad = ismissing(bus_row.Va) ? 0.0 : deg2rad(Float64(bus_row.Va)),
            baseKV = ismissing(bus_row.baseKV) ? 0.0 : Float64(bus_row.baseKV),
            bus_type = ismissing(bus_row.Type) ? 1 : Int(bus_row.Type),
            Area = convert_to_string(bus_row.Area),
            Zone = convert_to_string(bus_row.Zone),
            is_representative = false,           # will be set later by selection function
            IsRepresentative = is_rep_excel,    # preserved from Excel
            Latitude = lat_val,
            Longitude = lon_val,
        )

        push!(node_data, new_row; promote = true)
    end

    # ------------------------------------------------------------------
    # Map From/To to new numerical IDs
    # ------------------------------------------------------------------
    for df in [lines_df, tie_lines_df]
        if !isempty(df)
            df[!, :From] = [bus_map[name] for name in df.From_node]
            df[!, :To] = [bus_map[name] for name in df.To_node]
        end
    end

    return lines_df, tie_lines_df, node_data
end

"""
    process_dclines(dclines_df::DataFrame, Sbase::Float64)

Process DC interconnector lines.

DC lines have no AC impedance parameters (R, X, B are set to zero and must
NEVER be passed to form_ybus_with_shunt or any PTDF calculation).
Their capacity contributes additively to inter-zonal TTC after AC reduction.

Required columns in the DCLines Excel sheet:
    From_node    – sending-end bus name (must exist in Nodes sheet)
    To_node      – receiving-end bus name (must exist in Nodes sheet)
    Capacity_MW  – rated capacity in MW (symmetric; same limit both directions)
    EIC_Code     – identifier (optional)
"""
function process_dclines(dclines_df::DataFrame, Sbase::Float64)
    if isempty(dclines_df)
        return dclines_df
    end

    dclines_df[!, :IsDCLine] .= true
    dclines_df[!, :IsTieLine] .= false

    # Explicitly zero AC parameters — safety guard
    dclines_df[!, :R_pu] .= 0.0
    dclines_df[!, :X_pu] .= 0.0
    dclines_df[!, :B_pu] .= 0.0

    # Capacity to per-unit
    dclines_df[!, :Capacity_pu] = dclines_df.Capacity_MW ./ Sbase

    # Handle missing EIC codes
    if hasproperty(dclines_df, :EIC_Code)
        missing_eic = findall(x -> ismissing(x) || x == "-", dclines_df.EIC_Code)
        for (i, idx) in enumerate(missing_eic)
            dclines_df[idx, :EIC_Code] = "Fake_DC_$i"
        end
    else
        dclines_df[!, :EIC_Code] = ["DC_$i" for i = 1:nrow(dclines_df)]
    end

    # Remove self-loops
    filter!(row -> row.From_node != row.To_node, dclines_df)

    total_cap = round(sum(dclines_df.Capacity_MW); digits = 1)
    println(
        "DC lines processed: $(nrow(dclines_df)) interconnectors, " *
        "total capacity = $(total_cap) MW.",
    )
    return dclines_df
end

"""
    rename_dc_buses(dclines_df, bus_map)

Map DC line From_node/To_node names to numerical IDs using the bus_map
produced by rename_buses. Validates that all DC bus names exist in the
Nodes sheet and raises a descriptive error if any are missing.
"""
function rename_dc_buses(
    dclines_df::DataFrame,
    bus_map::Dict{String,Int},
    bus_as_int::Bool = CONFIG.bus_names_as_int,
)
    if isempty(dclines_df)
        dclines_df[!, :From] = Int[]
        dclines_df[!, :To] = Int[]
        return dclines_df
    end

    clean = bus_as_int ? x -> string.(x) : x -> uppercase.(strip.(string.(x)))

    dclines_df[!, :From_node] = clean(dclines_df.From_node)
    dclines_df[!, :To_node] = clean(dclines_df.To_node)

    for row in eachrow(dclines_df)
        haskey(bus_map, row.From_node) ||
            error("DC line From_node '$(row.From_node)' not found in Nodes sheet.")
        haskey(bus_map, row.To_node) ||
            error("DC line To_node '$(row.To_node)' not found in Nodes sheet.")
    end

    dclines_df[!, :From] = [bus_map[n] for n in dclines_df.From_node]
    dclines_df[!, :To] = [bus_map[n] for n in dclines_df.To_node]
    return dclines_df
end

"""
    build_dc_capacity_map(dclines_df, node_info, rep_node_ids; lines_df, tielines_df)

Build a Dict mapping representative-node pairs to aggregated DC capacity (pu).

Physical DC converter buses are remapped to a representative node in the same
AC connected component whenever AC line data are provided. Intra-zone DC lines
are skipped only when both endpoints are in the same AC component; intra-zone
DC bridges between separate AC islands are kept. Multiple DC lines between the
same representative-node pair are summed. This map is later used for additive
TTC contribution and as a floor constraint in optimisation.

# Returns
Dict{Tuple{Int,Int}, Float64}  keyed by (min_rep_id, max_rep_id)
"""
function build_dc_capacity_map(
    dclines_df::DataFrame,
    node_info::DataFrame,
    rep_node_ids::Vector{Int};
    lines_df::Union{Nothing,DataFrame} = nothing,
    tielines_df::Union{Nothing,DataFrame} = nothing,
)
    if isempty(dclines_df)
        return Dict{Tuple{Int,Int},Float64}()
    end

    id_to_zone = Dict(Int(row.new_id) => string(row.Zone) for row in eachrow(node_info))
    rep_id_set = Set(rep_node_ids)

    use_components = !(isnothing(lines_df) && isnothing(tielines_df))
    node_component =
        use_components ?
        _ac_component_labels(
            isnothing(lines_df) ? DataFrame() : lines_df,
            isnothing(tielines_df) ? DataFrame() : tielines_df,
            node_info,
        ) : zeros(Int, nrow(node_info))

    # Backward-compatible fallback for callers that do not provide AC topology.
    zone_to_rep = Dict{String,Int}()
    for rid in rep_node_ids
        z = id_to_zone[rid]
        haskey(zone_to_rep, z) || (zone_to_rep[z] = rid)
    end

    comp_zone_to_rep = Dict{Tuple{Int,String},Int}()
    comp_to_rep = Dict{Int,Int}()
    if use_components
        for rid in rep_node_ids
            comp = node_component[rid]
            z = id_to_zone[rid]
            haskey(comp_zone_to_rep, (comp, z)) || (comp_zone_to_rep[(comp, z)] = rid)
            haskey(comp_to_rep, comp) || (comp_to_rep[comp] = rid)
        end
    end

    dc_cap = Dict{Tuple{Int,Int},Float64}()
    skipped = 0

    for row in eachrow(dclines_df)
        zf = get(id_to_zone, row.From, nothing)
        zt = get(id_to_zone, row.To, nothing)

        if isnothing(zf) || isnothing(zt)
            @warn "DC line $(row.From)→$(row.To): unknown zone. Skipping."
            skipped += 1
            continue
        end

        if use_components
            cf = node_component[Int(row.From)]
            ct = node_component[Int(row.To)]

            if zf == zt && cf == ct
                @debug "DC line $(row.From)→$(row.To) is intra-zone and intra-component ($(zf)). Skipping."
                skipped += 1
                continue
            end

            rf = _dc_endpoint_representative(
                Int(row.From),
                zf,
                cf,
                rep_id_set,
                comp_zone_to_rep,
                comp_to_rep,
            )
            rt = _dc_endpoint_representative(
                Int(row.To),
                zt,
                ct,
                rep_id_set,
                comp_zone_to_rep,
                comp_to_rep,
            )

            if isnothing(rf) || isnothing(rt)
                @warn "AC component for DC line $(row.From)→$(row.To) has no " *
                      "representative node. Skipping."
                skipped += 1
                continue
            end
        elseif zf == zt
            @debug "DC line $(row.From)→$(row.To) is intra-zone ($(zf)). Skipping."
            skipped += 1
            continue
        else
            rf = get(zone_to_rep, zf, nothing)
            rt = get(zone_to_rep, zt, nothing)

            if isnothing(rf) || isnothing(rt)
                @warn "Zone '$(zf)' or '$(zt)' has no representative node. " *
                      "DC line $(row.From)→$(row.To) skipped."
                skipped += 1
                continue
            end
        end

        if rf == rt
            @debug "DC line $(row.From)→$(row.To) maps to representative self-loop $(rf). Skipping."
            skipped += 1
            continue
        end

        key = (min(rf, rt), max(rf, rt))
        dc_cap[key] = get(dc_cap, key, 0.0) + row.Capacity_pu
    end

    println(
        "DC capacity map: $(length(dc_cap)) representative-node pairs" *
        (skipped > 0 ? ", $(skipped) lines skipped." : "."),
    )
    for (k, v) in sort(collect(dc_cap))
        println("  Nodes $(k[1])↔$(k[2]) : $(round(v * CONFIG.base; digits=1)) MW")
    end

    return dc_cap
end

function _ac_component_labels(
    lines_df::DataFrame,
    tielines_df::DataFrame,
    node_info::DataFrame,
)
    n = nrow(node_info)
    g_ac = SimpleGraph(n)
    for row in eachrow(vcat(lines_df, tielines_df, cols = :union))
        if hasproperty(row, :From) && hasproperty(row, :To)
            u, v = Int(row.From), Int(row.To)
            if 1 <= u <= n && 1 <= v <= n
                add_edge!(g_ac, u, v)
            end
        end
    end

    node_component = zeros(Int, n)
    for (ci, comp) in enumerate(connected_components(g_ac))
        node_component[comp] .= ci
    end
    return node_component
end

function _dc_endpoint_representative(
    bus_id::Int,
    zone::String,
    component::Int,
    rep_id_set::Set{Int},
    comp_zone_to_rep::Dict{Tuple{Int,String},Int},
    comp_to_rep::Dict{Int,Int},
)
    bus_id in rep_id_set && return bus_id
    rep = get(comp_zone_to_rep, (component, zone), nothing)
    isnothing(rep) || return rep
    return get(comp_to_rep, component, nothing)
end

"""
    process_transformers(transformers_df::DataFrame)

Prepare transformer data for integration with the AC line pipeline.

Transformers are treated as AC elements: `IsTieLine = false`, `IsDCLine = false`.
The sheet must use the same column names as the Lines sheet for From_node, To_node,
X, and Capacity_MW. R and B columns are optional and default to 0 when absent.

Missing EIC codes are assigned synthetic identifiers.
"""
function process_transformers(transformers_df::DataFrame)
    if isempty(transformers_df)
        return transformers_df
    end

    transformers_df[!, :IsTieLine] .= false
    transformers_df[!, :IsDCLine] .= false

    # Add missing optional columns with safe defaults
    !hasproperty(transformers_df, :R) &&
        (transformers_df[!, :R] = zeros(nrow(transformers_df)))
    !hasproperty(transformers_df, :B) &&
        (transformers_df[!, :B] = zeros(nrow(transformers_df)))

    # Replace any missing values in R and B with 0
    transformers_df[!, :R] = coalesce.(transformers_df.R, 0.0)
    transformers_df[!, :B] = coalesce.(transformers_df.B, 0.0)

    # Remove self-loops
    clean_df = filter(row -> row.From_node != row.To_node, transformers_df)

    # Assign EIC codes
    if hasproperty(clean_df, :EIC_Code)
        missing_eic = findall(x -> ismissing(x) || x == "-", clean_df.EIC_Code)
        for (i, idx) in enumerate(missing_eic)
            clean_df[idx, :EIC_Code] = "Fake_Transformer_$i"
        end
    else
        clean_df[!, :EIC_Code] = ["Transformer_$i" for i = 1:nrow(clean_df)]
    end

    println("Transformers processed: $(nrow(clean_df)) entries.")
    return clean_df
end

"""
    process_converters(converters_df::DataFrame)

Clean and standardise the Converters sheet.

Each row represents one AC/DC interface:
  From_node — DC terminal bus name (bare OSM ID, e.g. way/920127890)
  To_node   — AC substation bus name (voltage-suffixed, e.g. way/920127890-380)

The same name-cleaning rules (uppercase + strip) used everywhere else are
applied so that converter map keys match the names produced by rename_buses
and rename_dc_buses.
"""
function process_converters(converters_df::DataFrame)
    if isempty(converters_df)
        return converters_df
    end

    clean = CONFIG.bus_names_as_int ? x -> string.(x) : x -> uppercase.(strip.(string.(x)))
    converters_df[!, :From_node] = clean(converters_df.From_node)
    converters_df[!, :To_node] = clean(converters_df.To_node)

    filter!(row -> row.From_node != row.To_node, converters_df)

    n_synthetic = count(
        row -> occursin("synthetic", lowercase(string(row.Converter_id))),
        eachrow(converters_df),
    )
    println(
        "Converters processed: $(nrow(converters_df)) AC/DC interface entries" *
        (n_synthetic > 0 ? " ($(n_synthetic) synthetic)." : "."),
    )
    return converters_df
end

"""
    build_converter_map(converters_df::DataFrame) -> Dict{String,String}

Return a Dict mapping each DC terminal bus name to its connected AC substation
bus name.  Used by remap_dc_endpoints! to rewrite DCLine endpoints before
numeric ID assignment.
"""
function build_converter_map(converters_df::DataFrame)::Dict{String,String}
    isempty(converters_df) && return Dict{String,String}()
    return Dict{String,String}(
        row.From_node => row.To_node for row in eachrow(converters_df)
    )
end

"""
    remap_dc_endpoints!(dclines_df, converter_map)

Replace DC terminal bus names in DCLines with their connected AC substation
bus names, using the map built from the Converters sheet.

DC cables physically connect between converter-station DC terminals.  For
PTDF/TTC analysis the relevant injection point is the AC bus adjacent to the
converter, not the DC terminal itself.  After remapping, every DC line
endpoint refers to an AC bus that exists in the Y-bus, eliminating DC-terminal
singleton islands and ensuring correct zone attribution in build_dc_capacity_map.

Endpoints with no converter entry are left unchanged; rename_dc_buses will
validate them and raise a descriptive error if they are also absent from the
Nodes sheet.
"""
function remap_dc_endpoints!(dclines_df::DataFrame, converter_map::Dict{String,String})
    if isempty(dclines_df) || isempty(converter_map)
        return dclines_df
    end

    # Apply the same name cleaning used by process_converters so that raw
    # Excel strings (lowercase, with spaces) match the uppercase map keys.
    # Cleaned names are written back even when no remapping occurs so that
    # rename_dc_buses sees consistent strings throughout.
    clean = CONFIG.bus_names_as_int ? s -> string(s) : s -> uppercase(strip(string(s)))

    n_remapped = 0
    n_unchanged = 0

    for i = 1:nrow(dclines_df)
        fn = clean(dclines_df[i, :From_node])
        tn = clean(dclines_df[i, :To_node])

        if haskey(converter_map, fn)
            dclines_df[i, :From_node] = converter_map[fn]
            n_remapped += 1
        else
            dclines_df[i, :From_node] = fn   # write back cleaned name
            n_unchanged += 1
        end

        if haskey(converter_map, tn)
            dclines_df[i, :To_node] = converter_map[tn]
            n_remapped += 1
        else
            dclines_df[i, :To_node] = tn     # write back cleaned name
            n_unchanged += 1
        end
    end

    println(
        "DC endpoint remapping: $(n_remapped)/$(2 * nrow(dclines_df)) endpoints " *
        "remapped to AC buses" *
        (n_unchanged > 0 ? ", $(n_unchanged) left unchanged (no converter entry)." : "."),
    )
    return dclines_df
end
