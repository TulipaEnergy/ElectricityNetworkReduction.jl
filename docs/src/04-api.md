# API Reference

```@autodocs
Modules = [ElectricityNetworkReduction]
Order   = [:function, :type]
```

## Exported Functions

This section provides an overview of the main exported functions in **ElectricityNetworkReduction.jl**, grouped by their role in the overall workflow. These functions are designed to support data ingestion, physical modeling, network reduction, optimization, and result export.

---

## 1. Data Loading and Cleaning

These functions handle the initial stage of reading input data from Excel or CSV files and preparing it for mathematical modeling.

- **`load_excel_data(file_path)`**
  Reads the mandatory `Lines`, `Tielines`, `Nodes`, and `Generators` sheets from an Excel input file and returns structured data frames.

- **`clean_line_data(lines_df)`**
  Cleans branch data by removing self-loops and assigning unique identifiers to missing or incomplete EIC codes.

- **`process_tielines(tielines_df)`**
  Processes inter-zonal transmission lines to ensure consistent representation of connections across zone boundaries.

- **`rename_buses(nodes_df, lines_df, tielines_df)`**
  Assigns sequential integer IDs to all buses and returns updated data frames alongside a mapping from original to new IDs. Used internally to normalise bus identifiers before matrix construction.

- **`convert_line_to_pu!(df, baseMVA)`**
  Converts line parameters from physical units (Ohms) to per-unit values using Voltage (kV) and Current (A), if required.
  This function modifies the data frame in place.

---

## 2. Network Physics and Matrix Construction

These functions construct the mathematical representation of the electrical network.

- **`form_ybus_with_shunt(nodes, lines)`**
  Assembles the bus admittance matrix ($Y_{bus}$), including the contribution of line shunt susceptances.

- **`calculate_ptdfs_dc_power_flow(ybus)`**
  Computes Power Transfer Distribution Factors (PTDFs) using DC power flow assumptions.

- **`calculate_ttc_from_ptdfs(ptdfs, capacities)`**
  Calculates the original Total Transfer Capacities (TTCs) for a set of transactions based on PTDFs and line limits.

---

## 3. Network Reduction Logic

These functions implement the core algorithms used to reduce the size of the network while preserving its physical behavior.

- **`select_representative_nodes(ybus, node_info, numbered_lines, numbered_tielines)`**
  Identifies representative nodes within each zone. Supports two modes controlled by `CONFIG.rep_node_mode`:
  - `"auto"`: selects the top `CONFIG.rep_node_k_per_zone` nodes per zone ranked by interconnection degree (line capacity as tiebreaker).
  - `"manual_excel"`: reads the `IsRepresentative` column from the `Nodes` sheet.

- **`kron_reduce_ybus(ybus, representative_nodes)`**
  Applies Kron reduction to eliminate internal nodes while preserving sensitivity relationships between representative nodes.

---

## 4. Capacity Optimization

These functions use mathematical programming to determine synthetic line capacities for the reduced network.

- **`optimize_equivalent_capacities(ttc_orig, ptdf_red)`**
  Primary interface for solving the capacity fitting problem using LP, QP, or MIQP formulations.

---

## 5. Workflow and Configuration

These functions and objects control the full end-to-end execution of the model.

- **`main_full_analysis(input_dir, output_dir)`**
  High-level wrapper that executes the complete network reduction pipeline, from data loading to result export. Returns `nothing`; all results are written to CSV files in `output_dir`.

- **`CONFIG`**
  Global configuration object. Key parameters: `optimization_type`, `lambda`, `ptdf_epsilon`, `base`, `bus_names_as_int`, `in_pu`, `allow_virtual_lines`, `rep_node_mode`, `rep_node_k_per_zone`, `enable_plots`. See the Model Usage guide for details.

- **`reset_config!()`**
  Resets all configuration parameters to their default values. Always call this between case studies in batch runs.

---

## 6. Visualisation (optional)

Network plots are generated when `CONFIG.enable_plots = true`. The plotting functions use `Plots` and `GraphRecipes`, which are regular dependencies installed with the package.

- **`plot_network(g, node_info, lines_df; title, n_size, f_size, show_names)`**
  Plots a single network. Nodes are coloured by connected component (island). Uses `Latitude`/`Longitude` columns for geo-layout if present in the `Nodes` sheet, otherwise uses a spring layout.

- **`plot_original_vs_reduced(g_orig, nodes_orig, lines_orig, g_red, nodes_red, lines_red, output_path)`**
  Produces a side-by-side 1400×700 px comparison plot of the original and reduced networks, saved to `output_path`.

---

## Internal Module Structure

The package follows a modular architecture, with each file responsible for a specific component of the workflow.

| File | Responsibility |
| :--- | :--- |
| `config.jl` | Centralized settings and global constants |
| `data-loading.jl` | Excel/CSV ingestion and per-unit normalization |
| `export-functions.jl` | CSV export and reporting utilities |
| `island-detection.jl` | Connected-component detection (used when `enable_plots = true`) |
| `kron-reduction.jl` | Mathematical node elimination |
| `main-analysis.jl` | The top-level wrapper executing the full pipeline |
| `network-visualisation.jl` | Network plot functions (only called when `enable_plots = true`) |
| `optimization.jl` | JuMP models for LP, QP, and MILP formulations |
| `ptdf-calculations.jl` | DC power flow sensitivity analysis |
| `representative-nodes.jl` | Groups buses and identifies boundary nodes per zone |
| `ttc-calculations.jl` | Transfer capacity evaluation |
| `ybus-formation.jl` | Physical matrix assembly ($Y_{bus}$) |
