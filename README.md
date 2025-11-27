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

NetworkReduction.jl is a package for simplifying detailed electrical networks into compact equivalents without losing the transfer characteristics. Starting from raw data, it selects representative nodes, performs Kron reduction, and optimizes synthetic line capacities.

Key capabilities:

- Automates the end-to-end workflow: data ingestion, Total Transfer Capacity (TTC)/Power Transfer Distribution Factors (PTDF) analysis, representative-node selection, Kron reduction, and optimization.
- Validate results (`Equivalent_Capacities_QP.csv`, `TTC_Comparison_QP.csv`, etc.) for the Netherlands Case Study.

## How to Cite

If you use NetworkReduction.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/TulipaEnergy/NetworkReduction.jl/blob/main/CITATION.cff).

## Contributing

If you want to make contributions of any kind, please first that a look into our [contributing guide directly on GitHub](docs/src/90-contributing.md) or the [contributing page on the website](https://TulipaEnergy.github.io/NetworkReduction.jl/dev/90-contributing/)

---

### Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
