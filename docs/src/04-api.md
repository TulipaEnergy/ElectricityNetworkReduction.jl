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
  Converts line parameters from physical units (R and X in ohms, B in µS) to per-unit values using the `Voltage_level` column, if required.
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

- **`apply_converter_limits!(dclines_df, converters_df, Sbase)`**
  Limits each DC line's capacity to the ratings of the converters at its two terminals (`min(line, converter_from, converter_to)`) and records the converter used at each end, so that `build_dc_capacity_map` can also cap lines sharing a converter. Must run before `remap_dc_endpoints!`, while endpoints are still DC terminal names.

- **`remap_dc_endpoints!(dclines_df, converter_map)`**
  Rewrites DC line endpoint bus names in-place: DC cable terminal names are replaced by their adjacent AC substation bus names using the converter map. Endpoints with no converter entry are left unchanged (but stored as cleaned strings, also for integer bus names). This step must run before `rename_buses` so DC terminals are excluded from the Y-bus.

- **`build_dc_capacity_map(dclines_df, node_info, rep_node_ids; lines_df, tielines_df)`**
  Aggregates DC line capacities (in p.u.) by representative-node pair. When AC line data are provided, each DC endpoint is mapped to a representative in its own AC connected component. Same-zone DC lines are skipped only when both endpoints are in the same AC component; same-zone DC bridges between separate AC islands are retained. If the lines carry converter information (from `apply_converter_limits!`), each pair's total is capped, on each side, by the summed rating of the distinct converters it uses. Returns a `Dict{Tuple{Int,Int}, Float64}` keyed by `(min_rep_id, max_rep_id)`. Used for additive TTC contribution in reporting and exported equivalent capacities.

---

## 2. Network Physics and Matrix Construction

These functions construct the mathematical representation of the electrical network.

- **`form_dc_ybus(lines, tielines, nodes, Sbase)`**
  Assembles the lossless DC Laplacian from series reactances only ($b = 1/X$; resistance, charging and shunts are ignored), returned in the complex form $-jB$. This is the matrix used for representative-node selection, PTDFs, TTCs and Kron reduction. AC lines and transformers (after merging) are included; DC interconnectors are excluded. Requires positive, finite `X_pu`.

- **`form_ybus_with_shunt(lines, tielines, nodes, Sbase)`**
  Assembles the full AC bus admittance matrix ($Y_{bus}$), including resistance and line shunt susceptances. Not used by the reduction pipeline (PTDF functions reject it); kept for users who need an AC $Y_{bus}$.

- **`calculate_all_ttc_results(Ybus, lines_df, tie_lines_df; dc_cap_map, transaction_nodes)`**
  Memory-optimised TTC computation for all pairwise transactions between `transaction_nodes` (default: all $\binom{N}{2}$ bus pairs; `main_full_analysis` passes the representative nodes). Factorises the $B$ matrix once, then computes PTDFs and TTC via shared back-solves. DC capacity is added additively using `dc_cap_map`. Supports multi-threaded execution when `CONFIG.parallel_processing = true`. Returns both the TTC DataFrame and a `Dict` of per-pair physical line capacities for downstream use (parallel branches combined by their tightest angle limit, $\sum b \cdot \min C/b$).

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
  - `"auto"`: selects the top `CONFIG.rep_node_k_per_zone` nodes per zone ranked by interconnection degree (line capacity as tiebreaker).
  - `"manual_excel"`: reads the `IsRepresentative` column from the Nodes sheet. Falls back to `"auto"` with a warning if the column is missing or empty.

  In both modes, zones listed in `CONFIG.high_res_zones` are retained at full bus resolution (all buses become representative nodes), and if an AC island is left without any representative, the best-ranked bus in that island is added as a forced representative. Returns `(rep_nodes_df, node_info)`; `rep_nodes_df` has columns `new_id`, `old_name`, `zone`, `area`, `degree`, `total_line_cap` in both modes.

- **`kron_reduce_ybus(Ybus, representative_nodes)`**
  Applies Kron reduction to eliminate internal nodes while preserving sensitivity relationships between representative nodes. If every bus is a representative node, nothing is eliminated and the matrix is returned reordered. Handles multi-island networks by applying small shunt regularisation ($\varepsilon = 10^{-8}$) before inversion to avoid singularity.

- **`filter_reduced_network(Y_kron, rep_node_ids, allowed_pairs)`**
  Removes virtual lines from the Kron-reduced network: a synthetic line is kept only if its `(min, max)` bus-id pair is in `allowed_pairs`. Removed susceptance is also taken out of the diagonal, so the result is a consistent DC Laplacian of the exported network. Compute reduced PTDFs on the returned matrix. Keeps the unfiltered network (with a warning) if no line would survive, and warns when filtering splits the network into separate AC islands. Used by `main_full_analysis` when `CONFIG.allow_virtual_lines = false`.

- **`calculate_ptdfs_reduced(Y_kron, rep_node_ids; high_res_ids)`**
  Calculates PTDFs for the smaller equivalent network using local indices and maps back to original IDs. Cross-island transactions have no AC PTDF rows. Intra-high-res pairs are skipped for mixed-resolution reductions; when every retained bus is high-resolution, all connected transactions are evaluated.

---

## 5. Capacity Optimisation

These functions use mathematical programming to determine synthetic line capacities for the reduced network.

- **`optimise_equivalent_capacities(ttc_original, ptdf_reduced_results; Type, lambda, gamma_C, optimizer_factory, dc_cap_map, high_res_node_ids, phys_line_caps, rep_node_ids, reduced_ybus, solver_diagnostics_path)`**
  Primary interface for solving the capacity fitting problem. Dispatches to `_solve_qp_model`, `_solve_lp_model`, or `_solve_miqp_model` based on `Type`. `QP` provides a fast accuracy/time balance, `LP` constructs a deterministic capacity envelope, and `MIQP` identifies binding synthetic lines with physically consistent capacities. Every synthetic line present in `ptdf_reduced_results` is a candidate, so virtual lines must already have been removed (with `filter_reduced_network`) from the network those PTDFs were computed on. Intra-high-res synthetic lines are fixed to their physical capacity and excluded from optimisation.

  Pass `rep_node_ids` and `reduced_ybus` to include isolated retained buses and preserve synthetic edges absent from the enumerated transactions. The full workflow supplies both. Physical capacities fixed at zero remain zero.

  The returned `TTC_Equivalent_pu` is evaluated from the final capacities as $\min_l C_l/|PTDF_{t,l}|$ plus additive DC capacity. QP's internal fitted TTC variable need not equal this minimum; MIQP additionally enforces a binding-line choice. Every mode is checked from its final capacities.

  Returns a tuple `(equivalent_capacities_df, ttc_equivalent_df)`.

  MIQP minimises squared relative errors with an original-AC-TTC upper bound,
  all binding candidates by default, safe objective screening, a complete
  conservative start and deterministic capacity closure. SCIP is the default;
  `optimizer_factory` or `CONFIG.miqp_optimizer` may select any other installed
  MIQP-capable JuMP optimizer. Optional diagnostics retain the original solve's
  status and gap. `in_calibration` marks transactions subject to the conservative fit.

---

## 6. Workflow and Configuration

These functions and objects control the full end-to-end execution of the model.

- **`main_full_analysis(input_dir, output_dir)`**
  High-level wrapper that executes the complete 11-step network reduction pipeline, from data loading to result export. Creates `output_dir` if it does not exist. Prints a step-by-step timing summary on completion. Returns `nothing`; all results are written to CSV files in `output_dir`.

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
  | `lambda` | Float64 | `1e-6` | QP capacity regularisation |
  | `ptdf_epsilon` | Float64 | `1e-6` | PTDF zero threshold |
  | `suffix` | String | `"QP"` | Suffix for output file names |
  | `miqp_optimizer` | Any | `SCIP.Optimizer` | MIQP optimizer constructor (any MIQP-capable JuMP solver) |
  | `miqp_optimizer_attributes` | Dict | empty | Additional solver-specific attributes |
  | `miqp_binding_candidates_per_txn` | Int | `0` | Zero considers all relevant binding lines; positive enables heuristic pruning |
  | `miqp_safe_binding_screening` | Bool | `true` | Objective-based safe screening |
  | `miqp_gamma_C` | Float64 | `1.0` | Reference capacity-bound multiplier |
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
  | `parallel_processing` | Bool | `false` | Multi-threaded TTC enumeration |

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
| `optimisation.jl` | QP fit, LP capacity envelope, MIQP with relative squared-error fitting, TTC reporting |
| `ptdf-calculations.jl` | DC power flow sensitivity analysis; parallel TTC enumeration |
| `representative-nodes.jl` | Zone grouping, degree-based or manual node selection, high-res zone support |
| `ybus-formation.jl` | Physical matrix assembly ($Y_{bus}$) |
