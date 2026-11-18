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
    case_study::String = "case118"            # Case study identifier

    # Flags that change per case study
    bus_names_as_int::Bool = false      # true if bus names are integers
    in_pu::Bool = false               # true if R,X,B are already in pu
    allow_virtual_lines::Bool = false   # set to false to eliminate virtual lines

    # Numerical parameters
    base::Float64 = 100.0               # MVA base for per-unit conversion
    # "QP" (default), "LP", or "MIQP". QP is a fast continuous fit, LP a
    # deterministic capacity-envelope construction, MIQP a conservative
    # binding-line model with squared relative errors. All report physical TTC.
    optimisation_type::String = "QP"
    lambda::Float64 = 1e-6              # Regularisation parameter
    ptdf_epsilon::Float64 = 1e-6        # PTDF zero threshold
    suffix::String = "QP"                 # Suffix for output files

    # SCIP is the open-source default. Any other MIQP-capable JuMP solver may be
    # assigned after installing/importing it separately; solver-specific
    # parameters go in miqp_optimizer_attributes.
    miqp_optimizer::Any = SCIP.Optimizer
    miqp_optimizer_attributes::Dict{String,Any} = Dict{String,Any}()
    miqp_binding_candidates_per_txn::Int = 0 # 0 considers all relevant branches
    miqp_safe_binding_screening::Bool = true
    miqp_gamma_C::Float64 = 1.0
    miqp_time_limit_sec::Float64 = 1800.0
    miqp_mip_rel_gap::Float64 = 1e-4

    # Representative node selection
    rep_node_mode::String = "auto"      # "auto" or "manual_excel"

    # Only used when rep_node_mode == "auto"
    rep_node_k_per_zone::Int = 1        # Number of highest-degree nodes to select per zone

    # Used in both modes for degree calculation
    rep_node_degree_threshold::Float64 = 1e-8

    # -----------------------------------------------------------------
    # HIGH-RESOLUTION ZONE SELECTION
    # -----------------------------------------------------------------
    # Zones listed here are retained at FULL bus resolution in the reduced network.
    # All other zones are reduced to one representative node (or k nodes when
    # rep_node_k_per_zone > 1).
    # The result is the complete internal network of the selected zone(s) plus
    # one equivalent bus per external zone, connected by Kron-equivalent lines
    # whose capacities are optimised to match original-network TTC values.
    #
    # Example — keep France at full resolution:
    #   high_res_zones = ["FR"]
    # Example — keep France and Germany:
    #   high_res_zones = ["FR", "DE"]
    # Leave empty (default) for standard single-representative-per-zone reduction.
    #
    # Must be a genuinely empty vector, not [""]: a missing Zone value in the
    # Nodes sheet is itself converted to "" (see convert_to_string in
    # data-loading.jl), so high_res_zones = [""] would silently treat every
    # bus with a blank Zone cell as high-resolution.
    high_res_zones::Vector{String} = String[]

    # Visualisation — on by default. Set to false to skip generating GIS-based
    # PNG plots of the original and reduced networks (CairoMakie + GraphMakie).
    enable_plots::Bool = true

    # -----------------------------------------------------------------
    # DC LINE CONFIGURATION
    # -----------------------------------------------------------------
    # Set to true when the input Excel file contains a DCLines sheet.
    has_dc_lines::Bool = false

    # Name of the Excel sheet containing DC line data.
    dc_lines_sheet::String = "DCLines"

    # -----------------------------------------------------------------
    # TRANSFORMER CONFIGURATION
    # -----------------------------------------------------------------
    # Set to true when the input Excel file contains a Transformers sheet.
    # The sheet must use the same column names as the Lines sheet:
    #   From_node, To_node, X, Capacity_MW (R and B default to 0 if absent).
    has_transformers::Bool = false

    # Name of the Excel sheet containing transformer data.
    transformers_sheet::String = "Transformers"

    # Set to true when transformer X (and R, B) are already in per-unit on the
    # system base. Set to false to convert from ohms using the Voltage_level column
    # (same conversion as AC lines).
    transformers_in_pu::Bool = true

    # -----------------------------------------------------------------
    # CONVERTER CONFIGURATION
    # -----------------------------------------------------------------
    # true when the input Excel file contains a Converters sheet.
    # Converters bridge DC terminal buses to their adjacent AC substation
    # buses.  Without them, every DC terminal bus becomes a singleton island
    # and DC capacity is misattributed in build_dc_capacity_map.
    #
    # Expected sheet columns (same naming convention as Lines/DCLines):
    #   Converter_id, From_node (DC terminal), To_node (AC bus),
    #   Voltage_level, Capacity_MW
    has_converters::Bool = false

    # Name of the Excel sheet containing converter data.
    converters_sheet::String = "Converters"

    # -----------------------------------------------------------------
    # PARALLEL PROCESSING
    # -----------------------------------------------------------------
    # Set to true to enable multi-threaded TTC enumeration (the dominant cost,
    # typically 97 %+ of total runtime for large networks).
    #
    # Julia must be started with multiple threads for this to have any effect:
    #   julia --threads=auto      (uses all logical CPU cores — recommended)
    #   julia -t 8                (exactly 8 threads)
    #   julia -t 24                (exactly 24 threads)
    # Has no effect when Julia is running with a single thread (a warning is
    # printed in that case so the user knows to restart with --threads).
    parallel_processing::Bool = false

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
