using NetworkReduction
using Documenter

DocMeta.setdocmeta!(
    NetworkReduction,
    :DocTestSetup,
    :(using NetworkReduction);
    recursive = true,
)

const page_rename = Dict("developer.md" => "Developer docs") # Without the numbers
const numbered_pages = [
    file for file in readdir(joinpath(@__DIR__, "src")) if
    file != "index.md" && splitext(file)[2] == ".md"
]

makedocs(;
    modules = [NetworkReduction],
    authors = "Germán Morales-España <german.morales@tno.nl>, Juan Giraldo Chavarriaga <juan.giraldo@tno.nl>, Muhammad Numan <muhammad.numan@ucd.ie>, Ni Wang <ni.wang@tno.nl>",
    repo = "https://github.com/TulipaEnergy/NetworkReduction.jl/blob/{commit}{path}#{line}",
    sitename = "NetworkReduction.jl",
    format = Documenter.HTML(;
        canonical = "https://TulipaEnergy.github.io/NetworkReduction.jl",
    ),
    pages = ["index.md"; numbered_pages],
)

deploydocs(; repo = "github.com/TulipaEnergy/NetworkReduction.jl")
