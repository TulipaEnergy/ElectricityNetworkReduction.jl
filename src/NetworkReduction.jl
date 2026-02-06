module NetworkReduction

using XLSX
using DataFrames
using SparseArrays
using LinearAlgebra
using CSV
using Statistics
using JuMP
using MathOptInterface
using Revise
using HiGHS
using Ipopt

export load_excel_data,
    clean_line_data,
    process_tielines,
    convert_line_to_pu!,
    rename_buses,
    form_ybus_with_shunt,
    calculate_ptdfs_dc_power_flow,
    calculate_all_ptdfs_original,
    calculate_ptdfs_reduced,
    calculate_ttc_from_ptdfs,
    calculate_ttc_equivalent,
    select_representative_nodes,
    kron_reduce_ybus,
    optimize_equivalent_capacities,
    debug_optimization_data,
    export_bus_id_map,
    export_detailed_line_info,
    main_full_analysis,
    config,
    CONFIG,
    reset_config!

#Configuration fie
include("config.jl")

# Data loading and cleaning
include("data-loading.jl")

# Network matrix formation
include("ybus-formation.jl")

# Power Transfer Distribution Factor calculations
include("ptdf-calculations.jl")

# Total Transfer Capacity calculations
include("ttc-calculations.jl")

# Representative node selection
include("representative-nodes.jl")

# Kron reduction
include("kron-reduction.jl")

# Optimization functions
include("optimization.jl")

# Export utilities
include("export-functions.jl")

# Main analysis workflow
include("main-analysis.jl")

end
