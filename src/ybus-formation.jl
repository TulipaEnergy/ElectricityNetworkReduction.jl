# --- Y-Bus Formation Function ---

"""
    form_dc_ybus(lines_df, tie_lines_df, node_info, Sbase)

Build the lossless DC Laplacian from series reactances only. The complex
wrapper `-im * Bdc` preserves the existing matrix API; it is not an AC Ybus.
Resistance, charging, and reactive bus shunts do not enter active-power PTDFs.
Input branches currently represent unity-tap series elements.
"""
function form_dc_ybus(lines_df, tie_lines_df, node_info, Sbase)
    Bdc = spzeros(Float64, nrow(node_info), nrow(node_info))
    for line in eachrow(vcat(lines_df, tie_lines_df, cols = :union))
        x = Float64(line.X_pu)
        isfinite(x) && x > 0 ||
            throw(ArgumentError("DC branches require positive finite X_pu; got $x"))
        i, j = Int(line.From), Int(line.To)
        i == j && continue
        b = 1.0 / x
        Bdc[i, i] += b
        Bdc[j, j] += b
        Bdc[i, j] -= b
        Bdc[j, i] -= b
    end
    return sparse(-im * Bdc)
end

"""
    form_ybus_with_shunt(lines_df, tie_lines_df, node_info, Sbase)

Form the network admittance matrix (Y-bus) including shunt elements.
Returns a sparse complex matrix representing the network admittance.
"""
function form_ybus_with_shunt(
    lines_df::DataFrame,
    tie_lines_df::DataFrame,
    node_info::DataFrame,
    Sbase::Float64,
)
    n_buses = nrow(node_info)
    Ybus = spzeros(ComplexF64, n_buses, n_buses)

    all_lines = vcat(lines_df, tie_lines_df, cols = :union)

    for line in eachrow(all_lines)
        i = line.From
        j = line.To

        R_pu = line.R_pu
        X_pu = line.X_pu
        B_shunt_pu = line.B_pu

        z_series = complex(R_pu, X_pu)
        y_series = 1 / z_series
        y_shunt = im * B_shunt_pu / 2

        Ybus[i, i] += y_series + y_shunt
        Ybus[j, j] += y_series + y_shunt
        Ybus[i, j] -= y_series
        Ybus[j, i] -= y_series
    end

    for (bus_idx, bus_row) in enumerate(eachrow(node_info))
        Ybus[bus_idx, bus_idx] += complex(bus_row.GS_pu, bus_row.BS_pu)
    end

    return Ybus
end
