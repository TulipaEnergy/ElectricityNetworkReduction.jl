using ElectricityNetworkReduction
using Documenter

DocMeta.setdocmeta!(
    ElectricityNetworkReduction,
    :DocTestSetup,
    :(using ElectricityNetworkReduction);
    recursive = true,
)

makedocs(;
    modules = [ElectricityNetworkReduction],
    authors = "Germán Morales-España <german.morales@tno.nl>, Juan Giraldo Chavarriaga <juan.giraldo@tno.nl>, Muhammad Numan <muhammad.numan@ucd.ie>, Ni Wang <ni.wang@tno.nl>",
    repo = "https://github.com/TulipaEnergy/ElectricityNetworkReduction.jl/blob/{commit}{path}#{line}",
    sitename = "ElectricityNetworkReduction.jl",
    format = Documenter.HTML(;
        canonical = "https://TulipaEnergy.github.io/ElectricityNetworkReduction.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Introduction" => "01-introduction.md",
        "Mathematical Formulation" => "02-mathematical-formulation.md",
        "Model Usage" => "03-model-usage.md",
        "API Reference" => "04-api.md",
        "Contributing Guidelines" => "05-contributing.md",
    ],
)

deploydocs(; repo = "github.com/TulipaEnergy/ElectricityNetworkReduction.jl")
