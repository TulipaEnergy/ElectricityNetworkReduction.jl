# ==============================================================================
# PTDF & TTC CALCULATIONS (MEMORY-OPTIMIZED)
# ==============================================================================

"""
    calculate_all_ttc_results(Ybus, lines_df, tie_lines_df)

Computes TTC for all canonical transactions (a < b) WITHOUT storing PTDFs.
Memory-optimized for large-scale systems.
"""
function calculate_all_ttc_results(
    Ybus::SparseMatrixCSC{ComplexF64},
    lines_df::DataFrame,
    tie_lines_df::DataFrame,
)
    N = size(Ybus, 1)

    # 1. Build bidirectional capacity lookup
    all_lines = vcat(lines_df, tie_lines_df, cols = :union)
    line_caps = Dict{Tuple{Int,Int},Float64}()
    for l in eachrow(all_lines)
        line_caps[(Int(l.From), Int(l.To))] = Float64(l.Capacity_pu)
        line_caps[(Int(l.To), Int(l.From))] = Float64(l.Capacity_pu)
    end

    # 2. Build PTDF basis (sparse LU factorization)
    println("Building PTDF basis using sparse LU factorization...")
    ptdf_single, lines_info = calculate_single_injection_ptdfs(Ybus)

    # 3. Initialize Results
    results = DataFrame(
        transaction_from = Int[],
        transaction_to = Int[],
        TTC_pu = Float64[],
        limiting_line_from = Int[],
        limiting_line_to = Int[],
    )

    total = N * (N - 1) ÷ 2
    done = 0
    t0 = time()

    # 4. On-the-fly TTC Calculation Loop
    for a = 1:N
        for b = (a+1):N
            # Calculate TTC for this pair specifically
            ttc, lim = _calculate_ttc_internal(ptdf_single, lines_info, line_caps, a, b)

            push!(results, (a, b, ttc, lim[1], lim[2]))
            done += 1

            # PROGRESS REPORTING
            if done % 5000 == 0 || done == total
                elapsed = time() - t0
                rate = done / elapsed
                progress = (100.0 * done) / total
                println(
                    "TTC progress: $(round(progress, digits=1))% | $(round(rate)) trans/s",
                )
            end
        end
    end

    return results, line_caps
end

"""
    calculate_single_injection_ptdfs(Ybus; reference_bus=1)

Core Engine: Factorizes B matrix once and solves for unit injections.
"""
function calculate_single_injection_ptdfs(
    Ybus::SparseMatrixCSC{ComplexF64};
    reference_bus::Int = 1,
)
    N = size(Ybus, 1)
    B = -imag(Ybus)
    non_ref = collect(setdiff(1:N, reference_bus))

    # Factorize B_reduced
    B_red = B[non_ref, non_ref]
    B_fact = lu(B_red)

    # Extract lines efficiently from sparse structure
    lines = Vector{Tuple{Int,Int,Float64}}()
    rows = rowvals(B)
    vals = nonzeros(B)
    for col = 1:N, k in nzrange(B, col)
        row = rows[k]
        if row < col
            push!(lines, (Int(row), Int(col), Float64(vals[k])))
        end
    end

    bus_to_idx = Dict(b => i for (i, b) in enumerate(non_ref))
    ptdf_single = Dict{Int,Vector{Float64}}()
    ptdf_single[reference_bus] = zeros(length(lines))

    for b in non_ref
        rhs = zeros(length(non_ref))
        rhs[bus_to_idx[b]] = 1.0

        theta_red = B_fact \ rhs
        theta_full = zeros(N)
        theta_full[non_ref] .= theta_red

        # Store impact on all lines for this injection
        ptdf_single[b] = [bij * (theta_full[i] - theta_full[j]) for (i, j, bij) in lines]
    end

    return ptdf_single, lines
end

# --- PRIVATE HELPER ---
function _calculate_ttc_internal(ptdf_single, lines_info, line_caps, a, b)
    # PTDF(a->b) = PTDF(a) - PTDF(b)
    ptdf_ab = ptdf_single[a] .- ptdf_single[b]
    ttc = Inf
    limiting = (0, 0)

    for (k, (i, j, _)) in enumerate(lines_info)
        p = ptdf_ab[k]
        abs(p) < 1e-10 && continue

        cap = get(line_caps, (i, j), get(line_caps, (j, i), Inf))
        val = cap / abs(p)

        if val < ttc
            ttc = val
            limiting = (i, j)
        end
    end
    return ttc, limiting
end


"""
    calculate_ptdfs_reduced(Y_kron, rep_node_ids)

Calculates PTDFs for the smaller equivalent network.
Uses local indices for calculation and maps back to original IDs for output.
"""

function calculate_ptdfs_reduced(
    Y_kron::SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int},
)
    N_R = length(rep_node_ids)

    # 1. Calculate basis using the reduced matrix (indices 1 to N_R)
    # The dictionary keys here will be 1, 2, ..., N_R
    ptdf_single, lines_info = calculate_single_injection_ptdfs(Y_kron)

    results = DataFrame(
        transaction_from_orig = Int[],
        transaction_to_orig = Int[],
        synth_line_from = Int[], # These will be original IDs
        synth_line_to = Int[],   # These will be original IDs
        PTDF_value = Float64[],
    )

    # 2. Iterate using local indices (1 to N_R)
    for a_local = 1:N_R
        for b_local = (a_local+1):N_R
            # Map local indices back to original IDs for the transaction
            id_a = rep_node_ids[a_local]
            id_b = rep_node_ids[b_local]

            # Use local indices to access the ptdf_single dictionary
            ptdf_ab = ptdf_single[a_local] .- ptdf_single[b_local]

            for (k, (i_local, j_local, _)) in enumerate(lines_info)
                if abs(ptdf_ab[k]) > 1e-10
                    # Map local line indices back to original IDs
                    id_i = rep_node_ids[i_local]
                    id_j = rep_node_ids[j_local]

                    push!(results, (id_a, id_b, id_i, id_j, ptdf_ab[k]))
                end
            end
        end
    end
    return results
end
