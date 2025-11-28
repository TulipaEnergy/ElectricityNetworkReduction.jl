```@meta
CurrentModule = NetworkReduction
```

# NetworkReduction

NetworkReduction.jl is a package for converting large, detailed eletricity grids into compact equivalents that retain the Total Transfer Capacity (TTC) and Power Transfer Distribution Factors (PTDF) characteristics in energy system analysis. The package ingests raw network data (topolgy, capacity, and other electrical properties), cleans the data, identifies representative nodes, performs Kron reduction, and solves an optimization problem to derive equivalent line capacities that mimic the behaviour of the full network. The result is a reduced model you can use for studies, validation, and optimization workflows.

## Workflow at a glance

1. **Load & clean data** – Read the raw data, remove invalid entries, assign consistent IDs, and convert everything to per-unit values.
2. **Analyse the original grid** – Build the Y-bus, compute PTDF matrices for canonical transactions, and derive TTC limits using the original line capacities.
3. **Select representative nodes** – Group buses by zone/area, then keep the nodes with the highest electrical degree to serve as the reduced network boundary.
4. **Kron reduction & reduced PTDFs** – Eliminate non-representative nodes while preserving admittance relationships, and recompute PTDFs on the reduced system.
5. **Optimize equivalent capacities** – Solve a quadratic program (via JuMP+Ipopt) to find synthetic line capacities that reproduce the canonical TTC limits within tolerance.
6. **Compare & export** – Generate CSV reports (bus maps, TTC comparison, PTDF/RN results, equivalent capacities) so you can inspect or downstream the reduced model.

## Getting started

```julia
using NetworkReduction

input_dir = "/path/to/case"
output_dir = joinpath(input_dir, "results")
mkpath(output_dir)

main_full_analysis(input_dir, output_dir)
```

## Contributors

```@raw html
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
```
