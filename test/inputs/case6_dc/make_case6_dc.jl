# Generates case6_dc.xlsx: case6 extended with the optional sheets so the batch
# test covers DC lines, converters and transformers.
#
#   - Buses 7–8 (zone 4) form a second AC island, reachable only over DC.
#   - Two parallel DC cables between terminals 1001 (→ AC bus 3) and
#     1002 (→ AC bus 7), 100 MW each. The converters are rated 150 MW and
#     120 MW, so the pair's DC capacity is capped at 120 MW by the shared
#     converter at 1002.
#   - Bus 9 (zone 3) is connected to buses 5 and 6 by transformers.
#
# Run from the repository root:  julia --project=. test/inputs/case6_dc/make_case6_dc.jl
using XLSX, DataFrames

src = joinpath(@__DIR__, "..", "case6", "case6.xlsx")
xf = XLSX.readxlsx(src)
sheet(name) = DataFrame(XLSX.gettable(xf[name]))

nodes = sheet("Nodes")
for (bus, zone) in ((7, 4), (8, 4), (9, 3))
    push!(nodes, merge(copy(nodes[end, :]), (Bus = bus, Zone = zone)))
end

lines = sheet("Lines")
push!(
    lines,
    merge(
        copy(lines[end, :]),
        (From_node = 7, To_node = 8, R = 0.02, X = 0.1, B = 0.02, Capacity_MW = 100),
    ),
)

transformers = DataFrame(
    Transformer_id = ["T1", "T2"],
    From_node = [6, 5],
    To_node = [9, 9],
    X = [0.05, 0.08],
    Capacity_MW = [150, 100],
)
dclines = DataFrame(
    Line_name = ["DC1", "DC2"],
    EIC_Code = ["DC1", "DC2"],
    From_node = [1001, 1001],
    To_node = [1002, 1002],
    Capacity_MW = [100, 100],
)
converters = DataFrame(
    Converter_id = ["C1", "C2"],
    From_node = [1001, 1002],
    To_node = [3, 7],
    Voltage_level = [230, 230],
    Capacity_MW = [150, 120],
)

XLSX.writetable(
    joinpath(@__DIR__, "case6_dc.xlsx"),
    "Lines" => lines,
    "Tielines" => sheet("Tielines"),
    "Nodes" => nodes,
    "Generators" => sheet("Generators"),
    "DCLines" => dclines,
    "Transformers" => transformers,
    "Converters" => converters;
    overwrite = true,
)
