# =============================================
# USER CONFIGURATION - CHANGE VALUES HERE ONLY
# =============================================

"""
    Config

Central configuration struct for the entire network reduction workflow.
Modify the default values below to run different case studies.
"""

Base.@kwdef mutable struct Config
    # -------------------------------
    # Data input/output
    # -------------------------------

    # input_data_dir::String  = ""      # Optional: Full path to input folder (defaults to test directory)
    # output_data_dir::String = ""      # Optional: Full path to save results (defaults to test directory)
    input_filename::String = "NL_HV_Network.xlsx"      # Name of the input Excel file (e.g., "case118.xlsx")
    case_study::String = "NL_case"      # Name of the case study
    bus_names_as_int::Bool = false      # true if bus names are integers, false if bus names are strings
    in_pu::Bool = false                 # true if transmission paramters (R,X,B) are in pu
    base::Float64 = 100.0               # MVA base for per-unit conversion
    optimization_type::String = "MIQP"    # "MIQP", "QP", or "LP"
    lambda::Float64 = 1e-6              # Regularization strength for capacity smoothing
    ptdf_epsilon::Float64 = 0.001       # Threshold below which PTDF is considered zero
    suffix::String = "MIQP"               # Used in output filenames (e.g., TTC_Comparison_QP.csv)
end

# Create a global config instance that users can modify
const CONFIG = Config()

# Optional: Print config on include for transparency
function print_config()
    println("="^60)
    println("CURRENT CONFIGURATION")
    println("="^60)
    for field in fieldnames(Config)
        value = getfield(CONFIG, field)
        println(rpad("$field:", 25), " $value")
    end
    println("="^60)
end

# Automatically print when config is loaded (optional)
print_config()
