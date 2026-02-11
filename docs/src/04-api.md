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

- **`select_representative_nodes(nodes_df, zone)`**
  Identifies boundary or representative nodes within each zone based on interconnection degree and network topology.

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
  High-level wrapper that executes the complete network reduction pipeline, from data loading to result export.

- **`CONFIG`**
  Global configuration object containing parameters such as `optimization_type`, `lambda`, `ptdf_epsilon`, base power, and unit settings.

- **`reset_config!()`**
  Resets all configuration parameters to their default values.

---

## Internal Module Structure

The package follows a modular architecture, with each file responsible for a specific component of the workflow.

| File | Responsibility |
| :--- | :--- |
| `config.jl` | Centralized settings and global constants |
| `data-loading.jl` | Excel/CSV ingestion and per-unit normalization |
| `export-functions.jl` | CSV export and reporting utilities |
| `kron-reduction.jl` | Mathematical node elimination |
| `main-analysis.jl` | The top-level wrapper executing the full pipeline |
| `optimization.jl` | JuMP models for LP, QP, and MILP formulations [cite: 11] |
| `ptdf-calculations.jl` | DC power flow sensitivity analysis |
| `representative-nodes.jl` | Groups buses and identifies the "boundary" nodes to keep based on their connectivity degree |
| `ttc-calculations.jl` | Transfer capacity evaluation [cite: 10] |
| `ybus-formation.jl` | Physical matrix assembly ($Y_{bus}$) |
