# --- TTC (Total Transfer Capacity) Calculations ---

"""
    calculate_ttc_from_ptdfs(ptdf_df, line_capacities)

Calculate the Total Transfer Capacity (TTC) for every canonical transaction (A < B).
Returns DataFrame with TTC values and limiting line information.
"""
function calculate_ttc_from_ptdfs(
    ptdf_df::DataFrames.DataFrame,
    line_capacities::Dict{Tuple{Int,Int},Float64},
)
    ttc_results = DataFrames.DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        TTC_pu = Float64[],
        limiting_line_from = Int[],
        limiting_line_to = Int[],
    )

    # We only process transactions where 'transaction_from' < 'transaction_to'
    canonical_ptdf_df =
        DataFrames.filter(row -> row.transaction_from < row.transaction_to, ptdf_df)
    grouped_transactions =
        DataFrames.groupby(canonical_ptdf_df, [:transaction_from, :transaction_to])

    println(
        "\nCalculating TTC for $(length(grouped_transactions)) canonical potential transactions...",
    )

    for (key, group) in pairs(grouped_transactions)

        a = key.transaction_from
        b = key.transaction_to

        min_ttc = Inf
        limiting_line = (0, 0)

        # The group already represents the A->B transaction PTDFs
        for row in DataFrames.eachrow(group)
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

"""
    calculate_ttc_equivalent(ptdf_reduced, eq_capacities)

Calculate TTC for canonical RN-to-RN transactions using the reduced network's
PTDFs and optimized equivalent capacities.
"""
function calculate_ttc_equivalent(
    ptdf_reduced::DataFrames.DataFrame,
    eq_capacities::DataFrames.DataFrame,
)
    # 1. Prepare capacity lookup (using canonical line order: min(i, j), max(i, j))
    eq_cap_map = Dict{Tuple{Int,Int},Float64}()
    for row in DataFrames.eachrow(eq_capacities)
        i, j = row.synth_line_from, row.synth_line_to
        cap = row.C_eq_pu
        eq_cap_map[(min(i, j), max(i, j))] = cap
    end

    # 2. Identify unique RN-to-RN transactions (using original IDs) that are CANONICAL (A < B)
    transactions = DataFrames.filter(
        row -> row.transaction_from_orig < row.transaction_to_orig,
        DataFrames.unique(ptdf_reduced, [:transaction_from_orig, :transaction_to_orig]),
    )

    ttc_equivalent_results = DataFrames.DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        TTC_Equivalent_pu = Float64[],
        limiting_synth_line_from = Int[],
        limiting_synth_line_to = Int[],
    )

    # 3. Calculate TTC for each canonical transaction (A -> B)
    for row in DataFrames.eachrow(transactions)
        a_orig, b_orig = row.transaction_from_orig, row.transaction_to_orig

        # We only process A -> B if A < B (already filtered, but an extra safety check)
        if a_orig >= b_orig
            continue
        end

        min_ttc_eq = Inf
        limiting_line = (0, 0)

        # Filter all reduced PTDFs relevant to this A -> B transaction
        txn_ptdfs = DataFrames.filter(
            r -> (r.transaction_from_orig == a_orig && r.transaction_to_orig == b_orig),
            ptdf_reduced,
        )

        for ptdf_row in DataFrames.eachrow(txn_ptdfs)
            line_from = ptdf_row.synth_line_from
            line_to = ptdf_row.synth_line_to
            ptdf = ptdf_row.PTDF_value

            if abs(ptdf) < 1e-6
                continue
            end

            # Look up capacity using canonical order
            line_key = (min(line_from, line_to), max(line_from, line_to))
            capacity = get(eq_cap_map, line_key, 0.0)

            # TTC_eq = C_eq / |PTDF_reduced|
            ttc_candidate = capacity / abs(ptdf)

            if ttc_candidate < min_ttc_eq
                min_ttc_eq = ttc_candidate
                limiting_line = (line_from, line_to)
            end
        end

        if min_ttc_eq != Inf
            push!(ttc_equivalent_results, (a_orig, b_orig, min_ttc_eq, limiting_line...))
        end
    end

    println("Equivalent TTC calculation complete for canonical RN-to-RN transactions.")
    return ttc_equivalent_results
end
