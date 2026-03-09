# --- TTC (Total Transfer Capacity) Calculations ---

"""
    calculate_ttc_from_ptdfs(ptdf_df, line_capacities)

Calculate the Total Transfer Capacity (TTC) for every canonical transaction (A < B).
Returns DataFrame with TTC values and limiting line information.
"""
function calculate_ttc_from_ptdfs(
    ptdf_df::DataFrame,
    line_capacities::Dict{Tuple{Int,Int},Float64},
)
    ttc_results = DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        TTC_pu = Float64[],
        limiting_line_from = Int[],
        limiting_line_to = Int[],
    )

    # TTC is symmetric (DC assumption): TTC(a→b) = TTC(b→a), so only compute canonical pairs (a < b)
    canonical_ptdf_df = filter(row -> row.transaction_from < row.transaction_to, ptdf_df)
    grouped_transactions = groupby(canonical_ptdf_df, [:transaction_from, :transaction_to])

    println(
        "\nCalculating TTC for $(length(grouped_transactions)) canonical potential transactions...",
    )

    for (key, group) in pairs(grouped_transactions)

        a = key.transaction_from
        b = key.transaction_to

        min_ttc = Inf
        limiting_line = (0, 0)

        # The group already represents the A->B transaction PTDFs
        for row in eachrow(group)
            line_from = row.line_from
            line_to = row.line_to
            ptdf = row.PTDF_value

            if abs(ptdf) < 1e-6
                continue
            end

            line_key = (line_from, line_to)
            capacity = get(line_capacities, line_key, 0.0)

            # TTC_candidate = Capacity / |PTDF_A->B|
            ttc_candidate = capacity / abs(ptdf)

            if ttc_candidate < min_ttc
                min_ttc = ttc_candidate
                limiting_line = (line_from, line_to)
            end
        end

        push!(ttc_results, (a, b, min_ttc, limiting_line...))
    end

    println("Original TTC calculation complete.")
    return ttc_results
end
