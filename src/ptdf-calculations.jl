# --- PTDF (Power Transfer Distribution Factor) Calculations ---

"""
    calculate_ptdfs_dc_power_flow(Ybus, from_bus, to_bus)

Calculate PTDF matrix for a specific transaction using DC power flow approximation.
Optimized version using matrix method for single reference slack.
"""
function calculate_ptdfs_dc_power_flow(
    Ybus::SparseMatrixCSC{ComplexF64},
    from_bus::Int,
    to_bus::Int,
    reference_slack::Int = 1,  # Fixed reference slack for all calculations
)
    N = size(Ybus, 1)

    if from_bus == to_bus
        return spzeros(N, N)
    end

    # Use fixed reference slack bus (not to_bus)
    slack_bus = reference_slack

    # Susceptance matrix B = -Imag(Ybus), keep sparse
    B = -imag.(Ybus) |> sparse

    # Non-slack buses
    non_slack_buses = collect(setdiff(1:N, slack_bus))

    # Reduced B matrix (sparse)
    B_reduced = B[non_slack_buses, non_slack_buses]

    # Create TWO injection vectors: one for from_bus, one for to_bus
    injection_from = zeros(length(non_slack_buses))
    injection_to = zeros(length(non_slack_buses))

    # Map bus indices to reduced indices
    bus_to_reduced = Dict{Int,Int}()
    for (idx, bus) in enumerate(non_slack_buses)
        bus_to_reduced[bus] = idx
    end

    # Set up injection for from_bus (+1)
    if from_bus != slack_bus && haskey(bus_to_reduced, from_bus)
        injection_from[bus_to_reduced[from_bus]] = 1.0
    end

    # Set up injection for to_bus (+1, but we'll subtract)
    if to_bus != slack_bus && haskey(bus_to_reduced, to_bus)
        injection_to[bus_to_reduced[to_bus]] = 1.0
    end

    # Solve B_reduced * θ = injection using backslash
    theta_from_reduced = B_reduced \ injection_from
    theta_to_reduced = B_reduced \ injection_to

    # Reconstruct full theta vectors (slack angle = 0)
    theta_from_full = zeros(N)
    theta_to_full = zeros(N)
    theta_from_full[non_slack_buses] .= theta_from_reduced
    theta_to_full[non_slack_buses] .= theta_to_reduced

    # PTDF matrix for transaction from_bus -> to_bus
    # PTDF = PTDF(from) - PTDF(to)
    PTDF_matrix = spzeros(N, N)

    # Compute PTDF only on existing lines (nonzeros of B)
    rows, cols, vals = findnz(B)

    for k in eachindex(vals)
        i = rows[k]
        j = cols[k]
        if i != j
            # PTDF_ij^{from->to} = b_ij * [(θ_i_from - θ_j_from) - (θ_i_to - θ_j_to)]
            flow_from = vals[k] * (theta_from_full[i] - theta_from_full[j])
            flow_to = vals[k] * (theta_to_full[i] - theta_to_full[j])
            PTDF_matrix[i, j] = flow_from - flow_to
        end
    end

    return PTDF_matrix
end

"""
    calculate_single_injection_ptdfs(Ybus, reference_bus)

Calculate PTDFs for single unit injections at each bus relative to reference bus.
Returns Dict of PTDF vectors for each bus injection.
"""
function calculate_single_injection_ptdfs(
    Ybus::SparseMatrixCSC{ComplexF64},
    reference_bus::Int = 1,
)
    N = size(Ybus, 1)
    B = -imag.(Ybus) |> sparse

    # Non-reference buses
    non_ref_buses = collect(setdiff(1:N, reference_bus))

    # Reduced B matrix
    B_reduced = B[non_ref_buses, non_ref_buses]

    # Factorize once for efficiency
    B_reduced_fact = lu(B_reduced)

    # Get all transmission lines
    lines = Vector{Tuple{Int,Int,Float64}}()
    rows, cols, vals = findnz(B)
    for k in eachindex(vals)
        i, j, b = rows[k], cols[k], vals[k]
        if i != j
            push!(lines, (i, j, b))
        end
    end
    num_lines = length(lines)

    # Create mapping from bus to reduced index
    bus_to_reduced = Dict{Int,Int}()
    for (idx, bus) in enumerate(non_ref_buses)
        bus_to_reduced[bus] = idx
    end

    # Pre-allocate results dictionary
    ptdf_single_injection = Dict{Int,Vector{Float64}}()

    # PTDF for injection at reference bus is always 0
    ptdf_single_injection[reference_bus] = zeros(num_lines)

    # Calculate for each non-reference bus
    for bus in non_ref_buses
        # Create unit injection vector at this bus
        e_k = zeros(length(non_ref_buses))
        e_k[bus_to_reduced[bus]] = 1.0

        # Solve for voltage angles
        theta_reduced = B_reduced_fact \ e_k

        # Reconstruct full theta vector
        theta_full = zeros(N)
        theta_full[non_ref_buses] .= theta_reduced

        # Calculate PTDFs for all lines
        ptdf_vector = zeros(num_lines)
        for (line_idx, (i, j, b)) in enumerate(lines)
            ptdf_vector[line_idx] = b * (theta_full[i] - theta_full[j])
        end

        ptdf_single_injection[bus] = ptdf_vector
    end

    return ptdf_single_injection, lines
end

"""
    calculate_all_ptdfs_original(Ybus, lines_df, tie_lines_df)

Calculate PTDFs for all canonical transactions (A->B where A < B) in the original network.
Optimized version using matrix method for massive speedup.
"""
function calculate_all_ptdfs_original(
    Ybus::SparseMatrixCSC{ComplexF64},
    lines_df::DataFrame,
    tie_lines_df::DataFrame,
)
    n_buses = size(Ybus, 1)

    # Combine all lines
    all_lines = vcat(lines_df, tie_lines_df, cols = :union)
    line_capacities = Dict{Tuple{Int,Int},Float64}()
    for line in eachrow(all_lines)
        line_capacities[(line.From, line.To)] = line.Capacity_pu
        line_capacities[(line.To, line.From)] = line.Capacity_pu
    end

    # Calculate single injection PTDFs once (biggest performance gain as compared to (to bus) reference)
    println("Calculating single-injection PTDF matrix (one-time computation)...")
    ptdf_single, lines_info = calculate_single_injection_ptdfs(Ybus)
    num_lines = length(lines_info)

    # Create line index mapping for quick lookup
    line_index_map = Dict{Tuple{Int,Int},Int}()
    for (idx, (i, j, _)) in enumerate(lines_info)
        line_index_map[(i, j)] = idx
        line_index_map[(j, i)] = idx  # Both directions point to same line
    end

    # Generate canonical transactions
    transactions = Tuple{Int,Int}[]
    for a = 1:n_buses
        for b = 1:n_buses
            if a < b
                push!(transactions, (a, b))
            end
        end
    end

    total_transactions = length(transactions)
    println(
        "Processing PTDFs for $total_transactions canonical transactions using matrix method...",
    )

    # Pre-allocate results dataframe
    ptdf_results = DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        line_from = Int[],
        line_to = Int[],
        PTDF_value = Float64[],
    )

    start_time = time()
    last_report_time = start_time

    # Process all transactions efficiently using pre-computed single injection PTDFs
    for (idx, (a, b)) in enumerate(transactions)
        # Get PTDF for this transaction: PTDF(a->b) = PTDF(a) - PTDF(b)
        ptdf_vector_a = ptdf_single[a]
        ptdf_vector_b = ptdf_single[b]
        transaction_ptdf = ptdf_vector_a - ptdf_vector_b

        # Store results for all lines that exist in the network
        for (line_from, line_to) in keys(line_capacities)
            if haskey(line_index_map, (line_from, line_to))
                line_idx = line_index_map[(line_from, line_to)]
                ptdf_value = transaction_ptdf[line_idx]
                push!(ptdf_results, (a, b, line_from, line_to, ptdf_value))
            end
        end

        # Progress reporting (less frequent for better performance)
        current_time = time()
        if current_time - last_report_time > 5.0  # Report every 5 seconds
            elapsed = current_time - start_time
            progress = idx / total_transactions * 100
            rate = idx / elapsed
            remaining_time = (total_transactions - idx) / rate

            println("Progress: $(round(progress, digits=1))% ($idx/$total_transactions)")
            println(
                "  Elapsed: $(round(elapsed, digits=1))s, Rate: $(round(rate, digits=1)) trans/s",
            )
            println("  Estimated remaining: $(round(remaining_time/60, digits=1)) minutes")
            last_report_time = current_time
        end
    end

    elapsed_total = time() - start_time
    println("\nPTDF calculation completed!")
    println("Total time: $(round(elapsed_total, digits=1)) seconds")
    println(
        "Average rate: $(round(total_transactions/elapsed_total, digits=1)) transactions/second",
    )

    return ptdf_results, line_capacities
end

"""
    calculate_ptdfs_reduced(Y_kron, rep_node_ids)

Calculate PTDFs for canonical transactions between representative nodes using Kron-reduced matrix.
Optimized version using matrix method.
"""
function calculate_ptdfs_reduced(
    Y_kron::SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int},
)
    N_R = size(Y_kron, 1)

    # Calculate single injection PTDFs for reduced network
    println("Calculating single-injection PTDFs for reduced network...")
    ptdf_single_reduced, lines_info_reduced = calculate_single_injection_ptdfs(Y_kron)

    # Generate canonical transactions between representative nodes
    reduced_transactions = Tuple{Int,Int}[]
    for a_r = 1:N_R
        for b_r = 1:N_R
            a_orig = rep_node_ids[a_r]
            b_orig = rep_node_ids[b_r]
            if a_orig < b_orig  # Canonical order using original IDs
                push!(reduced_transactions, (a_r, b_r))
            end
        end
    end

    # Create line index mapping for reduced network
    line_index_map_reduced = Dict{Tuple{Int,Int},Int}()
    for (idx, (i, j, _)) in enumerate(lines_info_reduced)
        line_index_map_reduced[(i, j)] = idx
        line_index_map_reduced[(j, i)] = idx
    end

    ptdf_reduced_results = DataFrame(
        transaction_from_reduced = Int[],
        transaction_to_reduced = Int[],
        transaction_from_orig = Int[],
        transaction_to_orig = Int[],
        synth_line_from = Int[],
        synth_line_to = Int[],
        PTDF_value = Float64[],
    )

    println("Processing $(length(reduced_transactions)) reduced transactions...")

    # Process reduced transactions
    for (a_r, b_r) in reduced_transactions
        # Get PTDF for this transaction in reduced network
        ptdf_vector_a = ptdf_single_reduced[a_r]
        ptdf_vector_b = ptdf_single_reduced[b_r]
        transaction_ptdf = ptdf_vector_a - ptdf_vector_b

        # Store results for all synthetic lines in reduced network
        for (line_idx, (i_r, j_r, _)) in enumerate(lines_info_reduced)
            if i_r != j_r
                ptdf_value = transaction_ptdf[line_idx]

                # Map reduced indices back to original IDs
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

    println("Reduced PTDF calculation complete.")
    return ptdf_reduced_results
end
