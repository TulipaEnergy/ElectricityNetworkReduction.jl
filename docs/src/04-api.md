# API Reference

```@autodocs
Modules = [ElectricityNetworkReduction]
Order   = [:function, :type]
```

## Exported Functions

This section provides an overview of the main exported functions in **ElectricityNetworkReduction.jl**, grouped by their role in the overall workflow. These functions are designed to support data ingestion, physical modeling, network reduction, optimisation, and result export.

---

## 1. Data Loading and Cleaning

These functions handle the initial stage of reading input data from an Excel workbook and preparing it for mathematical modeling.

- **`load_excel_data(file_path)`**
  Reads the mandatory `Lines`, `Tielines`, `Nodes`, and `Generators` sheets from an Excel input file. Also conditionally reads the `DCLines`, `Transformers`, and `Converters` sheets based on the corresponding `CONFIG.has_*` flags. Returns a dictionary of DataFrames keyed by element type.

- **`clean_line_data(lines_df)`**
  Cleans AC branch data by removing self-loops and assigning unique identifiers to missing or incomplete EIC codes.

- **`process_tielines(tielines_df)`**
  Processes inter-zonal AC transmission lines to ensure consistent representation of connections across zone boundaries. Deduplicates by EIC code (longest line kept) and assigns synthetic IDs for missing codes.

- **`rename_buses(nodes_df, generators_df, lines_df, tielines_df, Sbase)`**
  Assigns sequential integer IDs to all AC buses and returns updated DataFrames alongside the node metadata table. Preserves the `IsRepresentative` column and `Latitude`/`Longitude` columns from the Nodes sheet. Converts AC line parameters to per-unit.

- **`convert_line_to_pu!(df, baseMVA; in_pu)`**
  Converts line parameters from physical units (Ohms) to per-unit values using the `Voltage_level` column, if required.
  If `in_pu = true`, parameters are assumed already in per-unit. Modifies the data frame in place.

- **`process_dclines(dclines_df, Sbase)`**
  Prepares DC interconnector data for use. Sets AC impedance parameters to zero (DC lines must never enter the Y-bus), converts capacity to per-unit, removes self-loops, and assigns synthetic EIC codes for missing entries.

- **`rename_dc_buses(dclines_df, bus_map)`**
  Maps DC line `From_node`/`To_node` names to numerical bus IDs using the map produced by `rename_buses`. Raises a descriptive error if any DC bus name is absent from the Nodes sheet.

- **`process_transformers(transformers_df)`**
  Prepares transformer data for merging with the AC line set. Adds missing optional columns (`R`, `B`) with zero defaults, removes self-loops, and assigns synthetic EIC codes.

- **`process_converters(converters_df)`**
  Cleans and standardises the Converters sheet. Applies the same name-cleaning rules as `rename_buses` so that converter map keys match bus names throughout the pipeline.

- **`build_converter_map(converters_df)`**
  Returns a `Dict{String,String}` mapping each DC terminal bus name to its connected AC substation bus name. Used by `remap_dc_endpoints!` before numeric ID assignment.

- **`remap_dc_endpoints!(dclines_df, converter_map)`**
  Rewrites DC line endpoint bus names in-place: DC cable terminal names are replaced by their adjacent AC substation bus names using the converter map. Endpoints with no converter entry are left unchanged. This step must run before `rename_buses` so DC terminals are excluded from the Y-bus.

- **`build_dc_capacity_map(dclines_df, node_info, rep_node_ids; lines_df, tielines_df)`**
  Aggregates DC line capacities (in p.u.) by representative-node pair. When AC line data are provided, each DC endpoint is mapped to a representative in its own AC connected component. Same-zone DC lines are skipped only when both endpoints are in the same AC component; same-zone DC bridges between separate AC islands are retained. Returns a `Dict{Tuple{Int,Int}, Float64}` keyed by `(min_rep_id, max_rep_id)`. Used for additive TTC contribution in reporting and exported equivalent capacities.

---

## 2. Network Physics and Matrix Construction

These functions construct the mathematical representation of the electrical network.

- **`form_ybus_with_shunt(lines, tielines, nodes, Sbase)`**
  Assembles the bus admittance matrix ($Y_{bus}$), including the contribution of line shunt susceptances. AC lines and transformers (after merging) are included; DC interconnectors are excluded.

- **`calculate_all_ttc_results(Ybus, lines_df, tie_lines_df; dc_cap_map)`**
  Memory-optimised TTC computation for all $\binom{N}{2}$ bus-pair transactions. Factorises the $B$ matrix once, then computes PTDFs and TTC via shared back-solves. DC capacity is added additively using `dc_cap_map`. Supports multi-threaded execution when `CONFIG.parallel_processing = true`. Returns both the TTC DataFrame and a `Dict` of per-pair physical line capacities for downstream use.

- **`calculate_single_injection_ptdfs(Ybus; reference_bus=1)`**
  Core PTDF engine. Factorises the susceptance matrix once and computes voltage-angle sensitivities to unit injections at every non-reference bus. Handles multi-island networks by assigning one reference bus per AC connected component. Returns `(ptdf_single, lines_info, node_component)`. Used internally by `calculate_all_ttc_results` and `calculate_ptdfs_reduced`.

---

## 3. Island Detection and Diagnostics

These functions detect network connectivity issues and export diagnostic reports.

- **`detect_islands(lines_df, tielines_df, node_info, dclines_df)`**
  Builds the full network graph using AC lines, tie-lines, and DC lines as edges. Labels each bus with its connected-component index. Returns the components list, updated `node_info` (with an `:island` column), and the graph object. Used when `CONFIG.enable_plots = true` to colour nodes by island in plots.

- **`diagnose_islands(lines_df, tielines_df, node_info; dclines_df, top_n)`**
  Produces a per-island diagnostic report to distinguish physically-real islands from data-gap artefacts. Each island is classified as:
  - `REAL` — well-formed AC island
  - `SUSPECT` — contains buses of multiple voltage levels in the same zone (likely a missing transformer)
  - `DC-ONLY` — isolated AC island bridged to another island only via DC lines
  - `SINGLETON` — single bus with no AC connections

  Returns a summary DataFrame sorted largest-first, plus the raw components and node-component vectors.

- **`export_island_diagnostics(summary_df, output_path)`**
  Writes the island diagnostic summary DataFrame to a CSV file.

---

## 4. Network Reduction Logic

These functions implement the core algorithms used to reduce the size of the network while preserving its physical behavior.

- **`select_representative_nodes(Ybus, node_info, numbered_lines, numbered_tielines)`**
  Identifies representative nodes within each zone. Supports two modes controlled by `CONFIG.rep_node_mode`:
  - `"auto"`: selects the top `CONFIG.rep_node_k_per_zone` nodes per zone ranked by interconnection degree (line capacity as tiebreaker). Zones listed in `CONFIG.high_res_zones` are retained at full bus resolution (all buses become representative nodes). If this leaves an AC island without any representative, the best-ranked bus in that island is added as a forced representative.
  - `"manual_excel"`: reads the `IsRepresentative` column from the Nodes sheet.

  Falls back to `"auto"` with a warning if the column is missing or empty in manual mode.

- **`kron_reduce_ybus(Ybus, representative_nodes)`**
  Applies Kron reduction to eliminate internal nodes while preserving sensitivity relationships between representative nodes. Handles multi-island networks by applying small shunt regularisation ($\varepsilon = 10^{-8}$) before inversion to avoid singularity.

- **`calculate_ptdfs_reduced(Y_kron, rep_node_ids; high_res_ids)`**
  Calculates PTDFs for the smaller equivalent network using local indices and maps back to original IDs. When `high_res_ids` is non-empty, intra-high-res zone pairs are skipped to avoid the $O(n_{hires}^2)$ computation.

---

## 5. Capacity Optimisation

These functions use mathematical programming to determine synthetic line capacities for the reduced network.

- **`optimise_equivalent_capacities(ttc_original, ptdf_reduced_results; Type, lambda, allow_virtual_lines, allowed_synth_pairs, dc_cap_map, high_res_node_ids, phys_line_caps)`**
  Primary interface for solving the capacity fitting problem. Dispatches to `_solve_qp_model`, `_solve_lp_model`, or `_solve_miqp_model` based on `Type`. `QP` provides a fast accuracy/time balance, `LP` constructs a deterministic capacity envelope, and `MIQP` identifies binding synthetic lines with physically consistent capacities. DC capacity is added back in reported total TTC. Intra-high-res synthetic lines are fixed to their physical capacity and excluded from optimisation.

  Returns a tuple `(equivalent_capacities_df, ttc_equivalent_df)`.

---

## 6. Workflow and Configuration

These functions and objects control the full end-to-end execution of the model.

- **`main_full_analysis(input_dir, output_dir)`**
  High-level wrapper that executes the complete 11-step network reduction pipeline, from data loading to result export. Prints a step-by-step timing summary on completion. Returns `nothing`; all results are written to CSV files in `output_dir`.

- **`CONFIG`**
  Global configuration object. All parameters and their defaults:

  | Parameter | Type | Default | Description |
  | :--- | :--- | :--- | :--- |
  | `input_filename` | String | `"case118.xlsx"` | Input file name |
  | `case_study` | String | `"case118"` | Case study identifier (used in console output) |
  | `optimisation_type` | String | `"QP"` | `"QP"`, `"LP"`, or `"MIQP"` |
  | `base` | Float64 | `100.0` | System MVA base |
  | `bus_names_as_int` | Bool | `false` | `true` if bus IDs are integers |
  | `in_pu` | Bool | `false` | `true` if R, X, B already in per-unit |
  | `allow_virtual_lines` | Bool | `false` | Keep only physically connected synthetic lines |
  | `lambda` | Float64 | `1e-6` | Regularisation parameter (QP/MIQP) |
  | `ptdf_epsilon` | Float64 | `1e-6` | PTDF zero threshold |
  | `suffix` | String | `"QP"` | Suffix for output file names |
  | `miqp_binding_candidates_per_txn` | Int | `8` | Binding candidates retained per transaction in MIQP |
  | `miqp_time_limit_sec` | Float64 | `1800.0` | MIQP solver time limit |
  | `miqp_mip_rel_gap` | Float64 | `1e-4` | MIQP relative MIP gap |
  | `rep_node_mode` | String | `"auto"` | `"auto"` or `"manual_excel"` |
  | `rep_node_k_per_zone` | Int | `1` | Nodes per zone in auto mode |
  | `rep_node_degree_threshold` | Float64 | `1e-8` | Minimum susceptance to count as a connection |
  | `high_res_zones` | Vector{String} | `[]` | Zones retained at full bus resolution |
  | `enable_plots` | Bool | `true` | Generate GIS-based PNG plots |
  | `has_dc_lines` | Bool | `false` | Read DCLines sheet |
  | `dc_lines_sheet` | String | `"DCLines"` | Name of DC lines sheet |
  | `has_transformers` | Bool | `false` | Read Transformers sheet |
  | `transformers_sheet` | String | `"Transformers"` | Name of transformers sheet |
  | `transformers_in_pu` | Bool | `true` | Transformer X already in per-unit |
  | `has_converters` | Bool | `false` | Read Converters sheet |
  | `converters_sheet` | String | `"Converters"` | Name of converters sheet |
  | `parallel_processing` | Bool | `true` | Multi-threaded TTC enumeration |

- **`reset_config!()`**
  Resets all configuration parameters to their default values. Always call this between case studies in batch runs to avoid state leakage.

---

## 7. Visualisation (optional)

Network plots are generated when `CONFIG.enable_plots = true`. The plotting backend is **CairoMakie** + **GraphMakie**, which are regular dependencies installed with the package. Node colours represent zones; edge colours represent line types (gray = AC, red = AC tie-line, blue = DC interconnector).

- **`plot_network_gis(g, node_info, lines_df; title, show_names, node_sz)`**
  Plots a single network on a lon/lat axis. Uses `Latitude`/`Longitude` columns for geographic layout if present; otherwise uses a spring or stress layout. High-resolution zone areas are overlaid with a semi-transparent amber convex-hull polygon and a label. Returns a CairoMakie `Figure`.

- **`plot_original_vs_reduced_gis(g_orig, nodes_orig, lines_orig, g_red, nodes_red, lines_red; main_title)`**
  Produces a side-by-side comparison Figure (two panels, shared geographic bounding box). Left panel: full original network with unlabelled nodes. Right panel: reduced network with zone-code labels on external representative nodes; high-res zone buses are shown but not individually labelled. Saves to PNG via `CairoMakie.save`.

- **`plot_network(g, node_info, lines_df; title, n_size, f_size, show_names)`**
  Legacy plotting function using `Plots.jl` + `GraphRecipes`. Retained for backward compatibility. For new use cases, prefer `plot_network_gis`.

- **`plot_original_vs_reduced(g_orig, nodes_orig, lines_orig, g_red, nodes_red, lines_red, output_path)`**
  Legacy side-by-side comparison using `Plots.jl`. Saves a 1400×700 px PNG. Retained for backward compatibility.

---

## 8. Export Utilities

- **`export_bus_id_map(node_info, output_path)`**
  Writes the original-to-new bus ID mapping to CSV.

- **`export_detailed_line_info(lines_df, tielines_df, output_path)`**
  Writes comprehensive line information (per-unit parameters, type flags) to CSV.

- **`export_island_diagnostics(summary_df, output_path)`**
  Writes the island diagnostic summary to CSV.

---

## Internal Module Structure

The package follows a modular architecture, with each file responsible for a specific component of the workflow.

| File | Responsibility |
| :--- | :--- |
| `config.jl` | Centralized settings and global `CONFIG` object |
| `data-loading.jl` | Excel ingestion, per-unit normalization, DC line and converter handling |
| `export-functions.jl` | CSV export and reporting utilities |
| `island-detection.jl` | Connected-component detection, island diagnostics |
| `kron-reduction.jl` | Mathematical node elimination with multi-island regularisation |
| `main-analysis.jl` | 11-step top-level wrapper; timing summary |
| `network-visualisation.jl` | GIS-based (CairoMakie/GraphMakie) and legacy (Plots.jl) plot functions |
| `optimisation.jl` | QP fit, LP capacity envelope, MIQP binding-line MILP, TTC reporting |
| `ptdf-calculations.jl` | DC power flow sensitivity analysis; parallel TTC enumeration |
| `representative-nodes.jl` | Zone grouping, degree-based or manual node selection, high-res zone support |
| `ybus-formation.jl` | Physical matrix assembly ($Y_{bus}$) |
