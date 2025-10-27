# --- EXPORT FUNCTIONS ---

"""
    export_bus_id_map(node_info, export_path)

Export a CSV file containing the mapping between old bus names and new numerical IDs.

# Arguments
- `node_info::DataFrames.DataFrame`: Node information with old_name and new_id columns
- `export_path::String`: Path where the CSV file will be saved

# Output CSV Format
- old_name: Original bus names from input data
- new_id: Numerical IDs assigned during processing
"""
function export_bus_id_map(node_info::DataFrames.DataFrame, export_path::String)
    bus_map_df = DataFrames.select(node_info, :old_name, :new_id)
    CSV.write(export_path, bus_map_df)
    println("Bus ID map exported to CSV: $export_path")
end

"""
    export_detailed_line_info(lines_df, tielines_df, export_path)

Export comprehensive line information including both original names and numerical IDs.

# Arguments
- `lines_df::DataFrames.DataFrame`: Regular transmission lines data
- `tielines_df::DataFrames.DataFrame`: Tie lines data
- `export_path::String`: Path where the CSV file will be saved

# Output CSV Columns
- EIC_Code: European Identification Code for the line
- From_node, To_node: Original bus names
- New_ID_From, New_ID_To: Numerical bus IDs
- Voltage_level: Operating voltage level
- Length_km: Line length in kilometers
- Capacity_MW, Capacity_pu: Line capacity in MW and per-unit
- R_pu, X_pu, B_pu: Line parameters in per-unit
- IsTieLine: Boolean flag indicating if this is a tie line
"""
function export_detailed_line_info(
    lines_df::DataFrames.DataFrame,
    tielines_df::DataFrames.DataFrame,
    export_path::String,
)
    # Combine regular and tie lines
    all_lines = DataFrames.vcat(lines_df, tielines_df, cols = :union)

    # Select and reorder the most relevant columns for line tracking
    line_info_df = all_lines[
        !,
        [
            :EIC_Code,
            :From_node,
            :To_node, # Old Bus Names
            :From,
            :To,           # New Bus IDs
            :Voltage_level,
            :Length_km,
            :Capacity_MW,
            :Capacity_pu,
            :R_pu,
            :X_pu,
            :B_pu,
            :IsTieLine,
        ],
    ]

    # Rename new ID columns for clarity in the export
    DataFrames.rename!(line_info_df, :From => :New_ID_From, :To => :New_ID_To)

    CSV.write(export_path, line_info_df)
    println("Detailed line information exported to CSV: $export_path")
end
