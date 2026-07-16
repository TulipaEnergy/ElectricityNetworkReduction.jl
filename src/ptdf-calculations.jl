# ==============================================================================
# PTDF & TTC CALCULATIONS (MEMORY-OPTIMIZED, PARALLEL-CAPABLE)
# ==============================================================================

"""
    calculate_all_ttc_results(Ybus, lines_df, tie_lines_df; dc_cap_map)

Computes TTC for all canonical transactions (a < b) WITHOUT storing PTDFs.
Memory-optimised for large-scale systems.

DC lines contribute additively:
    TTC(a,b) = TTC_AC(a,b) + C_DC(a,b)

Pass an empty Dict (default) when no DC lines are present — the function
then behaves identically to the original.

When `CONFIG.parallel_processing = true` and Julia is started with multiple threads
(e.g. `julia --threads=auto`), the TTC enumeration loop is distributed across
all available threads using `Threads.@threads :static`.  The PTDF basis
computation (LU factorisation + back-solves) is always sequential because
SuiteSparse UMFPACK back-solves are not thread-safe on a shared factorisation
object.

# Keyword arguments
- `dc_cap_map` : Dict{Tuple{Int,Int},Float64} from build_dc_capacity_map().
                 Keys are (min_rep_id, max_rep_id), values are capacity in pu.
"""
function calculate_all_ttc_results(
    Ybus::SparseMatrixCSC{ComplexF64},
    lines_df::DataFrame,
    tie_lines_df::DataFrame;
    dc_cap_map::Dict{Tuple{Int,Int},Float64} = Dict{Tuple{Int,Int},Float64}(),
)
    N = size(Ybus, 1)

    # 1. Build bidirectional capacity lookup (AC lines only).
    #    Parallel branches between the same bus pair are aggregated into a single
    #    equivalent line in Ybus (admittances summed), so their capacities must be
    #    summed here too — otherwise the TTC limit silently reflects only the last
    #    branch iterated instead of the combined thermal rating.
    all_lines = vcat(lines_df, tie_lines_df, cols = :union)
    line_caps = Dict{Tuple{Int,Int},Float64}()
    for l in eachrow(all_lines)
        key = (Int(l.From), Int(l.To))
        line_caps[key] = get(line_caps, key, 0.0) + Float64(l.Capacity_pu)
        rkey = (Int(l.To), Int(l.From))
        line_caps[rkey] = get(line_caps, rkey, 0.0) + Float64(l.Capacity_pu)
    end

    # 2. Build PTDF basis — always sequential (UMFPACK back-solves are not
    #    thread-safe on a shared factorisation object).
    println("Building PTDF basis using sparse LU factorisation...")
    ptdf_single, lines_info, node_component = calculate_single_injection_ptdfs(Ybus)

    # 3. Pre-generate flat pair arrays so the parallel loop uses a 1-D index.
    #    This avoids nested-loop indexing and allows @threads to split the work.
    total = N * (N - 1) ÷ 2
    n_lines = length(lines_info)
    pairs_a = Vector{Int}(undef, total)
    pairs_b = Vector{Int}(undef, total)
    let idx = 0
        for a = 1:N, b = (a+1):N
            idx += 1
            pairs_a[idx] = a
            pairs_b[idx] = b
        end
    end

    # 4. Pre-allocate indexed result arrays.
    #    Each flat index k is written by exactly one task → no locking needed.
    res_ttc_ac = Vector{Float64}(undef, total)
    res_ttc_dc = Vector{Float64}(undef, total)
    res_lim_from = Vector{Int}(undef, total)
    res_lim_to = Vector{Int}(undef, total)

    # 5. Per-thread scratch buffers for the ptdf difference vector.
    #    Eliminates the per-iteration heap allocation of `ptdf_a .- ptdf_b`
    #    (which otherwise creates ~180 GB of GC pressure for a 3000-bus network).
    use_parallel = CONFIG.parallel_processing && Threads.nthreads() > 1
    n_threads = use_parallel ? Threads.nthreads() : 1
    ptdf_bufs = [Vector{Float64}(undef, n_lines) for _ = 1:n_threads]

    if CONFIG.parallel_processing && Threads.nthreads() == 1
        @warn "parallel_processing = true but Julia is running with only 1 thread.  " *
              "Restart Julia with `--threads=auto` (or `-t N`) to enable parallelism."
    end

    t0 = time()

    if use_parallel
        # Suppress BLAS internal threading to avoid oversubscription with @threads.
        # Sparse triangular solves do not benefit from BLAS multi-threading anyway.
        old_blas = BLAS.get_num_threads()
        BLAS.set_num_threads(1)

        println(
            "TTC computation: $(n_threads) threads × $(total) transactions " *
            "($(round(total / 1_000_000.0, digits=2))M pairs)...",
        )

        # Chunked parallel loop — 10 equal chunks gives ≈10 % progress granularity
        # while keeping the @threads spawn overhead negligible vs. compute time.
        n_chunks = min(10, total)
        chunk_size = total ÷ n_chunks

        for chunk_idx = 1:n_chunks
            k_start = (chunk_idx - 1) * chunk_size + 1
            k_end = chunk_idx == n_chunks ? total : chunk_idx * chunk_size

            Threads.@threads :static for k = k_start:k_end
                tid = Threads.threadid()
                a = pairs_a[k]
                b = pairs_b[k]
                buf = ptdf_bufs[tid]

                if node_component[a] != node_component[b]
                    res_ttc_ac[k] = Inf
                    res_lim_from[k] = 0
                    res_lim_to[k] = 0
                else
                    ttc, lim = _calculate_ttc_internal!(
                        buf,
                        ptdf_single,
                        lines_info,
                        line_caps,
                        a,
                        b,
                    )
                    res_ttc_ac[k] = ttc
                    res_lim_from[k] = lim[1]
                    res_lim_to[k] = lim[2]
                end

                key = (min(a, b), max(a, b))
                res_ttc_dc[k] = get(dc_cap_map, key, 0.0)
            end

            # Progress report printed by the main task after each chunk completes.
            elapsed = time() - t0
            pct = Int(round(100 * k_end / total))
            rate = round(k_end / elapsed, digits = 1)
            println("TTC progress: $(pct)% | $(rate) trans/s | $(n_threads) threads")
        end

        BLAS.set_num_threads(old_blas)

    else
        # ── Sequential path ────────────────────────────────────────────────────
        println("TTC computation: sequential mode ($(total) transactions)...")
        buf = ptdf_bufs[1]
        done = 0
        next_progress = 10.0

        for k = 1:total
            a = pairs_a[k]
            b = pairs_b[k]

            if node_component[a] != node_component[b]
                res_ttc_ac[k] = Inf
                res_lim_from[k] = 0
                res_lim_to[k] = 0
            else
                ttc, lim =
                    _calculate_ttc_internal!(buf, ptdf_single, lines_info, line_caps, a, b)
                res_ttc_ac[k] = ttc
                res_lim_from[k] = lim[1]
                res_lim_to[k] = lim[2]
            end

            key = (min(a, b), max(a, b))
            res_ttc_dc[k] = get(dc_cap_map, key, 0.0)

            done += 1
            progress = 100.0 * done / total
            if progress >= next_progress || done == total
                elapsed = time() - t0
                rate = round(done / elapsed, digits = 1)
                reported_percent = done == total ? 100 : Int(min(next_progress, 100))
                println("TTC progress: $(reported_percent)% | $(rate) trans/s")
                next_progress += 10.0
            end
        end
    end

    # 6. Assemble result DataFrame from pre-allocated arrays (zero-copy).
    #    For cross-island pairs (TTC_AC = Inf), the total TTC must be the DC
    #    capacity itself when a DC bridge exists (not Inf + C_DC = Inf), or Inf
    #    when no DC path connects the islands either.
    res_ttc_total = [
        isinf(ac) ? (dc > 0.0 ? dc : Inf) : ac + dc for
        (ac, dc) in zip(res_ttc_ac, res_ttc_dc)
    ]

    results = DataFrame(
        transaction_from = pairs_a,
        transaction_to = pairs_b,
        TTC_pu = res_ttc_total,
        TTC_AC_pu = res_ttc_ac,
        TTC_DC_pu = res_ttc_dc,
        limiting_line_from = res_lim_from,
        limiting_line_to = res_lim_to,
    )

    if !isempty(dc_cap_map)
        n_dc = count(r -> r.TTC_DC_pu > 0.0, eachrow(results))
        println("DC additive capacity applied to $(n_dc) transactions.")
    end

    return results, line_caps
end

"""
    calculate_single_injection_ptdfs(Ybus; reference_bus=1)

Core Engine: Factorises B matrix once and solves for unit injections.

Handles multi-island (multi-synchronous-zone) networks by detecting AC connected
components and using one reference bus per component. Returns a node_component
vector so callers can identify cross-island transactions (TTC_AC = Inf).
"""
function calculate_single_injection_ptdfs(
    Ybus::SparseMatrixCSC{ComplexF64};
    reference_bus::Int = 1,
)
    N = size(Ybus, 1)
    B = -imag(Ybus)

    # --- Detect AC connected components from B matrix sparsity ---
    g = SimpleGraph(N)
    brows = rowvals(B)
    bvals = nonzeros(B)
    for col = 1:N, k in nzrange(B, col)
        row = brows[k]
        if row != col && abs(bvals[k]) > 1e-10
            add_edge!(g, row, col)
        end
    end
    components = connected_components(g)
    n_components = length(components)
    if n_components > 1
        println("  Multi-island network: $(n_components) AC islands detected.")
    end

    # Build node → component index map
    node_component = zeros(Int, N)
    for (ci, comp) in enumerate(components)
        node_component[comp] .= ci
    end

    # Pick one reference node per component (prefer `reference_bus` for its island)
    comp_refs = [comp[1] for comp in components]
    for (ci, comp) in enumerate(components)
        if reference_bus in comp
            comp_refs[ci] = reference_bus
            break
        end
    end
    ref_set = Set(comp_refs)
    non_ref = collect(setdiff(1:N, ref_set))

    # Factorise the reduced B matrix (block-diagonal, non-singular when one ref per island)
    B_red = B[non_ref, non_ref]
    B_fact = lu(B_red)

    # Extract lines efficiently from sparse structure
    lines = Vector{Tuple{Int,Int,Float64}}()
    for col = 1:N, k in nzrange(B, col)
        row = brows[k]
        if row < col
            push!(lines, (Int(row), Int(col), Float64(bvals[k])))
        end
    end

    bus_to_idx = Dict(b => i for (i, b) in enumerate(non_ref))
    ptdf_single = Dict{Int,Vector{Float64}}()

    # Reference nodes for each component have zero PTDF
    for ref in comp_refs
        ptdf_single[ref] = zeros(length(lines))
    end

    for b in non_ref
        rhs = zeros(length(non_ref))
        rhs[bus_to_idx[b]] = 1.0

        theta_red = B_fact \ rhs
        theta_full = zeros(N)
        theta_full[non_ref] .= theta_red

        # Store impact on all lines for this injection
        ptdf_single[b] = [bij * (theta_full[i] - theta_full[j]) for (i, j, bij) in lines]
    end

    return ptdf_single, lines, node_component
end

# --- HELPER FUNCTION ---
# Mutating variant: writes the PTDF difference in-place into caller-supplied
# buffer `buf` to avoid per-call heap allocation (eliminates ~180 GB of GC
# pressure in the TTC enumeration loop for a 3000-bus network).
# Both the sequential and parallel paths share this implementation.
function _calculate_ttc_internal!(
    buf::Vector{Float64},
    ptdf_single,
    lines_info,
    line_caps,
    a,
    b,
)
    ptdf_a = ptdf_single[a]
    ptdf_b = ptdf_single[b]
    @inbounds for i = 1:length(buf)
        buf[i] = ptdf_a[i] - ptdf_b[i]
    end

    ttc = Inf
    limiting = (0, 0)

    @inbounds for (k, (i, j, _)) in enumerate(lines_info)
        p = buf[k]
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
    calculate_ptdfs_reduced(Y_kron, rep_node_ids; high_res_ids)

Calculates PTDFs for the smaller equivalent network.
Uses local indices for calculation and maps back to original IDs for output.

When `high_res_ids` is non-empty (high-resolution zone mode), pairs where
**both** endpoints are in the high-res set are skipped: their PTDFs are
determined by the original physical network, and including them would make
the computation O(n_hires²) — infeasible for large zones. Cross-boundary
and external-only pairs are still computed normally.
"""
function calculate_ptdfs_reduced(
    Y_kron::SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int};
    high_res_ids::Set{Int} = Set{Int}(),
)
    N_R = length(rep_node_ids)

    # 1. Calculate basis using the reduced matrix (indices 1 to N_R)
    ptdf_single, lines_info, _ = calculate_single_injection_ptdfs(Y_kron)

    results = DataFrame(
        transaction_from_orig = Int[],
        transaction_to_orig = Int[],
        synth_line_from = Int[],
        synth_line_to = Int[],
        PTDF_value = Float64[],
    )

    skip_intra = !isempty(high_res_ids)
    n_skipped = 0

    # 2. Iterate using local indices (1 to N_R)
    for a_local = 1:N_R
        for b_local = (a_local+1):N_R
            id_a = rep_node_ids[a_local]
            id_b = rep_node_ids[b_local]

            # Skip intra-high-res pairs — handled via original network TTC
            if skip_intra && (id_a in high_res_ids) && (id_b in high_res_ids)
                n_skipped += 1
                continue
            end

            ptdf_ab = ptdf_single[a_local] .- ptdf_single[b_local]

            # Canonicalise (transaction_from_orig, transaction_to_orig) to
            # (min, max) bus-ID order. `rep_node_ids` is ordered by
            # representative-selection order, not by numeric bus ID, so
            # id_a > id_b about half the time. Every downstream consumer
            # (optimise_equivalent_capacities' PTDF lookup, in particular)
            # queries by (min, max) — leaving pairs in local-index order
            # silently hid ~half of all PTDF rows from that lookup.
            swapped = id_a > id_b
            out_a, out_b = swapped ? (id_b, id_a) : (id_a, id_b)

            for (k, (i_local, j_local, _)) in enumerate(lines_info)
                if abs(ptdf_ab[k]) > 1e-10
                    id_i = rep_node_ids[i_local]
                    id_j = rep_node_ids[j_local]
                    ptdf_val = swapped ? -ptdf_ab[k] : ptdf_ab[k]
                    push!(results, (out_a, out_b, id_i, id_j, ptdf_val))
                end
            end
        end
    end

    if skip_intra && n_skipped > 0
        println(
            "  High-res mode: skipped $n_skipped intra-zone PTDF pairs " *
            "(use original network TTC for those transactions).",
        )
    end

    return results
end
