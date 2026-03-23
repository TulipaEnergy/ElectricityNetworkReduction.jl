# Model Usage Guide

This guide will walk you through setting up your environment, installing **ElectricityNetworkReduction.jl**, and running your first network reduction analysis.

---

## 1. Installing Julia and VS Code

To use this package, you first need to install the Julia programming language and a suitable code editor.

* **Install Julia**: Download the latest stable version from the [official Julia website](https://julialang.org/downloads/).
* **Install VS Code**: While you can run Julia from a terminal, we recommend [Visual Studio Code](https://code.visualstudio.com/) with the **Julia Extension** installed for a better development experience.

---

## 2. Installing ElectricityNetworkReduction.jl

### Starting Julia

Choose one of the following:

* **In VS Code**: Press `CTRL+Shift+P`, type "Julia: Start REPL", and press `Enter`.
* **In Terminal**: Type `julia` and press `Enter`.

### Adding the Package and Dependencies

The `ElectricityNetworkReduction` module requires several key libraries for optimization and data handling, including `JuMP`, `DataFrames`, `XLSX`, and solvers like `HiGHS` and `Ipopt`.

* Run the following commands to install the package directly from GitHub:

```julia
using Pkg
Pkg.add("ElectricityNetworkReduction")
Pkg.instantiate()
```

### Verifying the Installation

Press backspace to return to the standard Julia prompt and run:

```julia
using ElectricityNetworkReduction
```

To check if the package is active, enter help mode by pressing ? and search for a core function:

```julia
help?> main_full_analysis
```

If you see the documentation for the function, the installation was successful!

## 3. Preparing Input Data for Analysis

Before running the model, the input grid data must be properly organised.
The model supports input data in **Excel (`.xlsx`)** or **CSV** formats and identifies datasets based on predefined **sheet names** (for Excel) or **file names** (for CSV).

---

### Required Sheet / File Names

Your input dataset must include the following four sheets (or corresponding CSV files):

* **Lines** – Branch parameters for the internal network
* **Tielines** – Parameters for lines connecting different zones or areas
* **Nodes** – Bus-level network information
* **Generators** – Generator data
  > **Note:** Generator data is required for the data-loading stage but is not currently used in the network reduction physics. It is reserved for future model extensions.

### Data Fields and Units

The model constructs the bus admittance matrix ($Y_{bus}$) and computes PTDFs based on the physical parameters provided.
Correct specification of units is **critical**, especially when performing per-unit (p.u.) conversions.

### Lines and Tielines Sheets

The following parameters are required for both **Lines** and **Tielines**:

| Parameter | Description |
| :--- | :--- |
| From-node / To-node | Connection points of the branch |
| Resistance (R) | Series resistance |
| Reactance (X) | Series reactance |
| Shunt Susceptance (B) | Total shunt susceptance |

> **Unit Sensitivity**
>
> * If **R, X, B** are already provided in **per-unit (p.u.)**, no additional electrical parameters are required.
> * If **R, X, B** are provided in **Ohms**, you **must** also specify:
>   * **Voltage level (kV)**
>   * **Current rating (A)**
>
> Without these values, the model cannot perform per-unit conversion, which will lead to incorrect results.

### Nodes Sheet

The following fields are required to define network hierarchy and support **Kron reduction**:

* **Bus name or number** – Unique bus identifier
* **Type** – Load, Generator, or Slack bus
* **Area** – Geographic or administrative region
* **Zone** – Grouping used to determine representative nodes

## 4. How to Run a Case Study

This section explains how to configure and execute a complete network reduction case study using **ElectricityNetworkReduction.jl**, and how to interpret the generated outputs. A first-time user should be able to follow these steps end-to-end to successfully run a model.

### Step 1: Set the Configuration

All model behaviour is controlled through the global `CONFIG` object.
Before running a case study, you should update the relevant configuration parameters to match your input data and study objectives.

```julia
using ElectricityNetworkReduction

# Example configuration
CONFIG.input_filename = "case118.xlsx"    # Input Excel file name
CONFIG.case_study = "case118"             # Case study identifier
CONFIG.optimization_type = "QP"           # Options: "QP", "LP", or "MIQP"
CONFIG.base              = 100.0          # System MVA base
CONFIG.bus_names_as_int  = false          # true if bus IDs are integers, false if strings
CONFIG.in_pu             = false          # true if input data (R, X, B) are already in per-unit
CONFIG.ptdf_epsilon      = 1e-6           # PTDF zero threshold
CONFIG.suffix            = "QP"           # Output file suffix
CONFIG.allow_virtual_lines = false        # false to keep only physically connected synthetic lines
CONFIG.rep_node_mode     = "auto"         # "auto" or "manual_excel"
CONFIG.rep_node_k_per_zone = 1            # Number of highest-degree nodes to select per zone (auto mode)
```

### Key Configuration Parameters

* `input_filename`:
  Name of the input data file (Excel or CSV). This file must exist inside the specified input directory (test/inputs/) and contain the required sheets/files (Lines, Tielines, Nodes, Generators).

* `optimization_type`:
  Selects the method used to determine equivalent line capacities:

  * "QP": Quadratic Programming (default; via Ipopt)
  * "LP": Linear Programming (via Ipopt)
  * "MIQP": Mixed-Integer formulation (binding line selection via HiGHS)

* `base`:
  System base power in MVA. All results are internally computed in per-unit and exported in MW using this base.

* `bus_names_as_int`:
  Set to true if bus identifiers are numeric (e.g. 101, 205), or false if they are strings (e.g. "Bus_101").

* `in_pu`:
  Set to true if line parameters (R, X, B) are already provided in per-unit.
  If false, the model will convert values from physical units using voltage and current ratings.

* `allow_virtual_lines`:
  Set to `false` to keep only synthetic lines that correspond to physically connected zone pairs in the original network. When `false`, any Kron-reduced synthetic line between zones with no direct physical connection is removed. If filtering removes all lines, the model falls back to allowing virtual lines automatically.

* `rep_node_mode`:
  Two modes are available: `"auto"` or `"manual_excel"`. In `"auto"` mode, `rep_node_k_per_zone` highest-degree nodes are selected per zone (degree ties are broken by total incident line capacity). In `"manual_excel"` mode, representative nodes must be flagged in the `IsRepresentative` column of the `Nodes` sheet. Falls back to `"auto"` with a warning if the column is missing or empty.

### Step 2: Specify Input and Output Directories

The model separates input data from output results.
You must explicitly provide the directories when running a case study.

```julia
input_dir  = "test/inputs/case118"
output_dir = "test/outputs/case118"
```

`input_dir`:
Contains the grid data file specified by CONFIG.input_filename.

`output_dir`:
Will be created automatically (if it does not exist) and populated with all intermediate and final results.

### Step 3: Execute the Full Analysis Pipeline

Once the configuration and directories are set, run the full automated workflow:

```julia
main_full_analysis(input_dir, output_dir)
```

This single function call performs the complete pipeline, writing all results to CSV files in `output_dir`. It returns `nothing`.

The pipeline executes the following steps in order:

1. **Load and validate input data** — reads the Excel/CSV file, converts line parameters to per-unit if needed, and renames buses to sequential integers internally.

2. **Build the admittance matrix** ($Y_{bus}$) — assembles the full-network bus admittance matrix from line resistance, reactance, and shunt susceptance.

3. **Compute PTDFs for the original network** — calculates Power Transfer Distribution Factors for all inter-zonal transactions in the full network.

4. **Detect islands** (if `enable_plots = true`) — finds connected components and labels nodes for visualisation colouring.

5. **Select representative nodes** — identifies one or more representative nodes per zone, either automatically by network degree or from a manual Excel column (controlled by `CONFIG.rep_node_mode`).

6. **Apply Kron reduction** — eliminates all non-representative nodes, producing a reduced admittance matrix and a set of synthetic lines between representative nodes.

7. **Filter virtual lines** (if `allow_virtual_lines = false`) — removes synthetic lines between zones that have no direct physical connection in the original network.

8. **Compute PTDFs for the reduced network** — repeats the PTDF calculation on the reduced topology.

9. **Optimise equivalent line capacities** — solves a QP/LP/MIQP problem to find synthetic line thermal limits that best reproduce the original inter-zonal transfer capacities.

10. **Export results** — writes all intermediate and final outputs to CSV files in `output_dir`.

Progress information and solver status messages are printed to the console during execution.

### Optional: Enable Network Visualisation

To generate a side-by-side PNG plot of the original and reduced networks, set the flag before running:

```julia
CONFIG.enable_plots = true
main_full_analysis(input_dir, output_dir)
```

This produces `Network_Original_vs_Reduced_<suffix>.png` in the output directory. By default `enable_plots = false` and no plot is generated.

### 5. Reviewing the Results

After the run completes, the output directory will contain several CSV files documenting each stage of the network reduction process.

#### Key Output Files

* `Equivalent_Capacities.csv`:
  Contains the optimized capacities of synthetic lines in the reduced network.
  These capacities define the thermal limits of the equivalent model and are expressed in MW on the specified base.

* `TTC_Comparison.csv`:
  Provides a detailed comparison of Total Transfer Capacities (TTCs) between the original full network and the reduced equivalent network.
  This file includes absolute and percentage errors, allowing you to assess how accurately the reduced model preserves inter-zonal transfer limits.

* `PTDF_Reduced_Network.csv`:
  Contains Power Transfer Distribution Factors (PTDFs) for the reduced network.
  These sensitivities can be directly used in optimisation models such as DC OPF, unit commitment, or market simulations.

#### Interpreting the Results

A successful reduction should exhibit:

* Small TTC mismatches (typically < 1–2%)
* Physically consistent flow sensitivities
* A significantly reduced network size (tens of nodes instead of thousands)

If large TTC errors are observed, users should review:

* zone definitions,
* representative node selection,
* unit consistency (per-unit vs physical units),
* solver configuration.

#### Advanced: Interpreting Results

If the optimization fails to converge, consider:

* **Checking Connectivity:** Ensure all representative nodes are electrically connected in the original network.
* **Adjusting Lambda:** Increase $\lambda$ in `CONFIG` if synthetic capacities are fluctuating significantly.
* **Big-M Factor:** For "MIQP" (MILP), adjust the `bigM_factor` if binding constraints are not being identified correctly.

---
