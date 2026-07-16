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

The `ElectricityNetworkReduction` module requires several key libraries for optimisation and data handling, including `JuMP`, `DataFrames`, `XLSX`, solvers `HiGHS` and `Ipopt`, and plotting libraries `CairoMakie` and `GraphMakie`.

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

### Enabling parallel processing (recommended)

For large networks, start Julia with multiple threads to enable multi-threaded TTC computation:

```bash
julia --threads=auto
```

Then set `CONFIG.parallel_processing = true` (it is `true` by default). Julia prints a warning if this flag is set but only one thread is available.

---

## 3. Preparing Input Data for Analysis

Before running the model, the input grid data must be properly organised.
The model reads input data from a single **Excel (`.xlsx`)** workbook and identifies datasets based on predefined **sheet names**. CSV input is not currently supported.

---

### Required Sheet / File Names

Your input dataset must include the following core sheets:

* **Lines** – Branch parameters for the internal AC network
* **Tielines** – Parameters for AC lines connecting different zones or areas
* **Nodes** – Bus-level network information
* **Generators** – Generator data
  > **Note:** Generator data is required for the data-loading stage but is not currently used in the network reduction physics. It is reserved for future model extensions.

The following sheets are **optional** and are enabled via CONFIG flags:

* **DCLines** – DC interconnector data (enabled via `CONFIG.has_dc_lines = true`)
* **Transformers** – Transformer data (enabled via `CONFIG.has_transformers = true`)
* **Converters** – AC/DC converter station data (enabled via `CONFIG.has_converters = true`)

If a flag is set to `true` but the sheet is absent from the file, the model issues a warning and continues without that element type.

---

### Data Fields and Units

The model constructs the bus admittance matrix ($Y_{bus}$) and computes PTDFs based on the physical parameters provided.
Correct specification of units is **critical**, especially when performing per-unit (p.u.) conversions.

### Lines and Tielines Sheets

The following parameters are required for both **Lines** and **Tielines**:

| Parameter | Description |
| :--- | :--- |
| From_node / To_node | Connection points of the branch |
| Resistance (R) | Series resistance |
| Reactance (X) | Series reactance |
| Shunt Susceptance (B) | Total shunt susceptance |
| Capacity_MW | Thermal rating in MW |
| EIC_Code | Unique identifier (missing codes are auto-assigned) |

> **Unit Sensitivity**
>
> * If **R, X, B** are already provided in **per-unit (p.u.)**, set `CONFIG.in_pu = true`. No additional electrical parameters are required.
> * If **R, X, B** are provided in **Ohms**, set `CONFIG.in_pu = false` and also specify:
>   * **Voltage_level (kV)**
>   * **Current rating (A)**
>
> Without these values, the model cannot perform per-unit conversion, which will lead to incorrect results.

### DCLines Sheet

DC interconnectors only require capacity — no impedance parameters are needed:

| Parameter | Description |
| :--- | :--- |
| From_node / To_node | Terminal bus names |
| Capacity_MW | Rated capacity (symmetric, same both directions) |
| EIC_Code | Unique identifier (optional) |

DC line endpoints reference AC substation buses **after converter remapping** (see Converters sheet). They must appear in the Nodes sheet.

### Transformers Sheet

Transformers are treated as AC elements and merged into the line set before Y-bus assembly:

| Parameter | Description |
| :--- | :--- |
| From_node / To_node | Terminal bus names |
| X | Series reactance |
| Capacity_MW | Thermal rating in MW |
| R | Series resistance (optional, defaults to 0) |
| B | Shunt susceptance (optional, defaults to 0) |

Set `CONFIG.transformers_in_pu = true` if X (and R, B) are already in per-unit on the system base. Set to `false` to convert from ohms using a `Voltage_level` column (same conversion as AC lines).

### Converters Sheet

Converter stations map DC cable terminal buses to their adjacent AC substation buses. This remapping must happen before numeric ID assignment so DC terminals are excluded from the Y-bus:

| Parameter | Description |
| :--- | :--- |
| Converter_id | Unique identifier |
| From_node | DC terminal bus name |
| To_node | Adjacent AC substation bus name |
| Voltage_level | Voltage level in kV |
| Capacity_MW | Converter rated capacity in MW |

After remapping, DC terminal buses are removed from the node list and the DC line endpoints point to AC buses.

### Nodes Sheet

The following fields are required to define network hierarchy and support **Kron reduction**:

* **Bus name or number** – Unique bus identifier
* **Type** – Load, Generator, or Slack bus
* **Area** – Geographic or administrative region
* **Zone** – Grouping used to determine representative nodes
* **baseKV** – Voltage level in kV (used for per-unit conversion and island diagnostics)
* **Latitude / Longitude** – Geographic coordinates *(optional)*: used for GIS-based network plots when `enable_plots = true`. If absent, a spring/stress layout is used instead.
* **IsRepresentative** – Boolean flag *(optional)*: used only when `rep_node_mode = "manual_excel"`. Accepts `true/false`, `1/0`, `yes/no`.

---

## 4. How to Run a Case Study

This section explains how to configure and execute a complete network reduction case study using **ElectricityNetworkReduction.jl**, and how to interpret the generated outputs. A first-time user should be able to follow these steps end-to-end to successfully run a model.

### Step 1: Set the Configuration

All model behaviour is controlled through the global `CONFIG` object.
Before running a case study, update the relevant configuration parameters to match your input data and study objectives.

```julia
using ElectricityNetworkReduction

# Example configuration
CONFIG.input_filename    = "case118.xlsx"   # Input Excel file name
CONFIG.case_study        = "case118"         # Case study identifier
CONFIG.optimisation_type = "QP"             # Options: "QP", "LP", or "MIQP"
CONFIG.base              = 100.0            # System MVA base
CONFIG.bus_names_as_int  = false            # true if bus IDs are integers, false if strings
CONFIG.in_pu             = false            # true if input data (R, X, B) are already in per-unit
CONFIG.ptdf_epsilon      = 1e-6            # PTDF zero threshold
CONFIG.suffix            = "QP"            # Output file suffix
CONFIG.allow_virtual_lines = false          # false to keep only physically connected synthetic lines
CONFIG.rep_node_mode     = "auto"           # "auto" or "manual_excel"
CONFIG.rep_node_k_per_zone = 1             # Number of highest-degree nodes per zone (auto mode)

# Optional: retain specific zones at full bus resolution
CONFIG.high_res_zones    = []               # e.g. ["FR", "DE"] to retain France and Germany in full

# Optional: enable DC, transformer, and converter support
CONFIG.has_dc_lines      = false            # true if the file contains a DCLines sheet
CONFIG.has_transformers  = false            # true if the file contains a Transformers sheet
CONFIG.has_converters    = false            # true if the file contains a Converters sheet

# Optional: parallel processing
CONFIG.parallel_processing = true           # requires Julia started with --threads=auto
```

### Key Configuration Parameters

* `input_filename`:
  Name of the input Excel workbook (`.xlsx`). This file must exist inside the specified input directory (`test/inputs/`) and contain the required sheets (Lines, Tielines, Nodes, Generators). CSV input is not currently supported.

* `optimisation_type`:
  Selects the method used to determine equivalent line capacities:
  * `"QP"`: Quadratic Programming (default; via Ipopt), fits the AC TTC objective quickly.
  * `"LP"`: Deterministic capacity-envelope construction with HiGHS fixed-value extraction.
  * `"MIQP"`: Mixed-integer binding-line formulation via HiGHS, with candidate pruning and time/gap controls.

* `base`:
  System base power in MVA. All results are internally computed in per-unit and exported in MW using this base.

* `bus_names_as_int`:
  Set to `true` if bus identifiers are numeric (e.g. 101, 205), or `false` if they are strings (e.g. "Bus_101").

* `in_pu`:
  Set to `true` if line parameters (R, X, B) are already provided in per-unit.
  If `false`, the model will convert values from physical units using voltage and current ratings.

* `allow_virtual_lines`:
  Set to `false` to keep only synthetic lines that correspond to physically connected zone pairs in the original network. When `false`, any Kron-reduced synthetic line between zones with no direct physical connection is removed. If filtering removes all lines, the model falls back to allowing virtual lines automatically.

* `rep_node_mode`:
  Two modes are available: `"auto"` or `"manual_excel"`. In `"auto"` mode, `rep_node_k_per_zone` highest-degree nodes are selected per zone (degree ties are broken by total incident line capacity). If this leaves an AC island without a representative, the best-ranked bus in that island is added automatically. In `"manual_excel"` mode, representative nodes must be flagged in the `IsRepresentative` column of the `Nodes` sheet. Falls back to `"auto"` with a warning if the column is missing or empty.

* `high_res_zones`:
  List of zone codes to retain at **full bus resolution** in the reduced network. All buses in these zones become representative nodes; all other zones are reduced to one (or `k`) representative node(s). Leave as `[]` (default) for standard single-representative-per-zone reduction.

  ```julia
  CONFIG.high_res_zones = ["FR"]          # keep France at full resolution
  CONFIG.high_res_zones = ["FR", "DE"]    # keep France and Germany at full resolution
  ```

* `has_dc_lines` / `dc_lines_sheet`:
  Set `has_dc_lines = true` when the input file contains DC interconnector data. `dc_lines_sheet` specifies the Excel sheet name (default: `"DCLines"`).

* `has_transformers` / `transformers_sheet` / `transformers_in_pu`:
  Set `has_transformers = true` to read and merge transformer data. `transformers_in_pu = true` means the transformer reactance (X) is already in per-unit on the system base.

* `has_converters` / `converters_sheet`:
  Set `has_converters = true` when the input file contains an AC/DC converter station sheet. Converters remap DC cable terminal buses to their adjacent AC substation buses before ID assignment.

* `parallel_processing`:
  Set to `true` to enable multi-threaded TTC enumeration. Julia must be started with `--threads=auto` (or `-t N`) for this to have any effect. Has no impact on the LU factorisation (always sequential).

* `enable_plots`:
  Set to `true` to generate GIS-based PNG plots of the original and reduced networks. Nodes are coloured by zone; AC lines are gray, AC tie-lines are red, and DC interconnectors are blue (curved). High-resolution zone areas are shaded in amber.

---

### Step 2: Specify Input and Output Directories

The model separates input data from output results.
You must explicitly provide the directories when running a case study.

```julia
input_dir  = "test/inputs/case118"
output_dir = "test/outputs/case118"
```

`input_dir`:
Contains the grid data file specified by `CONFIG.input_filename`.

`output_dir`:
Will be created automatically (if it does not exist) and populated with all intermediate and final results.

---

### Step 3: Execute the Full Analysis Pipeline

Once the configuration and directories are set, run the full automated workflow:

```julia
main_full_analysis(input_dir, output_dir)
```

This single function call performs the complete pipeline, writing all results to CSV files in `output_dir`. It returns `nothing`.

The pipeline executes the following steps in order:

1. **Load and validate input data** — reads the Excel workbook, processes AC lines, tie-lines, transformers (merged into AC lines), DC interconnectors, and AC/DC converters. DC terminal buses are remapped to AC substation buses and excluded from the node list before numeric ID assignment.

2. **Island detection and original network plot** (if `enable_plots = true`) — builds the full network graph (AC + DC edges), labels connected components, and saves `Network_Original_<suffix>.png`.

3. **Build the admittance matrix ($Y_{bus}$) and export diagnostics** — assembles the full-network bus admittance matrix from AC lines and transformers. Exports island diagnostics, bus ID map, and line details.

4. **Select representative nodes** — identifies one or more representative nodes per zone, either automatically by network degree or from a manual Excel column (controlled by `CONFIG.rep_node_mode`). Zones in `CONFIG.high_res_zones` are retained at full resolution.

5. **Build virtual line filter and DC capacity map** — determines which synthetic lines correspond to directly connected zone pairs (AC or DC). Aggregates DC line capacities by representative-node pair, mapping each DC endpoint to a representative in its own AC connected component. Same-zone DC lines are skipped only when both endpoints are in the same AC component; same-zone DC bridges between separate AC islands are retained.

6. **Original network TTC/PTDF analysis** — computes TTC for all canonical bus-pair transactions using PTDFs. DC capacity is added additively: $TTC = TTC_{AC} + C_{DC}$. Parallelised across CPU threads when `parallel_processing = true`.

7. **Kron reduction** — eliminates all non-representative nodes, producing a reduced admittance matrix and a set of synthetic lines between representative nodes.

8. **Reduced-network PTDF computation** — repeats the PTDF calculation on the reduced topology. Intra-high-res zone pairs are skipped.

9. **Capacity optimisation** — solves the QP/LP/MIQP capacity-fitting problem. AC synthetic capacities are fitted to the AC TTC component; DC capacity is added back in the reported total TTC and exported as `is_dc = true`. Intra-high-res synthetic lines are fixed to their physical capacity (not optimised).

10. **Reduced network visualisation** (if `enable_plots = true`) — saves `Network_Reduced_<suffix>.png` and `Network_Original_vs_Reduced_<suffix>.png`.

11. **TTC comparison and result export** — writes all intermediate and final outputs to CSV files in `output_dir`.

Progress information and solver status messages are printed to the console during execution. A timing summary is printed on completion.

---

### Optional: Enable Network Visualisation

GIS-based PNG plots of the original and reduced networks are generated by default (`CONFIG.enable_plots = true`). To disable them:

```julia
CONFIG.enable_plots = false
main_full_analysis(input_dir, output_dir)
```

If `Latitude` and `Longitude` columns are present in the Nodes sheet, the plots use geographic coordinates. Otherwise a spring or stress layout is used automatically.

---

## 5. Reviewing the Results

After the run completes, the output directory will contain several CSV files documenting each stage of the network reduction process.

### Key Output Files

* `Bus_ID_Map_<suffix>.csv`:
  Maps every original bus name to the sequential integer ID used internally. Use this to cross-reference results against the original network data.

* `Island_Diagnostics_<suffix>.csv`:
  Per-island summary produced by `diagnose_islands`, one row per AC-connected component, sorted largest-first. Columns: `island_id`, `n_buses`, `zones`, `voltage_kv`, `dc_bridge`, `diagnosis`, `suspect_zones`.

  The `diagnosis` column classifies each island as one of:

  * `REAL` — a well-formed AC island: multiple buses, single voltage level per zone. No action needed. If the network is expected to be a single synchronous system, more than one `REAL` island signals a genuine AC connectivity gap — check for missing lines/tie-lines between the islands.
  * `SUSPECT` — the island contains buses at more than one voltage level within the same zone (listed in `suspect_zones`). This almost always indicates a missing transformer branch in the input data (the voltage levels should be linked but aren't). Resolve by adding the missing transformer to the Lines/Transformers sheet, then re-run.
  * `DC-ONLY` — the island has no AC path to the rest of the network but is linked to another island via a DC interconnector (`dc_bridge = true`). This is expected and not an error for legitimately asynchronous areas (e.g. offshore wind hubs, HVDC-connected zones) — just confirm `CONFIG.has_dc_lines = true` so the DC link is used for cross-island TTC instead of being treated as infinite.
  * `SINGLETON` — a single bus with no AC or DC connections at all. This is usually a data problem: a bus present in the Nodes sheet but missing from the Lines/DC Lines sheets, or a `From`/`To` typo elsewhere pointing to the wrong bus ID. Check the bus's entries in the raw input file and confirm its ID matches the branch data.

* `Line_Details_<suffix>.csv`:
  Comprehensive line information for AC lines and tie-lines, including per-unit parameters after conversion.

* `TTC_Original_Network_<suffix>.csv`:
  Original network TTC values for all representative-node-to-representative-node transactions. Columns: `transaction_from`, `transaction_to`, `TTC_MW` (total), `TTC_AC_MW` (AC component only), `TTC_DC_MW` (DC additive contribution), `limiting_line_from`, `limiting_line_to`.

* `PTDF_Reduced_Network_<suffix>.csv`:
  Power Transfer Distribution Factors for the reduced network. These sensitivities can be directly used in optimisation models such as DC OPF, unit commitment, or market simulations.

* `Equivalent_Capacities_<suffix>.csv`:
  The optimised capacities of synthetic lines in the reduced network. Columns: `from`, `to`, `from_node`, `to_node`, `capacity_MW`, `capacity_pu`, `X_pu` (equivalent reactance back-computed from Kron-reduced $Y_{bus}$), `is_dc` (true for DC interconnectors appended from the original network).

* `TTC_Comparison_<suffix>.csv`:
  Main comparison of Total Transfer Capacities between the original full network and the reduced equivalent network. `TTC_Equivalent_MW` is the reduced-network TTC produced by the selected optimisation mode. `TTC_Mismatch_MW`/`TTC_Error_Pct` measure how far it is from `TTC_Original_MW`.

Choose the optimisation mode according to the study objective:

* **QP**: use when you want the best practical balance between TTC accuracy and computation time.
* **LP**: use when you want a deterministic, solver-light capacity envelope.
* **MIQP**: use when the limiting synthetic line and physically consistent capacities matter more than speed.

Pick the formulation that matches the study goal and read its `TTC_Equivalent_MW` directly.

### Interpreting the Results

A successful reduction should exhibit:

* Small TTC mismatches (typically < 0–2%), checked via `TTC_Error_Pct` in `TTC_Comparison_<suffix>.csv`
* Physically consistent flow sensitivities
* A significantly reduced network size (tens of nodes instead of thousands)

If large TTC errors are observed, review:

* Zone definitions and representative node selection
* Unit consistency (per-unit vs physical units)
* `ptdf_epsilon` (if too large, important PTDF contributions are dropped)
* Solver configuration (`lambda` for QP, `bigM_factor` for MIQP)
* Island diagnostics — `SUSPECT` islands indicate a missing transformer branch; unexpected `SINGLETON` islands indicate a disconnected/mistyped bus; see [Key Output Files](#key-output-files) above for the full breakdown of all four diagnosis categories

### Advanced: Troubleshooting

If the optimisation fails to converge, consider:

* **Checking Connectivity:** Ensure all representative nodes are electrically connected in the original network.
* **Adjusting Lambda:** Increase $\lambda$ in `CONFIG` if synthetic capacities are fluctuating significantly.
* **MIQP controls:** For `"MIQP"` (MILP), adjust `CONFIG.miqp_binding_candidates_per_txn`, `CONFIG.miqp_time_limit_sec`, or `CONFIG.miqp_mip_rel_gap` if binding-line fitting is slow or too coarse.
* **Large `TTC_Error_Pct` under MIQP/LP:** the reduced network cannot realise that transaction's target exactly with one static capacity per synthetic line. Consider more representative nodes, allowing virtual lines, or using high-resolution zones.
* **Cross-island transactions:** If the original network has true electrical islands, ensure DC interconnectors are loaded (with `CONFIG.has_dc_lines = true`) so cross-island TTC is attributed correctly rather than defaulting to infinity.

---
