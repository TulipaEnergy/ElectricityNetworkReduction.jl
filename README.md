# ElectricityNetworkReduction

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://TulipaEnergy.github.io/ElectricityNetworkReduction.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://TulipaEnergy.github.io/ElectricityNetworkReduction.jl/dev)
[![Test workflow status](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/TulipaEnergy/ElectricityNetworkReduction.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/TulipaEnergy/ElectricityNetworkReduction.jl)
[![Lint workflow Status](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Lint.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Lint.yml?query=branch%3Amain)
[![Docs workflow Status](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Docs.yml/badge.svg?branch=main)](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/actions/workflows/Docs.yml?query=branch%3Amain)
[![DOI](https://zenodo.org/badge/DOI/FIXME)](https://doi.org/FIXME)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![All Contributors](https://img.shields.io/github/all-contributors/TulipaEnergy/ElectricityNetworkReduction.jl?labelColor=5e1ec7&color=c0ffee&style=flat-square)](#contributors)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)

**ElectricityNetworkReduction.jl** is a Julia package for **power system network reduction** based on **PTDF-preserving Kron reduction** and **optimization-based equivalent capacity estimation**.

It is a package for simplifying detailed electrical networks into compact equivalents without losing the transfer characteristics. Starting from raw data, it selects representative nodes, performs Kron reduction, and optimizes synthetic line capacities.

## How to Cite

If you use ElectricityNetworkReduction.jl in your work, please cite using the reference given in [CITATION.cff](https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/blob/main/CITATION.cff).

## Installation

```julia-pkg
pkg> add ElectricityNetworkReduction
```

See the [documentation](https://tulipaenergy.github.io/ElectricityNetworkReduction.jl/dev/) for details on the model and the package.

## Contributing

If you want to make contributions of any kind, please first that a look into our contributing guide directly on GitHub or the contributing page on the website.

## License

This content is released under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) License.

---

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/g-moralesespana"><img src="https://avatars.githubusercontent.com/u/42405171?v=4?s=100" width="100px;" alt="Germán Morales"/><br /><sub><b>Germán Morales</b></sub></a><br /><a href="#research-g-moralesespana" title="Research">🔬</a> <a href="#ideas-g-moralesespana" title="Ideas, Planning, & Feedback">🤔</a> <a href="#fundingFinding-g-moralesespana" title="Funding Finding">🔍</a> <a href="#projectManagement-g-moralesespana" title="Project Management">📆</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/gnawin"><img src="https://avatars.githubusercontent.com/u/125902905?v=4?s=100" width="100px;" alt="Ni Wang"/><br /><sub><b>Ni Wang</b></sub></a><br /><a href="#code-gnawin" title="Code">💻</a> <a href="#review-gnawin" title="Reviewed Pull Requests">👀</a> <a href="#projectManagement-gnawin" title="Project Management">📆</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/MNuman07"><img src="https://avatars.githubusercontent.com/u/191888232?v=4?s=100" width="100px;" alt="Muhammad Numan"/><br /><sub><b>Muhammad Numan</b></sub></a><br /><a href="#research-MNuman07" title="Research">🔬</a> <a href="#ideas-MNuman07" title="Ideas, Planning, & Feedback">🤔</a> <a href="#code-MNuman07" title="Code">💻</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/juan-giraldo-ch"><img src="https://avatars.githubusercontent.com/u/56868578?v=4?s=100" width="100px;" alt="juan-giraldo-ch"/><br /><sub><b>juan-giraldo-ch</b></sub></a><br /><a href="#research-juan-giraldo-ch" title="Research">🔬</a> <a href="#ideas-juan-giraldo-ch" title="Ideas, Planning, & Feedback">🤔</a></td>
    </tr>
  </tbody>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
