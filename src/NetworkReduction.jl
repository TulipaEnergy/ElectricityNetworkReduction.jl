module NetworkReduction

# Explicit imports with package prefixes for better code clarity and dependency management
using XLSX: readxlsx, gettable
using DataFrames: DataFrames
using SparseArrays: SparseArrays, spzeros, sparse, SparseMatrixCSC
using LinearAlgebra: inv, pinv, Matrix, complex, imag, deg2rad
using CSV: write
using Statistics: mean
using JuMP:
    JuMP,
    Model,
    @variable,
    @objective,
    @constraint,
    optimize!,
    value,
    termination_status,
    set_silent,
    raw_status
using Ipopt: Optimizer
using MathOptInterface: OPTIMAL, LOCALLY_SOLVED

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
