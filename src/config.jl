# =============================================
# USER CONFIGURATION - CHANGE VALUES HERE ONLY
# =============================================

"""
    Config

Central configuration struct for the entire network reduction workflow.
Modify the default values below to run different case studies.
"""
Base.@kwdef mutable struct Config
    # Data input/output
    input_filename::String = "case118.xlsx"   # Input Excel file name
    case_study::String = "case118"                  # Case study identifier


    # Flags that change per case study
    bus_names_as_int::Bool = false      # true if bus names are integers
    in_pu::Bool = false                 # true if R,X,B are already in pu
    allow_virtual_lines::Bool = false   # set to false to eliminate virtual lines

    # Numerical parameters
    base::Float64 = 100.0               # MVA base for per-unit conversion
    optimization_type::String = "MIQP"    # "MIQP", "QP", or "LP"
    lambda::Float64 = 1e-6              # Regularization parameter
    ptdf_epsilon::Float64 = 1e-6        # PTDF zero threshold
    suffix::String = "MIQP"               # Suffix for output files

    # Representative node selection
    rep_node_mode::String = "auto"      # "auto" or "manual_excel"

    # Only used when rep_node_mode == "auto"
    rep_node_k_per_zone::Int = 1        # Number of highest-degree nodes to select per zone

    # Used in both modes for degree calculation
    rep_node_degree_threshold::Float64 = 1e-8

end

# Create a global config instance
CONFIG = Config()

"""
    reset_config!()
Resets the global CONFIG object to its default values.
Useful for batch testing multiple case studies.
"""
function reset_config!()
    global CONFIG = Config()
    println("Configuration reset to defaults.")
end

function print_config()
    println("="^60)
    println("CURRENT CONFIGURATION: $(CONFIG.case_study)")
    println("="^60)
    for field in fieldnames(Config)
        println(rpad(string(field), 20), ": ", getfield(CONFIG, field))
    end
    println("="^60)
end
