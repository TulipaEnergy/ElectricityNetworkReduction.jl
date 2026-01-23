# Installation

## From gitHub repository

```julia
using Pkg
Pkg.add(url="https://github.com/TulipaEnergy/NetworkReduction.jl.git")
Pkg.instantiate()
```

## Local development installation

```julia
# Clone the repository
git clone https://github.com/TulipaEnergy/NetworkReduction.jl.git
cd NetworkReduction.jl

# Start Julia and activate project
julia --project=@.

# Instantiate dependencies
using Pkg
Pkg.instantiate()
```

## Basic usage

```julia
using NetworkReduction

# Define input/output directories
input_dir = "test/inputs/NL_case"    # Contains your Excel network data

output_dir = "test/outputs/NL_case"  # Where results will be saved

# Run the complete analysis
results = main_full_analysis(input_dir, output_dir)
```

## How to run a case study

1. **Prepare Data:** Place your network Excel file (containing 'Lines', 'Tielines', 'Nodes', and 'Generators' sheets) in the `inputs/` folder.
2. **Set Configuration:** Ensure `config.jl` points to your filename and preferred optimization type. All parameters are centralized in config.jl:

```julia
CONFIG.input_filename = "case118.xlsx"       # Input Excel file name
CONFIG.case_study = "case118"                # Case study identifier
CONFIG.bus_names_as_int = false              # Bus names are strings/integers (true for integers, false for strings)
CONFIG.in_pu = false                         # Line parameters are in ohms/per-unit (true for per-unit, fasle for ohms)
CONFIG.base = 100.0                          # MVA base for per-unit conversion
CONFIG.optimization_type = "QP"              # Optimization type used for equivalent capcaites "MIQP", "QP", or "LP"
CONFIG.lambda = 1e-6                         # Regularization parameter
CONFIG.ptdf_epsilon = 0.001                  # PTDF zero threshold
CONFIG.suffix = "QP"                         # Output file suffix
```

1. **Execute:** Run the `main_full_analysis` function.
2. **Review Results:** Check the `outputs/` folder for:

```text
| File                         | Description                   |
| ---------------------------- | ----------------------------- |
| Bus_ID_Map_QP.csv            | Mapping of bus names to IDs   |
| Line_Details_QP.csv          | Detailed line parameters      |
| Representative_Nodes_QP.csv  | Selected representative nodes |
| TTC_Original_Network_QP.csv  | Original TTCs                 |
| PTDF_Reduced_Network_QP.csv  | Reduced PTDFs                 |
| Equivalent_Capacities_QP.csv | Synthetic line capacities     |
| TTC_Comparison_QP.csv        | TTC validation                |
```

## Advanced: Interpreting Results

If the optimization fails to converge, consider:

- **Checking Connectivity:** Ensure all representative nodes are electrically connected in the original network.
- **Adjusting Lambda:** Increase $\lambda$ in `CONFIG` if synthetic capacities are fluctuating significantly.
- **Big-M Factor:** For "MIQP" (MILP), adjust the `bigM_factor` if binding constraints are not being identified correctly[cite: 89, 93].
