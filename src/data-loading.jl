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
    close(xf)
    return data
end

"""
    clean_line_data(lines_df::DataFrame)

Clean line data by removing self-loops and assigning fake EIC codes to missing entries.
"""
function clean_line_data(lines_df::DataFrame)
    lines_df[!, :IsTieLine] .= false
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
    sorted_tielines = sort(tielines_df, :Length_km, rev = true)
    unique_tielines = unique(sorted_tielines, :EIC_Code)
    filtered_tielines = filter(row -> row.From_node != row.To_node, unique_tielines)

    missing_eic = findall(x -> ismissing(x) || x == "-", filtered_tielines.EIC_Code)
    for (i, idx) in enumerate(missing_eic)
        filtered_tielines[idx, :EIC_Code] = "Fake_Tie_$i"
    end

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

Rename buses to uppercase, create numerical mapping, and convert data to per-unit.
Returns processed line DataFrames and node information.
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

    # Define how to handle bus identifiers based on the config
    if bus_as_int
        # Just convert to string for consistent mapping
        clean_bus_names = x -> string.(x)
    else
        # Standard cleaning for string names
        clean_bus_names = x -> uppercase.(strip.(string.(x)))
    end

    # Original string handling (uppercase conversion)
    transform!(nodes_df, :Bus => clean_bus_names => :Bus)
    transform!(generators_df, :Bus => clean_bus_names => :Bus)
    transform!(lines_df, [:From_node, :To_node] .=> (x -> uppercase.(strip.(string.(x)))))
    transform!(
        tie_lines_df,
        [:From_node, :To_node] .=> (x -> uppercase.(strip.(string.(x)))),
    )

    # For lines and tielines, we apply it to both From and To columns
    for df in [lines_df, tie_lines_df]
        if !isempty(df)
            df[!, :From_node] = clean_bus_names(df.From_node)
            df[!, :To_node] = clean_bus_names(df.To_node)
        end
    end

    lines_df = convert_line_to_pu!(lines_df, Sbase, in_pu = in_pu)
    tie_lines_df = convert_line_to_pu!(tie_lines_df, Sbase, in_pu = in_pu)

    bus_map = Dict{String,Int}()
    for (idx, bus_name) in enumerate(nodes_df.Bus)
        bus_map[bus_name] = idx
    end

    # Helper function to consistently convert Area and Zone to String
    function convert_to_string(value)
        if ismissing(value)
            return ""
        else
            return string(value)  # Convert integers, floats, etc. to string
        end
    end

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
        is_representative = Bool[],
    )

    function power_to_pu(value)
        ismissing(value) ? 0.0 : value / Sbase
    end

    for (idx, bus_row) in enumerate(eachrow(nodes_df))
        bus_name = bus_row.Bus

        # Handle Area and Zone conversion
        area_value = bus_row.Area
        zone_value = bus_row.Zone

        area_str = convert_to_string(area_value)
        zone_str = convert_to_string(zone_value)

        bus_node = filter(:Bus => x -> x == bus_name, nodes_df)
        isempty(bus_node) && error("Bus $bus_name not found in nodes DataFrame")

        # Create a NamedTuple with all values
        new_row = (
            old_name = bus_name,
            new_id = idx,
            PD_pu = power_to_pu(bus_row.PD),
            QD_pu = power_to_pu(bus_row.QD),
            GS_pu = ismissing(bus_row.GS) ? 0.0 : Float64(bus_row.GS),
            BS_pu = ismissing(bus_row.BS) ? 0.0 : Float64(bus_row.BS),
            Vm_pu = ismissing(bus_row.Vm) ? 1.0 : Float64(bus_row.Vm),
            Va_rad = ismissing(bus_row.Va) ? 0.0 : deg2rad(Float64(bus_row.Va)),
            baseKV = ismissing(bus_row.baseKV) ? 0.0 : Float64(bus_row.baseKV),
            bus_type = ismissing(bus_row.Type) ? 1 : Int(bus_row.Type),
            Area = area_str,
            Zone = zone_str,
            is_representative = false,
        )

        # Use push! with promote=true to handle type conversions automatically
        push!(node_data, new_row, promote = true)
    end

    for df in [lines_df, tie_lines_df]
        df[!, :From] = [bus_map[name] for name in df.From_node]
        df[!, :To] = [bus_map[name] for name in df.To_node]
    end

    return lines_df, tie_lines_df, node_data
end
