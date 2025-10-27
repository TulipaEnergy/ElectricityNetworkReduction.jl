# --- OPTIMIZATION FUNCTIONS ---

"""
    optimize_equivalent_capacities_qp(ttc_original, ptdf_reduced_results)

Optimize equivalent capacities for the reduced network using Quadratic Programming.

This function solves an optimization problem to find synthetic line capacities
for the reduced network that best match the original network's TTC values.

# Arguments
- `ttc_original::DataFrames.DataFrame`: Original network TTC values
- `ptdf_reduced_results::DataFrames.DataFrame`: PTDF results from reduced network

# Returns
- `equivalent_capacities::DataFrames.DataFrame`: Optimized synthetic line capacities

# Mathematical Formulation
Minimize: Σ(TTC_eq[t] - TTC_orig[t])² + λ*Σ(C_eq[l]²)
Subject to: TTC_eq[t] ≤ C_eq[l] / |PTDF[t,l]| for all transactions t and lines l
"""
function optimize_equivalent_capacities_qp(
    ttc_original::DataFrames.DataFrame,
    ptdf_reduced_results::DataFrames.DataFrame,
)
    println("\n--- OPTIMIZING EQUIVALENT CAPACITIES (QP Approach) ---")

    # Data preparation
    synth_lines_df =
        DataFrames.unique(ptdf_reduced_results, [:synth_line_from, :synth_line_to])
    synth_lines = Tuple{Int,Int}[]
    synth_line_map = Dict{Tuple{Int,Int},Int}()
    for (idx, row) in enumerate(DataFrames.eachrow(synth_lines_df))
        i, j = row.synth_line_from, row.synth_line_to
        line_key = (min(i, j), max(i, j))
        if !(line_key in synth_lines)
            push!(synth_lines, line_key)
            synth_line_map[line_key] = length(synth_lines)
        end
    end
    num_synth_lines = length(synth_lines)

    # Filter to only canonical RN-to-RN transactions
    rn_orig_ids = DataFrames.unique(
        DataFrames.vcat(
            ptdf_reduced_results.transaction_from_orig,
            ptdf_reduced_results.transaction_to_orig,
        ),
    )
    ttc_canonical_rn = DataFrames.filter(
        row ->
            (row.transaction_from in rn_orig_ids) &&
                (row.transaction_to in rn_orig_ids) &&
                (row.transaction_from < row.transaction_to),
        ttc_original,
    )

    ttc_transactions = Tuple{Int,Int}[]
    ttc_orig_values = Float64[]
    txn_map = Dict{Int,DataFrames.DataFrame}()

    for (t_idx, row) in enumerate(DataFrames.eachrow(ttc_canonical_rn))
        a_orig, b_orig = row.transaction_from, row.transaction_to
        push!(ttc_transactions, (a_orig, b_orig))
        push!(ttc_orig_values, row.TTC_pu)

        txn_group = DataFrames.filter(
            r -> (r.transaction_from_orig == a_orig && r.transaction_to_orig == b_orig),
            ptdf_reduced_results,
        )
        DataFrames.transform!(
            txn_group,
            [:synth_line_from, :synth_line_to] =>
                DataFrames.ByRow(
                    (i, j) -> get(synth_line_map, (min(i, j), max(i, j)), 0),
                ) => :l_idx,
        )
        DataFrames.transform!(txn_group, :PTDF_value => DataFrames.ByRow(abs) => :PTDF_abs)
        txn_map[t_idx] = txn_group
    end

    num_txns = length(ttc_transactions)
    println("Optimizing for $num_synth_lines equivalent synthetic line capacities.")
    println("Using $num_txns canonical TTC values for matching.")

    # --- QP MODEL ---
    model = JuMP.Model(Ipopt.Optimizer)  # Using Ipopt for QP
    JuMP.set_silent(model)

    # Variables
    JuMP.@variable(model, C_eq[l = 1:num_synth_lines] >= 1e-4)      # Equivalent capacities
    JuMP.@variable(model, TTC_eq[t = 1:num_txns] >= 1e-4)           # Equivalent TTCs
    JuMP.@variable(model, V_mismatch[t = 1:num_txns])               # Mismatch variables

    # Objective: Minimize sum of squared mismatches + small regularization
    JuMP.@objective(
        model,
        Min,
        sum(V_mismatch[t]^2 for t = 1:num_txns) +
        0.001 * sum(C_eq[l]^2 for l = 1:num_synth_lines)    # Regularization to prevent extreme values
    )

    # Constraint: Define mismatch
    JuMP.@constraint(
        model,
        [t = 1:num_txns],
        V_mismatch[t] == TTC_eq[t] - ttc_orig_values[t]
    )

    # Key constraint: TTC cannot exceed capacity/PTDF for any line
    for t = 1:num_txns
        for row in DataFrames.eachrow(txn_map[t])
            l_idx = row.l_idx
            ptdf_abs = max(row.PTDF_abs, 1e-8)  # Avoid division by zero

            JuMP.@constraint(model, TTC_eq[t] <= C_eq[l_idx] / ptdf_abs + 1e-6)
        end
    end

    # Solve the problem
    JuMP.optimize!(model)

    status = JuMP.termination_status(model)
    println("QP Optimization status: $status")

    if status == MathOptInterface.OPTIMAL || status == MathOptInterface.LOCALLY_SOLVED
        C_eq_values = JuMP.value.(C_eq)
        TTC_eq_values = JuMP.value.(TTC_eq)

        # Create output DataFrame
        equivalent_capacities = DataFrames.DataFrame(
            synth_line_from = Int[],
            synth_line_to = Int[],
            C_eq_pu = Float64[],
        )

        for (idx, line) in enumerate(synth_lines)
            push!(equivalent_capacities, (line..., C_eq_values[idx]))
        end

        println("QP Optimization successful!")
        println("C_eq range: [$(minimum(C_eq_values)), $(maximum(C_eq_values))]")

        # Calculate and display matching accuracy
        mismatches = TTC_eq_values .- ttc_orig_values
        max_abs_error = maximum(abs.(mismatches))
        avg_abs_error = Statistics.mean(abs.(mismatches))
        rms_error = sqrt(Statistics.mean(mismatches .^ 2))

        println("TTC Matching Accuracy:")
        println("  Max Absolute Error: $(round(max_abs_error, digits=6)) pu")
        println("  Average Absolute Error: $(round(avg_abs_error, digits=6)) pu")
        println("  RMS Error: $(round(rms_error, digits=6)) pu")

        # Show a few examples
        println("\nSample TTC Comparisons (Original vs Equivalent):")
        for t = 1:min(5, num_txns)
            error_pct = 100 * (TTC_eq_values[t] - ttc_orig_values[t]) / ttc_orig_values[t]
            println(
                "  Txn $t: $(round(ttc_orig_values[t], digits=4)) -> $(round(TTC_eq_values[t], digits=4)) ($(round(error_pct, digits=2))%)",
            )
        end

        return equivalent_capacities
    else
        @error "QP Optimization failed: $status"
        @error "Raw status: $(JuMP.raw_status(model))"
        return nothing
    end
end

"""
    debug_optimization_data(ttc_original, ptdf_reduced_results)

Debug function to analyze optimization input data and identify potential issues.
Prints statistics about TTC values, PTDF values, transactions, and synthetic lines.
"""
function debug_optimization_data(ttc_original, ptdf_reduced_results)
    println("\n=== DEBUGGING OPTIMIZATION DATA ===")

    # Check TTC data
    println("TTC Original Data:")
    println("Number of transactions: $(DataFrames.nrow(ttc_original))")
    println("TTC range: [$(minimum(ttc_original.TTC_pu)), $(maximum(ttc_original.TTC_pu))]")

    # Check PTDF data
    println("\nPTDF Reduced Data:")
    println("Number of PTDF entries: $(DataFrames.nrow(ptdf_reduced_results))")
    println(
        "PTDF range: [$(minimum(ptdf_reduced_results.PTDF_value)), $(maximum(ptdf_reduced_results.PTDF_value))]",
    )

    # Check transaction coverage
    transactions = DataFrames.unique(
        ptdf_reduced_results[:, [:transaction_from_orig, :transaction_to_orig]],
    )
    println("Unique transactions in PTDF: $(DataFrames.nrow(transactions))")

    # Check synthetic lines
    synth_lines =
        DataFrames.unique(ptdf_reduced_results[:, [:synth_line_from, :synth_line_to]])
    println("Synthetic lines: $(DataFrames.nrow(synth_lines))")

    # Analyze PTDF values per transaction
    println("\nFirst 3 transactions PTDF analysis:")
    for txn in DataFrames.eachrow(transactions[1:min(3, DataFrames.nrow(transactions)), :])
        a, b = txn.transaction_from_orig, txn.transaction_to_orig
        txn_ptdfs = DataFrames.filter(
            r -> r.transaction_from_orig == a && r.transaction_to_orig == b,
            ptdf_reduced_results,
        )
        println("Transaction $a -> $b: $(DataFrames.nrow(txn_ptdfs)) lines")
        println(
            "  PTDF range: [$(minimum(txn_ptdfs.PTDF_value)), $(maximum(txn_ptdfs.PTDF_value))]",
        )
    end

    println("=== END DEBUGGING ===\n")
end
