# --- Y-Bus Formation Function ---

"""
    form_ybus_with_shunt(lines_df, tie_lines_df, node_info, Sbase)

Form the network admittance matrix (Y-bus) including shunt elements.
Returns a sparse complex matrix representing the network admittance.
"""
function form_ybus_with_shunt(
    lines_df::DataFrames.DataFrame,
    tie_lines_df::DataFrames.DataFrame,
    node_info::DataFrames.DataFrame,
    Sbase::Float64,
)
    n_buses = DataFrames.nrow(node_info)
    Ybus = SparseArrays.spzeros(ComplexF64, n_buses, n_buses)

    all_lines = DataFrames.vcat(lines_df, tie_lines_df, cols = :union)

    for line in DataFrames.eachrow(all_lines)
        i = line.From
        j = line.To

        R_pu = line.R_pu
        X_pu = line.X_pu
        B_shunt_pu = line.B_pu

        z_series = LinearAlgebra.complex(R_pu, X_pu)
        y_series = 1 / z_series
        y_shunt = im * B_shunt_pu / 2

        Ybus[i, i] += y_series + y_shunt
        Ybus[j, j] += y_series + y_shunt
        Ybus[i, j] -= y_series
        Ybus[j, i] -= y_series
    end

    for (bus_idx, bus_row) in enumerate(DataFrames.eachrow(node_info))
        Ybus[bus_idx, bus_idx] += LinearAlgebra.complex(bus_row.GS_pu, bus_row.BS_pu)
    end

    return Ybus
end
