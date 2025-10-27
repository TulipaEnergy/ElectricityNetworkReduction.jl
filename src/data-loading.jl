# --- Data Loading and Cleaning Functions ---

"""
    load_excel_data(file_path::String)

Load network data from Excel file with multiple sheets.
Returns a dictionary containing DataFrames for lines, tielines, nodes, and generators.
"""
function load_excel_data(file_path::String)
    xf = XLSX.readxlsx(file_path)
    data = Dict(
        "lines" => DataFrames.DataFrame(XLSX.gettable(xf["Lines"])),
        "tielines" => DataFrames.DataFrame(XLSX.gettable(xf["Tielines"])),
        "nodes" => DataFrames.DataFrame(XLSX.gettable(xf["Nodes"])),
        "generators" => DataFrames.DataFrame(XLSX.gettable(xf["Generators"])),
    )
    close(xf)
    return data
end

"""
    clean_line_data(lines_df::DataFrames.DataFrame)

Clean line data by removing self-loops and assigning fake EIC codes to missing entries.
"""
function clean_line_data(lines_df::DataFrames.DataFrame)
    lines_df[!, :IsTieLine] .= false
    clean_df = DataFrames.filter(row -> row.From_node != row.To_node, lines_df)

    missing_eic = findall(x -> ismissing(x) || x == "-", clean_df.EIC_Code)
    for (i, idx) in enumerate(missing_eic)
        clean_df[idx, :EIC_Code] = "Fake_$i"
    end
    return clean_df
end

"""
    process_tielines(tielines_df::DataFrames.DataFrame)

Process tie-lines by sorting, removing duplicates, and handling missing EIC codes.
"""
function process_tielines(tielines_df::DataFrames.DataFrame)
    tielines_df[!, :IsTieLine] .= true
    sorted_tielines = DataFrames.sort(tielines_df, :Length_km, rev = true)
    unique_tielines = DataFrames.unique(sorted_tielines, :EIC_Code)
    filtered_tielines =
        DataFrames.filter(row -> row.From_node != row.To_node, unique_tielines)

    missing_eic = findall(x -> ismissing(x) || x == "-", filtered_tielines.EIC_Code)
    for (i, idx) in enumerate(missing_eic)
        filtered_tielines[idx, :EIC_Code] = "Fake_Tie_$i"
    end

    return filtered_tielines
end

"""
    convert_line_to_pu!(lines_df::DataFrames.DataFrame, Sbase::Float64)

Convert line parameters to per-unit values based on system base power.
"""
function convert_line_to_pu!(lines_df::DataFrames.DataFrame, Sbase::Float64)
    lines_df[!, :R_pu] =
        [r / ((v^2) / Sbase) for (r, v) in zip(lines_df.R, lines_df.Voltage_level)]
    lines_df[!, :X_pu] =
        [x / ((v^2) / Sbase) for (x, v) in zip(lines_df.X, lines_df.Voltage_level)]
    lines_df[!, :B_pu] =
        [(b * 1e-6) * ((v^2) / Sbase) for (b, v) in zip(lines_df.B, lines_df.Voltage_level)]
    lines_df[!, :Capacity_pu] = lines_df.Capacity_MW ./ Sbase

    return lines_df
end

"""
    rename_buses(nodes_df, generators_df, lines_df, tie_lines_df, Sbase)

Rename buses to uppercase, create numerical mapping, and convert data to per-unit.
Returns processed line DataFrames and node information.
"""
function rename_buses(
    nodes_df::DataFrames.DataFrame,
    generators_df::DataFrames.DataFrame,
    lines_df::DataFrames.DataFrame,
    tie_lines_df::DataFrames.DataFrame,
    Sbase::Float64,
)

    DataFrames.transform!(nodes_df, :Bus => (x -> uppercase.(strip.(x)) => :Bus))
    DataFrames.transform!(generators_df, :Bus => (x -> uppercase.(strip.(x)) => :Bus))
    DataFrames.transform!(lines_df, [:From_node, :To_node] .=> (x -> uppercase.(strip.(x))))
    DataFrames.transform!(
        tie_lines_df,
        [:From_node, :To_node] .=> (x -> uppercase.(strip.(x))),
    )

    lines_df = convert_line_to_pu!(lines_df, Sbase)
    tie_lines_df = convert_line_to_pu!(tie_lines_df, Sbase)

    bus_map = Dict{String,Int}()
    for (idx, bus_name) in enumerate(nodes_df.Bus)
        bus_map[bus_name] = idx
    end

    node_data = DataFrames.DataFrame(
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

    for (idx, bus_row) in enumerate(DataFrames.eachrow(nodes_df))
        bus_name = bus_row.Bus

        bus_node = DataFrames.filter(:Bus => x -> x == bus_name, nodes_df)
        isempty(bus_node) && error("Bus $bus_name not found in nodes DataFrame")

        push!(
            node_data,
            (
                bus_name,
                idx,
                power_to_pu(bus_node.PD[1]),
                power_to_pu(bus_node.QD[1]),
                bus_node.GS[1],
                bus_node.BS[1],
                bus_node.Vm[1],
                LinearAlgebra.deg2rad(bus_node.Va[1]),
                bus_node.baseKV[1],
                bus_node.Type[1],
                bus_node.Area[1],
                bus_node.Zone[1],
                false, # This will be set later in main
            ),
        )
    end

    for df in [lines_df, tie_lines_df]
        df[!, :From] = [bus_map[name] for name in df.From_node]
        df[!, :To] = [bus_map[name] for name in df.To_node]
    end

    return lines_df, tie_lines_df, node_data
end
