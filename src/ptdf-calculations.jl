# --- PTDF (Power Transfer Distribution Factor) Calculations ---

"""
    calculate_ptdfs_dc_power_flow(Ybus, from_bus, to_bus)

Calculate PTDF matrix for a specific transaction using DC power flow approximation.
Note: Function signature needs to be corrected - current implementation has parameter mismatches.
"""
function calculate_ptdfs_dc_power_flow(
    Ybus::SparseArrays.SparseMatrixCSC{ComplexF64},
    from_bus::Int,
    to_bus::Int,
)
    N = size(Ybus, 1)

    if from_bus == to_bus
        return zeros(N, N)
    end

    # Use to_bus as slack bus
    slack_bus = to_bus

    # Create susceptance matrix B (negative imaginary part of Ybus)
    B = -LinearAlgebra.imag.(LinearAlgebra.Matrix(Ybus))

    # Remove slack bus row and column
    non_slack_buses = setdiff(1:N, slack_bus)
    B_reduced = B[non_slack_buses, non_slack_buses]

    B_reduced_inv = nothing

    # Calculate inverse of reduced B matrix with proper error handling
    try
        B_reduced_inv = LinearAlgebra.inv(B_reduced)
    catch e
        if isa(e, SingularException)
            @warn "B matrix is singular for transaction $from_bus->$to_bus, using pseudoinverse"
            B_reduced_inv = LinearAlgebra.pinv(B_reduced)
        else
            rethrow(e)
        end
    end

    # Create injection vector: +1 at from_bus, -1 at to_bus (slack)
    injection = zeros(length(non_slack_buses))
    if from_bus != slack_bus
        # Find the index of the 'from' bus within the non_slack_buses list
        from_idx = findfirst(non_slack_buses .== from_bus)
        if isnothing(from_idx)
            error("From bus $from_bus not found in non-slack buses $non_slack_buses")
        end
        injection[from_idx] = 1.0
    end

    # Calculate voltage angles for non-slack buses
    theta_reduced = B_reduced_inv * injection

    # Reconstruct full theta vector (slack bus angle = 0)
    theta_full = zeros(N)
    theta_full[non_slack_buses] = theta_reduced

    # Calculate PTDF matrix
    PTDF_matrix = zeros(N, N)

    # For each possible line (i,j), calculate PTDF
    for i = 1:N
        for j = 1:N
            if i != j && abs(B[i, j]) > 1e-8  # Only consider connected lines
                # PTDF for line i-j is the power flow when 1 pu is injected at from_bus
                PTDF_matrix[i, j] = B[i, j] * (theta_full[i] - theta_full[j])
            end
        end
    end

    return PTDF_matrix
end

"""
    calculate_all_ptdfs_original(Ybus, lines_df, tie_lines_df)

Calculate PTDFs for all canonical transactions (A->B where A < B) in the original network.
Note: Function signature corrected from original implementation.
"""
function calculate_all_ptdfs_original(
    Ybus::SparseArrays.SparseMatrixCSC{ComplexF64},
    lines_df::DataFrames.DataFrame,
    tie_lines_df::DataFrames.DataFrame,
)
    n_buses = size(Ybus, 1)

    all_lines = DataFrames.vcat(lines_df, tie_lines_df, cols = :union)

    line_capacities = Dict{Tuple{Int,Int},Float64}()
    for line in DataFrames.eachrow(all_lines)
        line_capacities[(line.From, line.To)] = line.Capacity_pu
        line_capacities[(line.To, line.From)] = line.Capacity_pu
    end

    transactions = Tuple{Int,Int}[]
    for a = 1:n_buses
        for b = 1:n_buses
            if a < b # Enforce canonical order: a -> b, where a < b
                push!(transactions, (a, b))
            end
        end
    end

    ptdf_results = DataFrames.DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        line_from = Int[],
        line_to = Int[],
        PTDF_value = Float64[],
    )

    total_transactions = length(transactions)
    println(
        "Calculating PTDFs for $total_transactions canonical transactions in the ORIGINAL network...",
    )

    progress_step = max(1, floor(Int, total_transactions / 20))
    start_time = time()

    for (idx, (a, b)) in enumerate(transactions)
        if idx % progress_step == 0 || idx == total_transactions
            elapsed = time() - start_time
            rate = idx / elapsed
            remaining_time = (total_transactions - idx) / rate
            # println("Processing transaction $idx/$total_transactions: $a -> $b. Est. remaining: $(round(remaining_time, digits=1)) s")
        end

        # PTDF is calculated for A -> B
        PTDF_matrix = calculate_ptdfs_dc_power_flow(Ybus, a, b)

        for (line_from, line_to) in keys(line_capacities)
            ptdf_value = PTDF_matrix[line_from, line_to]
            push!(ptdf_results, (a, b, line_from, line_to, ptdf_value))
        end
    end

    return ptdf_results, line_capacities
end

"""
    calculate_ptdfs_reduced(Y_kron, rep_node_ids)

Calculate PTDFs for canonical transactions between representative nodes using Kron-reduced matrix.
"""
function calculate_ptdfs_reduced(
    Y_kron::SparseArrays.SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int},
)
    N_R = size(Y_kron, 1)

    reduced_transactions = Tuple{Int,Int}[]
    for a_r = 1:N_R
        for b_r = 1:N_R
            a_orig = rep_node_ids[a_r]
            b_orig = rep_node_ids[b_r]

            # Enforce canonical order using ORIGINAL IDs for consistency
            if a_orig < b_orig
                push!(reduced_transactions, (a_r, b_r))
            end
        end
    end

    ptdf_reduced_results = DataFrames.DataFrame(
        transaction_from_reduced = Int[],
        transaction_to_reduced = Int[],
        transaction_from_orig = Int[],
        transaction_to_orig = Int[],
        synth_line_from = Int[],
        synth_line_to = Int[],
        PTDF_value = Float64[],
    )

    println(
        "Calculating PTDFs for $(length(reduced_transactions)) canonical reduced transactions...",
    )

    for (a_r, b_r) in reduced_transactions
        # This function uses the *reduced* Ybus and *reduced* bus IDs (1 to N_R)
        # We calculate PTDF for A_R -> B_R
        PTDF_matrix = calculate_ptdfs_dc_power_flow(Y_kron, a_r, b_r)

        for i_r = 1:N_R
            for j_r = 1:N_R
                # Only consider synthetic lines with a non-zero susceptance component
                if i_r != j_r && abs(-LinearAlgebra.imag(Y_kron[i_r, j_r])) > 1e-8
                    ptdf_value = PTDF_matrix[i_r, j_r]

                    # Map reduced indices back to original IDs for tracking
                    a_orig = rep_node_ids[a_r]
                    b_orig = rep_node_ids[b_r]
                    i_orig = rep_node_ids[i_r]
                    j_orig = rep_node_ids[j_r]

                    push!(
                        ptdf_reduced_results,
                        (a_r, b_r, a_orig, b_orig, i_orig, j_orig, ptdf_value),
                    )
                end
            end
        end
    end

    println("Reduced PTDF calculation complete.")
    return ptdf_reduced_results
end
