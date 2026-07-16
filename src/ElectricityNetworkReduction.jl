module ElectricityNetworkReduction

using XLSX
using DataFrames
using SparseArrays
using LinearAlgebra
using CSV
using Statistics
using JuMP
using MathOptInterface
using HiGHS
using Ipopt
using Graphs
using GraphRecipes
using Plots
using CairoMakie
using GraphMakie

export load_excel_data,
    clean_line_data,
    process_tielines,
    process_dclines,
    process_transformers,
    process_converters,
    build_converter_map,
    remap_dc_endpoints!,
    convert_line_to_pu!,
    rename_buses,
    rename_dc_buses,
    build_dc_capacity_map,
    form_ybus_with_shunt,
    calculate_single_injection_ptdfs,
    calculate_all_ttc_results,
    calculate_ptdfs_reduced,
    select_representative_nodes,
    kron_reduce_ybus,
    optimise_equivalent_capacities,
    export_bus_id_map,
    export_detailed_line_info,
    main_full_analysis,
    CONFIG,
    reset_config!,
    detect_islands,
    diagnose_islands,
    export_island_diagnostics,
    plot_network,
    plot_original_vs_reduced,
    plot_network_gis,
    plot_original_vs_reduced_gis

# Configuration
include("config.jl")

# Data loading and cleaning
include("data-loading.jl")

# Network matrix formation
include("ybus-formation.jl")

# Power Transfer Distribution Factor calculations
include("ptdf-calculations.jl")

# Representative node selection
include("representative-nodes.jl")

# Kron reduction
include("kron-reduction.jl")

# Optimisation functions
include("optimisation.jl")

# Export utilities
include("export-functions.jl")

# Main analysis workflow
include("main-analysis.jl")

# Detect Islands
include("island-detection.jl")

# Network visualisation
include("network-visualisation.jl")

end
