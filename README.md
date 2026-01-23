# NetworkReduction

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://TulipaEnergy.github.io/NetworkReduction.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://TulipaEnergy.github.io/NetworkReduction.jl/dev)
[![Test workflow status](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/TulipaEnergy/NetworkReduction.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/TulipaEnergy/NetworkReduction.jl)
[![Lint workflow Status](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/NetworkReduction.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![DOI](https://zenodo.org/badge/DOI/FIXME)](https://doi.org/FIXME)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![All Contributors](https://img.shields.io/github/all-contributors/TulipaEnergy/NetworkReduction.jl?labelColor=5e1ec7&color=c0ffee&style=flat-square)](#contributors)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

**NetworkReduction.jl** is a Julia package for **power system network reduction** based on **PTDF-preserving Kron reduction** and **optimization-based equivalent capacity estimation**.

It is a package for simplifying detailed electrical networks into compact equivalents without losing the transfer characteristics. Starting from raw data, it selects representative nodes, performs Kron reduction, and optimizes synthetic line capacities.

---

## Core Workflow

1. Load transmission network data (Excel format)
2. Build admittance matrix (Ybus) with shunt elements
3. Compute **PTDF** (Power Transfer Distribution Factors) for all canonical transactions (A → B with A < B)
4. Calculate **Total Transfer Capacity (TTC)** per transaction pair using PTDF + line ratings
5. Select one **representative node** per zone (highest degree bus)
6. Perform **Kron reduction** → obtain reduced Ybus between representative nodes
7. Compute PTDFs in the reduced (equivalent) network
8. **Optimize synthetic line capacities** so that TTC values in the reduced network match the original as closely as possible
   → using QP (default), MIQP or LP formulations
9. Export results (including comparison tables and error statistics)

---

## Features

- Sparse-matrix PTDF computation using single-injection technique (fast)
- Canonical transaction ordering (from < to)
- Kron reduction with numerical stability fallback (`pinv` when submatrix is singular)
- Three optimization strategies for equivalent capacities:
  - **QP** — least-squares matching + L₂ regularization (recommended default)
  - **MIQP** — mixed-integer quadratic (exactly one binding constraint per transaction)
  - **LP** — maximize total TTC subject to original TTC upper bounds
- Basic test suite checking output file existence, schema and non-negativity

---

## Package Structure

```text
├── src/
│   ├── NetworkReduction.jl      # Main module file
│   ├── config.jl                # Configuration settings
│   ├── data-loading.jl          # Data loading and cleaning
│   ├── ybus-formation.jl        # Y-bus matrix formation
│   ├── ptdf-calculations.jl     # PTDF calculations
│   ├── ttc-calculations.jl      # TTC calculations
│   ├── representative-nodes.jl  # Representative node selection
│   ├── kron-reduction.jl        # Kron reduction implementation
│   ├── optimization.jl          # Capacity optimization
│   ├── export-functions.jl      # Export utilities
│   └── main-analysis.jl         # Main workflow
├── test/
│   ├── run-tests.jl             # Test runner
│   └── test-case-studies.jl     # Test cases
└── README.md                    # This file
```

---

## Installation

Install the package directly from GitHub:

using Pkg
Pkg.add(url = "<https://github.com/TulipaEnergy/NetworkReduction.jl.git>")

To ensure all necessary dependencies are installed in your environment:

using Pkg
Pkg.instantiate()

Solvers

- The model uses JuMP for optimization.

- Ipopt: Used by default for QP and LP problems.

- CPLEX: Required if you choose to use the MIQP optimization type.

Then:
using NetworkReduction

---

## Configuration

The package behavior is controlled via a central Config struct. You can modify these values globally using NetworkReduction.CONFIG:

### Available configuration options

```text
CONFIG.input_filename = "case118.xlsx"       # Input Excel file name
CONFIG.case_study = "case118"                # Case study identifier
CONFIG.bus_names_as_int = false              # Bus names are strings (not integers)
CONFIG.in_pu = false                         # Line parameters are in ohms (not per-unit)
CONFIG.base = 100.0                          # MVA base for per-unit conversion
CONFIG.optimization_type = "QP"              # "MIQP", "QP", or "LP"
CONFIG.lambda = 1e-6                         # Regularization parameter
CONFIG.ptdf_epsilon = 0.001                  # PTDF zero threshold
CONFIG.suffix = "QP"                         # Output file suffix
```

---

## Quick Start – Full Analysis

using NetworkReduction

### Customize configuration

```text
CONFIG.input_filename    = "case118.xlsx"
CONFIG.case_study        = "case118"
CONFIG.base              = 100.0                # MVA
CONFIG.in_pu             = false                # R/X/B already in pu?
CONFIG.optimization_type = "QP"                 # "QP", "MIQP", "LP"
CONFIG.lambda            = 5e-6                 # regularization
CONFIG.suffix            = "QP"                 # filename suffix

input_dir  = joinpath(@__DIR__, "data", "input", CONFIG.case_study)
output_dir = joinpath(@__DIR__, "results", CONFIG.case_study)
```

#### Run everything

ptdf_original,
ttc_original,
ptdf_reduced,
equivalent_capacities,
ttc_equivalent = main_full_analysis(input_dir, output_dir)

After execution you should find (in output_dir):

- Bus_ID_Map_QP.csv
- Line_Details_QP.csv
- Representative_Nodes_QP.csv
- TTC_Original_Network_QP.csv
- PTDF_Reduced_Network_QP.csv
- Equivalent_Capacities_QP.csv
- TTC_Comparison_QP.csv

## Limitations & Notes

- Only DC power flow approximation (linear, lossless)
- Kron reduction can be numerically sensitive on large ill-conditioned systems (uses pinv fallback)
- MIQP formulation scales poorly — use only for small/medium networks
- Lines are assumed undirected (same rating both directions)
- No N-1 security / contingency consideration

## How to Cite

If you use NetworkReduction.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/TulipaEnergy/NetworkReduction.jl/blob/main/CITATION.cff).

## Contributing

If you want to make contributions of any kind, please first that a look into our [contributing guide directly on GitHub] or the [contributing page on the website]

---

### Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
