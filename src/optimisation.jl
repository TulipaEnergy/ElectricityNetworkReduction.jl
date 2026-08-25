# --- OPTIMIZATION FUNCTIONS ---

"""
    optimise_equivalent_capacities(

    ttc_original::DataFrame,
    ptdf_reduced_results::DataFrame;
    Type::String = CONFIG.optimisation_type,
    lambda::Float64 = CONFIG.lambda,
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0
    )

Optimise equivalent AC capacities for the reduced network using QP, MIQP, or LP.

DC capacity is handled separately and added back in the reported total TTC.
The primary `TTC_Equivalent` result is formulation-aware: QP reports the
fitted TTC, while LP/MIQP report the recomputed TTC (obtained by recomputing
TTC from the final exported capacities and reduced-network PTDFs).

# Arguments
- `ttc_original::DataFrame`: Original network TTC values
- `ptdf_reduced_results::DataFrame`: PTDF results from reduced network
- `Type::String`: Optimisation type: "QP", "MIQP", or "LP"
- `bigM_factor::Float64`: Factor for big-M constraints (MIQP only)
- `lambda::Float64`: Regularisation parameter for capacity smoothing

# Returns
- `equivalent_capacities::DataFrame`: Optimised synthetic line capacities

# Mathematical Formulation

## QP/LP Formulation:
Minimise: Σ(TTC_eq[t] - TTC_orig[t])² + λ*Σ(C_eq[l]²)  (QP)
or
Maximise: Σ TTC_eq[t] (LP with TTC_eq[t] ≤ TTC_orig[t])
Subject to: TTC_eq[t] ≤ C_eq[l] / |PTDF[t,l]| for all transactions t and lines l

## MIQP (Linearized as MILP) Formulation:
Minimise: Σ |TTC_eq[t] - TTC_orig[t]|  (L1 Norm for matching)
Subject to:
    # 1. Physical Capacity Constraints
    TTC_eq[t] ≤ C_eq[l] / |PTDF[t,l]|            for all t, l

    # 2. Exactly-One-Binding Logic (Linearized with Big-M)
    TTC_eq[t] = Σ (Z[t,l] / |PTDF[t,l]|)         where Z[t,l] is allocated capacity
    Z[t,l] ≤ C_eq[l]                            (always)
    Z[t,l] ≥ C_eq[l] - M(1 - b[t,l])            (if b[t,l]=1, then Z=C_eq)
    Z[t,l] ≤ M * b[t,l]                         (if b[t,l]=0, then Z=0)
    Σ b[t,l] = 1                                (Exactly one line b binds transaction t)
"""

function optimise_equivalent_capacities(
    ttc_original::DataFrame,
    ptdf_reduced_results::DataFrame;
    Type::String = CONFIG.optimisation_type,
    lambda::Float64 = CONFIG.lambda,
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0,
    allow_virtual_lines::Bool = CONFIG.allow_virtual_lines,
    allowed_synth_pairs::Set{Tuple{Int,Int}} = Set{Tuple{Int,Int}}(),
    dc_cap_map::Dict{Tuple{Int,Int},Float64} = Dict{Tuple{Int,Int},Float64}(),
    high_res_node_ids::Set{Int} = Set{Int}(),
    phys_line_caps::Dict{Tuple{Int,Int},Float64} = Dict{Tuple{Int,Int},Float64}(),
)
    println("\n--- OPTIMISING EQUIVALENT CAPACITIES (Type: $Type) ---")

    # Display selected solver based on optimisation type
    # Map MIQP to MILP

    if Type == "MIQP"
        println("Note: MIQP converted to MILP (linearized)")
        println("Selected solver: HiGHS")
    elseif Type == "LP"
        println(
            "Selected solver: deterministic capacity envelope + HiGHS fixed-value extraction",
        )
    else
        println("Selected solver: Ipopt")
    end
    # ------------------------------------------------------------
    # 1. DATA PREPARATION (COMMON FOR ALL MODELS)
    # ------------------------------------------------------------

    # Get unique synthetic lines from PTDF results
    synth_lines_df = unique(ptdf_reduced_results, [:synth_line_from, :synth_line_to])

    println("Candidate synthetic lines BEFORE any filtering: $(nrow(synth_lines_df))")

    # ── Save the original unfiltered candidates for possible fallback ──
    original_candidates = copy(synth_lines_df)

    # === FILTER VIRTUAL LINES IF REQUESTED ===

    if !allow_virtual_lines
        println("→ Virtual lines disabled per config.")
        println("   Keeping ONLY synth lines that correspond to original topology:")
        println("     • ALL intra-zone synthetic lines")
        println(
            "     • Inter-zone synthetic lines ONLY if zones had direct physical connection",
        )
        old_count = nrow(synth_lines_df)

        filter!(row -> begin
            u = min(row.synth_line_from, row.synth_line_to)
            v = max(row.synth_line_from, row.synth_line_to)
            (u, v) ∈ allowed_synth_pairs
        end, synth_lines_df)

        new_count = nrow(synth_lines_df)
        println("Remaining after topology-preserving filter: $new_count (was $old_count)")

        # Automatic fallback
        if new_count == 0
            if old_count == 0
                @error "PTDF results contain no synthetic lines at all..."
                throw(ArgumentError("No candidate lines from Kron reduction"))
            else
                println(" No lines retained after topology filter.")
                println(
                    "→ Automatically enabling virtual lines for this run to avoid empty network.",
                )
                allow_virtual_lines = true
                synth_lines_df = original_candidates
                println("Restored $(nrow(synth_lines_df)) virtual/synthetic lines.")
            end
        end
    end

    # ── Build canonical edge list and mapping ─────────────────────────────
    synth_lines = Tuple{Int,Int}[]
    synth_line_map = Dict{Tuple{Int,Int},Int}()

    for row in eachrow(synth_lines_df)
        u = min(row.synth_line_from, row.synth_line_to)
        v = max(row.synth_line_from, row.synth_line_to)
        key = (u, v)
        if !haskey(synth_line_map, key)
            push!(synth_lines, key)
            synth_line_map[key] = length(synth_lines)
        end
    end

    # --- Build fixed-capacity dict for intra-high-res synthetic lines ---
    # Physical lines between two high-res nodes get their actual capacity fixed.
    # Kron fill-in lines (no physical counterpart) get a large sentinel value so
    # they never constrain any transaction.
    fixed_caps = Dict{Int,Float64}()
    if !isempty(high_res_node_ids)
        for (idx, (u, v)) in enumerate(synth_lines)
            if (u in high_res_node_ids) && (v in high_res_node_ids)
                cap = get(phys_line_caps, (u, v), get(phys_line_caps, (v, u), 0.0))
                fixed_caps[idx] = cap > 0.0 ? cap : 1e6   # 1e6 pu ≈ unconstrained
            end
        end
        if !isempty(fixed_caps)
            println(
                "High-res mode: $(length(fixed_caps)) intra-zone synthetic lines " *
                "fixed to physical capacities (not optimised).",
            )
        end
    end

    L = 1:length(synth_lines)  # Synthetic line indices
    # Get reduced network bus IDs
    rn_ids = unique(
        vcat(
            ptdf_reduced_results.transaction_from_orig,
            ptdf_reduced_results.transaction_to_orig,
        ),
    )

    # Filter canonical transactions (from reduced network only).
    # In high-res mode, exclude intra-high-res pairs from the optimisation —
    # their TTC is captured by the fixed physical line capacities and the
    # original network TTC, so there is nothing to optimise for those pairs.
    ttc_canonical = filter(
        r ->
            (r.transaction_from in rn_ids) &&
            (r.transaction_to in rn_ids) &&
            (r.transaction_from < r.transaction_to) &&
            !(
                !isempty(high_res_node_ids) &&
                (r.transaction_from in high_res_node_ids) &&
                (r.transaction_to in high_res_node_ids)
            ),
        ttc_original,
    )

    TR = 1:nrow(ttc_canonical)  # Transaction indices

    println("Synthetic lines: $(length(L))")
    println("Canonical transactions: $(length(TR))")

    # Create PTDF lookup dictionary: (t,l) → |PTDF|
    # Pre-index ptdf_reduced_results by (from, to) pair so we never do a
    # O(|ptdf_rows|) scan per transaction. Critical for high-res mode where
    # transaction count can reach tens of thousands.
    epsilon = CONFIG.ptdf_epsilon

    ptdf_index = Dict{Tuple{Int,Int},Vector{Int}}()
    for (row_idx, r) in enumerate(eachrow(ptdf_reduced_results))
        # Canonicalise to (min, max) — ttc_canonical always queries this way.
        key = (
            min(r.transaction_from_orig, r.transaction_to_orig),
            max(r.transaction_from_orig, r.transaction_to_orig),
        )
        push!(get!(ptdf_index, key, Int[]), row_idx)
    end

    PTDF = Dict{Tuple{Int,Int},Float64}()
    for (t, row) in enumerate(eachrow(ttc_canonical))
        a, b = row.transaction_from, row.transaction_to
        row_indices = get(ptdf_index, (a, b), Int[])

        for row_idx in row_indices
            r = ptdf_reduced_results[row_idx, :]
            lkey = (
                min(r.synth_line_from, r.synth_line_to),
                max(r.synth_line_from, r.synth_line_to),
            )
            if haskey(synth_line_map, lkey)
                l = synth_line_map[lkey]
                val = abs(r.PTDF_value)
                if val > epsilon
                    PTDF[(t, l)] = val
                end
            end
        end
    end

    ttc_orig = ttc_canonical.TTC_pu  # Total TTC (AC + DC) — used for reporting

    # Equivalent AC synthetic capacities should fit the AC TTC component. DC
    # interconnector capacity is exported separately and added back in the
    # recomputed-TTC calculation below. Optimising the AC network against
    # total AC+DC TTC would overstate the AC synthetic capacities and double
    # count DC capacity for users who consume the exported equivalent network.
    ttc_orig_ac =
        hasproperty(ttc_canonical, :TTC_AC_pu) ? ttc_canonical.TTC_AC_pu :
        ttc_canonical.TTC_pu

    # Precompute relevant lines for each transaction
    relevant_lines_per_txn = [Int[] for _ in TR]
    for t in TR
        relevant_lines_per_txn[t] = [l for l in L if haskey(PTDF, (t, l))]
    end

    # Precompute transactions for each line
    relevant_txns_per_line = [Int[] for _ in L]
    for t in TR
        for l in relevant_lines_per_txn[t]
            push!(relevant_txns_per_line[l], t)
        end
    end

    # Per-transaction additive DC capacity (0.0 when no DC capacity applies).
    # Optimisation fits the AC component only; this value is added back when
    # reporting total fitted TTC and recomputed TTC.
    dc_floor = zeros(Float64, length(TR))
    if !isempty(dc_cap_map)
        for (t, row) in enumerate(eachrow(ttc_canonical))
            key = (
                min(row.transaction_from, row.transaction_to),
                max(row.transaction_from, row.transaction_to),
            )
            dc_floor[t] = get(dc_cap_map, key, 0.0)
        end
    end

    # ------------------------------------------------------------
    # 2. MODEL SELECTION AND SETUP
    # ------------------------------------------------------------
    binding_dict = nothing
    if Type == "QP"
        model, TTC_vals = _solve_qp_model(
            ttc_orig_ac,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            lambda,
            dc_floor;
            fixed_caps,
        )

    elseif Type == "MIQP"
        model, TTC_vals, binding_dict = _solve_miqp_model(
            ttc_orig_ac,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            relevant_txns_per_line,
            dc_floor;
            lambda,
            bigM_factor,
            max_C_factor,
            fixed_caps,
            binding_candidates_per_txn = CONFIG.miqp_binding_candidates_per_txn,
            time_limit_sec = CONFIG.miqp_time_limit_sec,
            mip_rel_gap = CONFIG.miqp_mip_rel_gap,
        )

    elseif Type == "LP"
        model, TTC_vals, binding_dict = _solve_lp_model(
            ttc_orig_ac,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            lambda,
            dc_floor;
            fixed_caps,
        )

    else
        error("Invalid Type: $Type. Choose from: QP, MIQP, LP")
    end

    ttc_ac_orig =
        hasproperty(ttc_canonical, :TTC_AC_pu) ? ttc_canonical.TTC_AC_pu :
        ttc_canonical.TTC_pu

    C_vals = collect(value.(model[:C_eq]))
    recomputed_ac_vals, recomputed_total_vals, recomputed_binding_dict =
        _compute_recomputed_ttc(
            C_vals,
            synth_lines,
            TR,
            PTDF,
            relevant_lines_per_txn,
            dc_floor,
            ttc_ac_orig,
        )

    # ------------------------------------------------------------
    # 3. EXTRACT BOTH CAPACITIES AND TTC RESULTS
    # ------------------------------------------------------------

    # Extract equivalent capacities
    equivalent_capacities = _extract_capacities(model, synth_lines, L, TR, ttc_orig, Type)

    # Create TTC results directly from optimisation variables
    ttc_equivalent_results = create_ttc_results_from_optimisation(
        TTC_vals,
        recomputed_ac_vals,
        recomputed_total_vals,
        ttc_canonical,
        model = model,
        Type = Type,
        synth_lines = synth_lines,
        binding_dict = recomputed_binding_dict,
    )

    return equivalent_capacities, ttc_equivalent_results
end

# ------------------------------------------------------------
# RECOMPUTED TTC (TTC recomputed from the final exported capacities and
# reduced-network PTDFs, as opposed to the solver's own fitted variable)
# ------------------------------------------------------------

function _compute_recomputed_ttc(
    C_vals::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    dc_floor::Vector{Float64},
    ttc_ac_orig::Vector{Float64},
)
    recomputed_ac = Vector{Float64}(undef, length(TR))
    recomputed_total = Vector{Float64}(undef, length(TR))
    binding_dict = Dict{Int,Tuple{Int,Int}}()

    for t in TR
        if !isfinite(ttc_ac_orig[t])
            # No AC path in the original network. A DC bridge contributes its
            # capacity directly; otherwise the total TTC remains infinite.
            recomputed_ac[t] = Inf
            recomputed_total[t] = dc_floor[t] > 0.0 ? dc_floor[t] : Inf
            continue
        end

        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            # Finite AC original TTC but no reduced AC PTDF support. This is an
            # honest unsupported-topology outcome; DC, if present, is still
            # represented by dc_floor in the total TTC.
            recomputed_ac[t] = 0.0
            recomputed_total[t] = dc_floor[t]
            continue
        end

        best_val = Inf
        best_line = 0
        for l in rel_lines
            p = PTDF[(t, l)]
            val = C_vals[l] / p
            if val < best_val
                best_val = val
                best_line = l
            end
        end

        recomputed_ac[t] = max(0.0, best_val)
        recomputed_total[t] = recomputed_ac[t] + dc_floor[t]
        if best_line != 0
            binding_dict[t] = synth_lines[best_line]
        end
    end

    return recomputed_ac, recomputed_total, binding_dict
end

# ------------------------------------------------------------
# QP MODEL IMPLEMENTATION
# ------------------------------------------------------------

function _solve_qp_model(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    lambda::Float64,
    dc_floor::Vector{Float64} = zeros(Float64, length(TR));
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
)
    println("Setting up QP model...")

    # Use Ipopt for QP
    model = Model(Ipopt.Optimizer)

    # ipopt-specific settings
    set_silent(model)  # Suppress output

    # Variables
    @variable(model, C_eq[l in L] >= 0)           # Equivalent capacities
    @variable(model, TTC_eq[t in TR] >= 0)        # Equivalent TTCs
    @variable(model, V_mismatch[t in TR])         # TTC mismatches

    # Fix intra-high-res synthetic line capacities to their physical values
    for (l, cap) in fixed_caps
        fix(C_eq[l], cap; force = true)
    end

    # Objective: Minimise squared error with regularisation
    @objective(
        model,
        Min,
        sum(V_mismatch[t]^2 for t in TR) + lambda * sum(C_eq[l]^2 for l in L)
    )

    # Constraints
    # 1. Mismatch definition (skip cross-island transactions where TTC_orig = Inf)
    @constraint(
        model,
        [t in TR; isfinite(ttc_orig[t])],
        V_mismatch[t] == TTC_eq[t] - ttc_orig[t]
    )

    # 2. Physical constraints: AC TTC cannot exceed capacity/PTDF ratio.
    #    Transactions with no relevant synthetic line (all PTDFs below epsilon)
    #    have no physical path in the reduced network, so TTC_eq must be pinned
    #    to 0.0. DC capacity is represented separately and added back after the
    #    AC recomputed TTC is computed.
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            @constraint(model, TTC_eq[t] == 0.0)
        else
            for l in rel_lines
                @constraint(model, TTC_eq[t] <= C_eq[l] / PTDF[(t, l)])
            end
        end
    end

    # Solve
    optimize!(model)

    status = termination_status(model)
    println("QP status: $status")

    if status in (
        MathOptInterface.INFEASIBLE,
        MathOptInterface.LOCALLY_INFEASIBLE,
        MathOptInterface.INFEASIBLE_OR_UNBOUNDED,
    )
        error(
            "QP solve reported $status — refusing to export meaningless values. " *
            "Check for conflicting AC capacity constraints or inconsistent TTC targets.",
        )
    elseif status != MathOptInterface.OPTIMAL
        println("QP solution status: $status")
    end

    # Extract results. Clamp to zero: transactions pinned by an equality
    # constraint (no relevant synthetic line) can land at a tiny negative
    # value (e.g. -1e-50) from solver tolerance rather than exactly 0.0.
    TTC_vals_raw = value.(model[:TTC_eq])
    TTC_vals = [max(0.0, TTC_vals_raw[t]) for t in TR]

    binding_dict = nothing

    return model, TTC_vals, binding_dict
end

# ------------------------------------------------------------
# MIQP MODEL IMPLEMENTATION
# ------------------------------------------------------------
"""
Linearized MILP formulation using HiGHS that enforces **exactly one binding line** per transaction.
Objective: minimise sum of absolute TTC errors (L1 norm).

"""
function _solve_miqp_model_legacy(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    relevant_txns_per_line::Vector{Vector{Int}},
    dc_floor::Vector{Float64} = zeros(Float64, length(TR));
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0,
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
)
    println(
        "Setting up linearized MILP model (HiGHS) — exactly one binding line per transaction",
    )

    # ── Safeguards & big-M computation ──────────────────────────────────────
    finite_orig = filter(isfinite, ttc_orig)
    max_ttc = isempty(finite_orig) ? 1.0 : maximum(finite_orig)
    max_ptdf = isempty(PTDF) ? 1.0 : maximum(abs.(values(PTDF))) + 1e-9
    bigM_ttc = bigM_factor * max_ttc
    bigM_Z = bigM_factor * max_ttc * max_ptdf
    C_ub = max_C_factor * max_ttc * max_ptdf

    # ── Model ───────────────────────────────────────────────────────────────
    model = Model(HiGHS.Optimizer)
    set_silent(model)


    # ── Variables ───────────────────────────────────────────────────────────
    @variable(model, 0 ≤ C_eq[l in L] ≤ C_ub)

    # Fix intra-high-res synthetic line capacities to their physical values
    for (l, cap) in fixed_caps
        fix(C_eq[l], cap; force = true)
    end

    @variable(model, TTC_eq[t in TR] ≥ 0)

    # Sparse (t,l) variables — only for relevant pairs
    Z = Dict{Tuple{Int,Int},VariableRef}()
    b = Dict{Tuple{Int,Int},VariableRef}()

    for t in TR, l in relevant_lines_per_txn[t]
        Z[(t, l)] = @variable(model, lower_bound = 0.0, base_name = "Z[$t,$l]")
        b[(t, l)] = @variable(model, binary = true, base_name = "b[$t,$l]")
    end
    # Register the binding-indicator variables on the model so the caller can
    # recompute the binding dictionary after any later solve without it going stale.
    model[:b_bind] = b

    @variable(model, V_abs[t in TR] ≥ 0)

    # ── Objective ───────────────────────────────────────────────────────────
    @objective(model, Min, sum(V_abs[t] for t in TR))

    # ── Constraints ─────────────────────────────────────────────────────────

    # A. L1 error linearisation (skip cross-island transactions where TTC_orig = Inf)
    for t in TR
        if isfinite(ttc_orig[t])
            @constraint(model, V_abs[t] ≥ TTC_eq[t] - ttc_orig[t])
            @constraint(model, V_abs[t] ≥ ttc_orig[t] - TTC_eq[t])
        end
    end

    # B. TTC definition = sum (allocated capacity / PTDF).
    #    No relevant line -> pin to the additive DC value used by this legacy
    #    formulation (0.0 if none).
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            @constraint(model, TTC_eq[t] == dc_floor[t])
        else
            @constraint(
                model,
                TTC_eq[t] == sum(Z[(t, l)] / PTDF[(t, l)] for l in rel_lines)
            )
        end
    end

    # C. Z[t,l] ≤ C_eq[l]   (always respected)
    for (t, l) in keys(Z)
        @constraint(model, Z[(t, l)] ≤ C_eq[l])
    end

    # D. Exactly-one-binding logic + Z = C_eq when binding
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if !isempty(rel_lines)
            @constraint(model, sum(b[(t, l)] for l in rel_lines) == 1)

            for l in rel_lines
                @constraint(model, Z[(t, l)] ≤ bigM_Z * b[(t, l)])
                @constraint(model, Z[(t, l)] ≥ C_eq[l] - bigM_Z * (1 - b[(t, l)]))
            end
        end
    end

    # E. Physical upper bounds on TTC
    for t in TR, l in relevant_lines_per_txn[t]
        @constraint(model, TTC_eq[t] ≤ C_eq[l] / PTDF[(t, l)])
    end

    # F. Numerical stability bound
    for t in TR
        @constraint(model, TTC_eq[t] ≤ bigM_ttc)
    end

    # ── Solve ───────────────────────────────────────────────────────────────
    println("Solving MILP with HiGHS...")
    optimize!(model)

    status = termination_status(model)
    println("MILP status: $status")

    if status ∉ [OPTIMAL, LOCALLY_SOLVED, ALMOST_OPTIMAL, ALMOST_LOCALLY_SOLVED]
        @warn "Unexpected termination status: $status"
        if primal_status(model) == FEASIBLE_POINT
            println("  → but a feasible solution was found")
        end
    end

    # ── Results ─────────────────────────────────────────────────────────────
    TTC_vals = [max(0.0, value(TTC_eq[t])) for t in TR]
    binding_dict = _extract_miqp_binding(model, relevant_lines_per_txn, synth_lines, TR)

    return model, TTC_vals, binding_dict
end

"""
Binding-line MILP solved by HiGHS.

This method supersedes the older Z-allocation MILP above. It fits the AC
recomputed TTC directly:

    TTC_eq[t] = min_l C_eq[l] / abs(PTDF[t,l])

Physical upper-bound constraints are enforced for every relevant
(transaction, line) pair; binary binding choices are restricted to likely
limiting lines for scalability.
"""
function _solve_miqp_model(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    relevant_txns_per_line::Vector{Vector{Int}},
    dc_floor::Vector{Float64} = zeros(Float64, length(TR));
    lambda::Float64 = CONFIG.lambda,
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0,
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
    binding_candidates_per_txn::Int = CONFIG.miqp_binding_candidates_per_txn,
    time_limit_sec::Float64 = CONFIG.miqp_time_limit_sec,
    mip_rel_gap::Float64 = CONFIG.miqp_mip_rel_gap,
)
    println("Setting up binding-line MILP model (HiGHS) -- recomputed TTC fit")

    finite_orig = filter(isfinite, ttc_orig)
    max_ttc = isempty(finite_orig) ? 1.0 : maximum(finite_orig)

    required_cap = zeros(Float64, length(L))
    for t in TR
        isfinite(ttc_orig[t]) || continue
        for l in relevant_lines_per_txn[t]
            required_cap[l] = max(required_cap[l], ttc_orig[t] * PTDF[(t, l)])
        end
    end
    for (l, cap) in fixed_caps
        required_cap[l] = max(required_cap[l], cap)
    end

    C_ub = [
        max(max_C_factor * max(required_cap[l], 1e-8), get(fixed_caps, l, 0.0), 1e-6)
        for l in L
    ]
    bigM_ttc = bigM_factor * max(max_ttc, 1e-6)

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    time_limit_sec > 0.0 && set_time_limit_sec(model, time_limit_sec)
    set_optimizer_attribute(model, "mip_rel_gap", mip_rel_gap)

    @variable(model, 0 <= C_eq[l in L] <= C_ub[l])
    for (l, cap) in fixed_caps
        fix(C_eq[l], cap; force = true)
    end

    @variable(model, 0 <= TTC_eq[t in TR] <= bigM_ttc)
    @variable(model, V_abs[t in TR] >= 0)

    b = Dict{Tuple{Int,Int},VariableRef}()
    binding_candidates = Dict{Int,Vector{Int}}()
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines) || !isfinite(ttc_orig[t])
            binding_candidates[t] = Int[]
            continue
        end

        candidates = if length(rel_lines) <= binding_candidates_per_txn
            rel_lines
        else
            sorted = sort(rel_lines; by = l -> required_cap[l] / max(PTDF[(t, l)], 1e-12))
            sorted[1:binding_candidates_per_txn]
        end
        binding_candidates[t] = candidates

        for l in candidates
            b[(t, l)] = @variable(model, binary = true, base_name = "b[$t,$l]")
        end
    end
    model[:b_bind] = b

    @objective(
        model,
        Min,
        sum(V_abs[t] for t in TR if isfinite(ttc_orig[t])) +
        lambda * sum(C_eq[l] for l in L)
    )

    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines) || !isfinite(ttc_orig[t])
            @constraint(model, TTC_eq[t] == 0.0)
            continue
        end

        @constraint(model, V_abs[t] >= TTC_eq[t] - ttc_orig[t])
        @constraint(model, V_abs[t] >= ttc_orig[t] - TTC_eq[t])

        for l in rel_lines
            @constraint(model, C_eq[l] >= PTDF[(t, l)] * TTC_eq[t])
        end

        candidates = binding_candidates[t]
        if isempty(candidates)
            @constraint(model, TTC_eq[t] == 0.0)
        else
            @constraint(model, sum(b[(t, l)] for l in candidates) == 1)
            for l in candidates
                @constraint(
                    model,
                    C_eq[l] <= PTDF[(t, l)] * TTC_eq[t] + C_ub[l] * (1 - b[(t, l)])
                )
            end
        end
    end

    for l in L
        set_start_value(C_eq[l], min(required_cap[l], C_ub[l]))
    end
    for t in TR
        if isfinite(ttc_orig[t])
            set_start_value(TTC_eq[t], min(ttc_orig[t], bigM_ttc))
        end
    end

    n_binaries = length(b)
    n_relevant = sum(length(relevant_lines_per_txn[t]) for t in TR)
    println(
        "Solving MILP with HiGHS ($(length(TR)) transactions, " *
        "$(length(L)) lines, $n_relevant physical constraints, " *
        "$n_binaries binding binaries)...",
    )
    optimize!(model)

    status = termination_status(model)
    println("MILP status: $status")

    usable_status = status in [
        MathOptInterface.OPTIMAL,
        MathOptInterface.ALMOST_OPTIMAL,
        MathOptInterface.TIME_LIMIT,
    ]
    if !usable_status
        @warn "Unexpected MILP termination status: $status"
    end
    if primal_status(model) != MathOptInterface.FEASIBLE_POINT
        error("MILP did not find a feasible recomputed-TTC solution.")
    end

    TTC_vals = [max(0.0, value(TTC_eq[t])) for t in TR]
    binding_dict = _extract_miqp_binding(model, relevant_lines_per_txn, synth_lines, TR)

    return model, TTC_vals, binding_dict
end

# ------------------------------------------------------------
# Recompute the MIQP/MILP binding-line dictionary from the current binary
# variable values so the exported "limiting synthetic line" reflects the
# final MILP solution.
# ------------------------------------------------------------
function _extract_miqp_binding(
    model::Model,
    relevant_lines_per_txn::Vector{Vector{Int}},
    synth_lines::Vector{Tuple{Int,Int}},
    TR::UnitRange{Int},
)
    b = model[:b_bind]
    binding_dict = Dict{Int,Tuple{Int,Int}}()  # t → (from_bus, to_bus)

    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if !isempty(rel_lines)
            found = false
            for l in rel_lines
                if haskey(b, (t, l)) && value(b[(t, l)]) > 0.5
                    u, v = synth_lines[l]
                    binding_dict[t] = (u, v)
                    found = true
                    break
                end
            end
            if !found
                @warn "No binding line detected for transaction $t (constraint violation?)"
            end
        end
    end

    return binding_dict
end
# ------------------------------------------------------------
# LP MODEL IMPLEMENTATION
# ------------------------------------------------------------

function _solve_lp_model_legacy(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    lambda::Float64,
    dc_floor::Vector{Float64} = zeros(Float64, length(TR));
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
)
    println("Setting up LP model...")

    # Use Ipopt for LP
    model = Model(Ipopt.Optimizer)
    set_silent(model)

    # Variables
    @variable(model, C_eq[l in L] >= 0)           # Equivalent capacities
    @variable(model, TTC_eq[t in TR] >= 0)        # Equivalent TTCs

    # Fix intra-high-res synthetic line capacities to their physical values
    for (l, cap) in fixed_caps
        fix(C_eq[l], cap; force = true)
    end

    # Objective: Maximise total TTC (subject to TTC_eq ≤ TTC_orig), with a small
    # penalty on capacity. Without this, C_eq only appears in one-directional
    # constraints and is otherwise free — any sufficiently large C_eq is equally
    # optimal, so the reported capacities are arbitrary/solver-dependent. The
    # lambda penalty (same regularisation parameter used by QP/MIQP) drives C_eq
    # to the smallest value that still supports the maximised TTC.
    @objective(model, Max, sum(TTC_eq[t] for t in TR) - lambda * sum(C_eq[l] for l in L))

    # Constraints

    # 1. TTC cannot exceed original TTC (skip cross-island transactions where TTC_orig = Inf)
    @constraint(model, [t in TR; isfinite(ttc_orig[t])], TTC_eq[t] <= ttc_orig[t])

    # 2. Physical constraints: TTC cannot exceed capacity/PTDF ratio.
    #    Transactions with no relevant synthetic line have no AC path in the
    #    reduced network, so this legacy formulation pins TTC_eq to the
    #    additive DC value (0.0 when no DC capacity applies).
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            @constraint(model, TTC_eq[t] == dc_floor[t])
        else
            for l in rel_lines
                @constraint(model, TTC_eq[t] <= C_eq[l] / PTDF[(t, l)])
            end
        end
    end

    # Solve
    optimize!(model)

    status = termination_status(model)
    println("LP status: $status")

    if status in (
        MathOptInterface.INFEASIBLE,
        MathOptInterface.LOCALLY_INFEASIBLE,
        MathOptInterface.INFEASIBLE_OR_UNBOUNDED,
    )
        error(
            "LP solve reported $status — refusing to export meaningless values. " *
            "Check for conflicting AC capacity constraints or inconsistent TTC targets.",
        )
    elseif status != MathOptInterface.OPTIMAL
        println("LP solution status: $status")
        if primal_status(model) == MathOptInterface.FEASIBLE_POINT
            println("But found a feasible solution")
        end
    end

    # Extract results
    TTC_vals = max.(0.0, collect(value.(TTC_eq)))
    binding_dict = _extract_lp_binding(model, relevant_lines_per_txn, synth_lines, PTDF, TR)

    return model, TTC_vals, binding_dict
end

function _solve_lp_model(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    lambda::Float64,
    dc_floor::Vector{Float64} = zeros(Float64, length(TR));
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
)
    println("Setting up LP capacity-envelope model...")

    C_vals = zeros(Float64, length(L))
    for l in L
        if haskey(fixed_caps, l)
            C_vals[l] = fixed_caps[l]
            continue
        end

        required = 0.0
        for t in TR
            if isfinite(ttc_orig[t]) && haskey(PTDF, (t, l))
                required = max(required, ttc_orig[t] * PTDF[(t, l)])
            end
        end
        C_vals[l] = required
    end

    TTC_vals = zeros(Float64, length(TR))
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines) || !isfinite(ttc_orig[t])
            TTC_vals[t] = 0.0
        else
            TTC_vals[t] = minimum(C_vals[l] / PTDF[(t, l)] for l in rel_lines)
        end
    end

    # Build a tiny fixed-value JuMP model so downstream extraction can keep
    # using the same C_eq/TTC_eq variable access pattern for all formulations.
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    @variable(model, C_eq[l in L] >= 0)
    @variable(model, TTC_eq[t in TR] >= 0)
    for l in L
        fix(C_eq[l], C_vals[l]; force = true)
    end
    for t in TR
        fix(TTC_eq[t], TTC_vals[t]; force = true)
    end
    @objective(model, Min, 0.0)
    optimize!(model)

    status = termination_status(model)
    println("LP envelope status: $status")
    if status != MathOptInterface.OPTIMAL
        error("LP envelope fixed-value model did not solve cleanly (status: $status).")
    end

    binding_dict = _extract_lp_binding(model, relevant_lines_per_txn, synth_lines, PTDF, TR)
    return model, TTC_vals, binding_dict
end

# ------------------------------------------------------------
# Recompute the LP binding-line dictionary from the current variable
# values so the exported "limiting synthetic line" reflects the final LP
# solution.
# ------------------------------------------------------------
function _extract_lp_binding(
    model::Model,
    relevant_lines_per_txn::Vector{Vector{Int}},
    synth_lines::Vector{Tuple{Int,Int}},
    PTDF::Dict{Tuple{Int,Int},Float64},
    TR::UnitRange{Int},
)
    C_eq = model[:C_eq]
    TTC_eq = model[:TTC_eq]
    binding_dict = Dict{Int,Tuple{Int,Int}}()

    for t in TR
        for l in relevant_lines_per_txn[t]
            if abs(value(TTC_eq[t]) - value(C_eq[l]) / PTDF[(t, l)]) < 1e-6
                binding_dict[t] = synth_lines[l]
                break
            end
        end
    end

    return binding_dict
end
# ------------------------------------------------------------
# RESULT EXTRACTION FUNCTION
# ------------------------------------------------------------

function _extract_capacities(
    model::Model,
    synth_lines,
    L,
    TR,
    ttc_orig,
    Type = CONFIG.optimisation_type,
)
    if isempty(L) || length(synth_lines) == 0
        println("\n=== $Type Optimisation Results ===")
        println(
            "No lines in reduced network (likely allow_virtual_lines=false + no direct physical links between rep nodes)",
        )
        println("→ Returning empty equivalent capacities DataFrame")
        return DataFrame(
            synth_line_from = Int[],
            synth_line_to = Int[],
            C_eq_pu = Float64[],
        )
    end

    C_vals = value.(model[:C_eq])

    println("\n=== $Type Optimisation Results ===")
    println("C_eq statistics:")
    println("  Min:  $(round(minimum(C_vals); digits=6)) pu")
    println("  Max:  $(round(maximum(C_vals); digits=6)) pu")
    println("  Mean: $(round(mean(C_vals); digits=6)) pu")
    println("  Std:  $(round(std(C_vals); digits=6)) pu")

    df = DataFrame(synth_line_from = Int[], synth_line_to = Int[], C_eq_pu = Float64[])
    for (i, (u, v)) in enumerate(synth_lines)
        push!(df, (u, v, C_vals[i]))
    end
    return df
end

"""
    create_ttc_results_from_optimisation(
    ttc_vals::Vector{Float64},
    ttc_canonical::DataFrame;
    model=model,
    Type = CONFIG.optimisation_type,
    synth_lines::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    binding_dict::Union{Dict,Nothing} = nothing
    )

Create TTC results directly from optimisation variables.

"""
function create_ttc_results_from_optimisation(
    ttc_vals::Vector{Float64},
    ttc_recomputed_ac::Vector{Float64},
    ttc_recomputed_total::Vector{Float64},
    ttc_canonical::DataFrame;
    model = model,
    Type = CONFIG.optimisation_type,
    synth_lines::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    binding_dict::Union{Dict,Nothing} = nothing,
)

    n_txn = length(ttc_vals)
    @assert n_txn == nrow(ttc_canonical) "TTC size mismatch"
    @assert length(ttc_recomputed_total) == n_txn "Recomputed TTC size mismatch"

    opt_total = [
        isfinite(ttc_canonical.TTC_AC_pu[t]) ?
        ttc_vals[t] + ttc_canonical.TTC_DC_pu[t] :
        (ttc_canonical.TTC_DC_pu[t] > 0.0 ? ttc_canonical.TTC_DC_pu[t] : Inf) for
        t = 1:n_txn
    ]

    mode = uppercase(String(Type))
    physical_primary = mode in ("LP", "MIQP", "MILP")
    primary_total = physical_primary ? ttc_recomputed_total : opt_total
    primary_source = physical_primary ? "recomputed" : "fitted_optimisation"

    # Base results (common for all types)
    ttc_results = DataFrame(
        transaction_from = ttc_canonical.transaction_from,
        transaction_to = ttc_canonical.transaction_to,
        TTC_Equivalent_pu = primary_total,
    )

    binding_from = fill(0, n_txn)
    binding_to = fill(0, n_txn)
    if isnothing(binding_dict)
        @warn "Recomputed-TTC binding dictionary was not provided to the result extractor."
    else
        for t = 1:n_txn
            if haskey(binding_dict, t)
                from, to = binding_dict[t]
                binding_from[t] = from
                binding_to[t] = to
            end
        end
    end
    ttc_results[!, :limiting_synth_line_from] = binding_from
    ttc_results[!, :limiting_synth_line_to] = binding_to

    # Calculate error statistics (finite-TTC transactions only)
    err_primary = primary_total .- ttc_canonical.TTC_pu
    finite_mask = isfinite.(ttc_canonical.TTC_pu)
    err_primary_finite = err_primary[finite_mask]
    println("\nTTC matching accuracy ($(sum(finite_mask)) finite-TTC transactions):")
    println("  Primary TTC source            = $primary_source")
    println(
        "  Primary max |error|           = $(round(maximum(abs.(err_primary_finite)); digits=6)) pu",
    )
    println(
        "  Primary mean |error|          = $(round(mean(abs.(err_primary_finite)); digits=6)) pu",
    )

    println("\nSample TTC comparisons (first 5 transactions):")
    for t = 1:min(5, n_txn)
        println(
            "  T$t: Original=$(round(ttc_canonical.TTC_pu[t]; digits=6)), " *
            "Equivalent=$(round(primary_total[t]; digits=6)), " *
            "Primary error=$(round(err_primary[t]; digits=6))",
        )
    end

    return ttc_results
end
