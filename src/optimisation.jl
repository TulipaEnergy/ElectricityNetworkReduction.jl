# Capacity fitting and evaluation.

"""
    optimise_equivalent_capacities(ttc_original, ptdf_reduced_results;
        Type=CONFIG.optimisation_type, lambda=CONFIG.lambda,
        gamma_C=CONFIG.miqp_gamma_C, optimizer_factory=CONFIG.miqp_optimizer,
        dc_cap_map, high_res_node_ids, phys_line_caps, rep_node_ids,
        reduced_ybus, solver_diagnostics_path=nothing)

Fit AC equivalent capacities using QP, LP envelope, or MIQP.
MIQP minimises the sum of squared relative AC TTC errors, enforces an actual
binding line and bounds each calibrated TTC by its original target. SCIP is
the default; any other installed MIQP-capable JuMP optimizer may be supplied.
`gamma_C >= 1` scales the reference capacity bounds; `lambda` affects QP only.

Return `(equivalent_capacities, ttc_equivalent_results)`. Reported TTCs are
always evaluated from the exported capacities and the final reduced topology,
with additive DC capacity. MIQP applies a deterministic capacity
closure, validates fitted versus physical TTC and optionally writes solver
status, bounds, gap and timing to `solver_diagnostics_path`.

Filter virtual lines in the DC matrix before computing the supplied PTDFs.
Pass `rep_node_ids` and `reduced_ybus` to retain isolated buses and edges absent
from the enumerated PTDF transactions. Fixed physical zero ratings stay zero.
Fit errors describe the approximation trade-off; no universal accuracy cutoff
is imposed. Calibrated MIQP transactions are finite positive AC targets that
load an optimisable line. Fixed-only and unsupported transfers are evaluated
from their physical capacities without fitting.
"""

function optimise_equivalent_capacities(
    ttc_original::DataFrame,
    ptdf_reduced_results::DataFrame;
    Type::String = CONFIG.optimisation_type,
    lambda::Float64 = CONFIG.lambda,
    gamma_C::Float64 = CONFIG.miqp_gamma_C,
    optimizer_factory = CONFIG.miqp_optimizer,
    dc_cap_map::Dict{Tuple{Int,Int},Float64} = Dict{Tuple{Int,Int},Float64}(),
    high_res_node_ids::Set{Int} = Set{Int}(),
    phys_line_caps::Dict{Tuple{Int,Int},Float64} = Dict{Tuple{Int,Int},Float64}(),
    rep_node_ids::Vector{Int} = sort!(
        unique(
            vcat(ptdf_reduced_results.synth_line_from, ptdf_reduced_results.synth_line_to),
        ),
    ),
    reduced_ybus::Union{Nothing,SparseMatrixCSC{ComplexF64}} = nothing,
    solver_diagnostics_path::Union{Nothing,String} = nothing,
)
    println("\n--- OPTIMISING EQUIVALENT CAPACITIES (Type: $Type) ---")

    # Display selected solver based on optimisation type

    if Type == "MIQP"
        println("MIQP: squared relative error with conservative binding lines")
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

    # Get unique synthetic lines from PTDF results. Virtual-line filtering has
    # already been applied to the network these PTDFs were computed on.
    synth_lines_df = unique(ptdf_reduced_results, [:synth_line_from, :synth_line_to])
    # Keep physical edges even when none of the enumerated transactions uses
    # them (e.g. retained high-resolution islands).
    if !isnothing(reduced_ybus)
        size(reduced_ybus) == (length(rep_node_ids), length(rep_node_ids)) ||
            throw(ArgumentError("reduced_ybus dimensions must match rep_node_ids"))
        allunique(rep_node_ids) || throw(ArgumentError("rep_node_ids must be unique"))
        synth_lines_df = DataFrame(synth_line_from = Int[], synth_line_to = Int[])
        for j in axes(reduced_ybus, 2), k in nzrange(reduced_ybus, j)
            i = rowvals(reduced_ybus)[k]
            if i < j && abs(imag(nonzeros(reduced_ybus)[k])) > 1e-10
                push!(synth_lines_df, (rep_node_ids[i], rep_node_ids[j]))
            end
        end
    end
    println("Candidate synthetic lines: $(nrow(synth_lines_df))")

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
                fixed_caps[idx] =
                    haskey(phys_line_caps, (u, v)) || haskey(phys_line_caps, (v, u)) ? cap :
                    1e6
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
    rn_ids = rep_node_ids
    all_high_res = !isempty(rn_ids) && all(in(high_res_node_ids), rn_ids)

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
                !all_high_res &&
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
    PTDF_full = Dict{Tuple{Int,Int},Float64}()
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
                val > 0.0 && (PTDF_full[(t, l)] = val)
                if val > epsilon
                    PTDF[(t, l)] = val
                end
            end
        end
    end

    # Equivalent AC synthetic capacities should fit the AC TTC component. DC
    # interconnector capacity is exported separately and added back when the
    # equivalent TTC is evaluated below. Optimising the AC network against
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
    relevant_lines_full_per_txn = [[l for l in L if haskey(PTDF_full, (t, l))] for t in TR]

    # Precompute transactions for each line
    relevant_txns_per_line = [Int[] for _ in L]
    for t in TR
        for l in relevant_lines_per_txn[t]
            push!(relevant_txns_per_line[l], t)
        end
    end

    # Per-transaction additive DC capacity (0.0 when no DC capacity applies).
    # Optimisation fits the AC component only; this value is added back when
    # the equivalent TTC is evaluated.
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
    # Only the capacities are taken from the solver. Its TTC variable is a
    # lower bound on the network's TTC and is not reported (see docstring).
    if Type == "QP"
        model, _ = _solve_qp_model(
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
        model, _ = _solve_miqp_model(
            ttc_orig_ac,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            relevant_txns_per_line,
            dc_floor;
            gamma_C,
            optimizer_factory,
            fixed_caps,
            ptdf_full = PTDF_full,
            relevant_lines_full_per_txn = relevant_lines_full_per_txn,
            binding_candidates_per_txn = CONFIG.miqp_binding_candidates_per_txn,
            time_limit_sec = CONFIG.miqp_time_limit_sec,
            mip_rel_gap = CONFIG.miqp_mip_rel_gap,
        )

    elseif Type == "LP"
        model, _ = _solve_lp_model(
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

    # ------------------------------------------------------------
    # 3. EXTRACT CAPACITIES AND EVALUATE THE EQUIVALENT TTC
    # ------------------------------------------------------------
    C_vals = _capacity_values(model)
    if !isnothing(solver_diagnostics_path) && haskey(model.ext, :solver_diagnostics)
        CSV.write(solver_diagnostics_path, DataFrame([model.ext[:solver_diagnostics]]))
    end
    _, ttc_eq_total, binding_dict = _compute_equivalent_ttc(
        C_vals,
        synth_lines,
        TR,
        Type == "MIQP" ? PTDF_full : PTDF,
        Type == "MIQP" ? relevant_lines_full_per_txn : relevant_lines_per_txn,
        dc_floor,
        ttc_orig_ac,
    )

    equivalent_capacities = _extract_capacities(model, synth_lines, L, Type)
    ttc_equivalent_results =
        create_ttc_results_from_optimisation(ttc_eq_total, ttc_canonical; binding_dict)
    if Type == "MIQP"
        calibrated = Set(model.ext[:calibrated_transaction_ids])
        ttc_equivalent_results[!, :in_calibration] = [t in calibrated for t in TR]
    end

    return equivalent_capacities, ttc_equivalent_results
end

# ------------------------------------------------------------
# EQUIVALENT TTC: TTC_eq[t] = min_l C_eq[l] / |PTDF[t,l]|, evaluated from the
# final capacities (plus additive DC capacity).
# ------------------------------------------------------------

function _compute_equivalent_ttc(
    C_vals::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    dc_floor::Vector{Float64},
    ttc_ac_orig::Vector{Float64},
)
    ttc_ac = Vector{Float64}(undef, length(TR))
    ttc_total = Vector{Float64}(undef, length(TR))
    binding_dict = Dict{Int,Tuple{Int,Int}}()

    for t in TR
        if !isfinite(ttc_ac_orig[t])
            # No AC path in the original network. A DC bridge contributes its
            # capacity directly; otherwise the total TTC remains infinite.
            ttc_ac[t] = Inf
            ttc_total[t] = dc_floor[t] > 0.0 ? dc_floor[t] : Inf
            continue
        end

        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            # Finite AC original TTC but no reduced AC PTDF support. This is an
            # honest unsupported-topology outcome; DC, if present, is still
            # represented by dc_floor in the total TTC.
            ttc_ac[t] = 0.0
            ttc_total[t] = dc_floor[t]
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

        ttc_ac[t] = max(0.0, best_val)
        ttc_total[t] = ttc_ac[t] + dc_floor[t]
        if best_line != 0
            binding_dict[t] = synth_lines[best_line]
        end
    end

    return ttc_ac, ttc_total, binding_dict
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
    #    equivalent TTC is evaluated.
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

    primal_status(model) == MathOptInterface.FEASIBLE_POINT ||
        error("QP did not find a feasible solution; refusing to export capacities.")

    # Extract results. Clamp to zero: transactions pinned by an equality
    # constraint (no relevant synthetic line) can land at a tiny negative
    # value (e.g. -1e-50) from solver tolerance rather than exactly 0.0.
    TTC_vals_raw = value.(model[:TTC_eq])
    TTC_vals = [max(0.0, TTC_vals_raw[t]) for t in TR]

    binding_dict = nothing

    return model, TTC_vals, binding_dict
end

# MIQP: conservative relative squared-error capacity fitting.

function _conservative_capacity_start(ttc_orig, C_ref, Tf, PTDF, relevant_lines_per_txn)
    envelope =
        [minimum(C_ref[l] / PTDF[(t, l)] for l in relevant_lines_per_txn[t]) for t in Tf]
    alpha = min(1.0, minimum(ttc_orig[t] / envelope[i] for (i, t) in enumerate(Tf)))
    best_ttc = alpha .* envelope
    # Bound memory for larger cases. The scalar start remains available.
    if length(Tf) * length(C_ref) <= 5_000_000
        requirement = zeros(length(Tf), length(C_ref))
        for (i, t) in enumerate(Tf), l in relevant_lines_per_txn[t]
            requirement[i, l] = PTDF[(t, l)] * ttc_orig[t]
        end
        ratios = envelope ./ ttc_orig[Tf]
        # Each step makes the most overestimated transaction conservative by
        # lowering one branch. Choose the branch with the smallest resulting
        # total squared underestimation. Lowering capacities never uncovers a
        # previously conservative transaction, so at most |Tf| steps are needed.
        trial = similar(ratios)
        for _ in eachindex(Tf)
            i = argmax(ratios)
            ratios[i] <= 1.0 + 1e-10 && break
            best_score, best_line = Inf, 0
            for l in relevant_lines_per_txn[Tf[i]]
                score = 0.0
                c = requirement[i, l]
                for j in eachindex(Tf)
                    ratio =
                        requirement[j, l] > 0 ? min(ratios[j], c / requirement[j, l]) :
                        ratios[j]
                    score += min(ratio - 1.0, 0.0)^2
                end
                if score < best_score
                    best_score, best_line = score, l
                end
            end
            c = requirement[i, best_line]
            for j in eachindex(Tf)
                trial[j] =
                    requirement[j, best_line] > 0 ?
                    min(ratios[j], c / requirement[j, best_line]) : ratios[j]
            end
            ratios .= trial
        end
        if maximum(ratios) <= 1.0 + 1e-9 &&
           sum((ratios .- 1.0) .^ 2) < sum((best_ttc ./ ttc_orig[Tf] .- 1.0) .^ 2)
            best_ttc = min.(ratios, 1.0) .* ttc_orig[Tf]
        end
    end
    capacities = zeros(length(C_ref))
    for (i, t) in enumerate(Tf), l in relevant_lines_per_txn[t]
        capacities[l] = max(capacities[l], PTDF[(t, l)] * best_ttc[i])
    end
    return capacities, Dict(t => best_ttc[i] for (i, t) in enumerate(Tf))
end

"""
If branch l binds transaction t, C_l <= p[t,l] * target[t]. Every transaction
s loading l then has TTC[s]/target[s] <= (p[t,l]*target[t])/(p[s,l]*target[s]).
Summing the unavoidable squared shortfalls gives an objective lower bound for
that binding choice. Sorted suffix sums evaluate all these bounds efficiently.
"""
function _binding_objective_bounds(ttc_orig, Tf, PTDF, relevant_txns_per_line)
    calibrated = Set(Tf)
    bounds = Dict{Tuple{Int,Int},Float64}()
    for (l, transactions) in enumerate(relevant_txns_per_line)
        entries = sort(
            [(PTDF[(t, l)] * ttc_orig[t], t) for t in transactions if t in calibrated];
            by = first,
        )
        inverse_sum, inverse_square_sum = 0.0, 0.0
        m = length(entries)
        for k = m:-1:1
            q, t = entries[k]
            bounds[(t, l)] = max(0.0, (m - k) - 2q * inverse_sum + q^2 * inverse_square_sum)
            inverse_sum += 1 / q
            inverse_square_sum += 1 / q^2
        end
    end
    return bounds
end

"""
Literal binding-branch MIQP, solved directly with the configured MIQP solver.

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
    gamma_C::Float64 = CONFIG.miqp_gamma_C,
    optimizer_factory = CONFIG.miqp_optimizer,
    fixed_caps::Dict{Int,Float64} = Dict{Int,Float64}(),
    ptdf_full::Dict{Tuple{Int,Int},Float64} = PTDF,
    relevant_lines_full_per_txn::Vector{Vector{Int}} = relevant_lines_per_txn,
    calibrated_mask::AbstractVector{Bool} = trues(length(TR)),
    binding_candidates_per_txn::Int = CONFIG.miqp_binding_candidates_per_txn,
    time_limit_sec::Float64 = CONFIG.miqp_time_limit_sec,
    mip_rel_gap::Float64 = CONFIG.miqp_mip_rel_gap,
    safe_binding_screening::Bool = CONFIG.miqp_safe_binding_screening,
)
    println("Setting up binding-line MIQP model...")
    gamma_C >= 1.0 || throw(ArgumentError("gamma_C must be at least 1"))
    binding_candidates_per_txn >= 0 ||
        throw(ArgumentError("Use 0 for all binding candidates, or a positive count"))

    is_optimised(l) = !haskey(fixed_caps, l)

    # ------------------------------------------------------------------
    # Calibration set T_f (Section III-E, "not all transactions are
    # calibrated"): finite, strictly positive AC target, and loads at
    # least one optimisable branch.
    # ------------------------------------------------------------------
    Tf = [
        t for t in TR if isfinite(ttc_orig[t]) &&
            ttc_orig[t] > 0.0 &&
            calibrated_mask[t] &&
            any(is_optimised, relevant_lines_per_txn[t])
    ]
    Tf_set = Set(Tf)
    # Empty calibration sets still export fixed physical or DC-only networks.

    # ------------------------------------------------------------------
    # Reference capacity C_ref[l]: largest requirement any calibrated
    # transaction places on branch l at its ORIGINAL target. Evaluated in
    # a single pass over the PTDF data.
    # ------------------------------------------------------------------
    C_ref = zeros(Float64, length(L))
    for t in Tf, l in relevant_lines_per_txn[t]
        C_ref[l] = max(C_ref[l], PTDF[(t, l)] * ttc_orig[t])
    end

    # Capacity bound / big-M. Fixed branches use their fixed rating

    C_max = Dict{Int,Float64}()
    M = Dict{Int,Float64}()
    for l in L
        if haskey(fixed_caps, l)
            M[l] = fixed_caps[l]
        else
            # Tiny floor keeps a branch untouched by any calibrated
            # transaction well-posed rather than pinned to exactly zero.
            C_max[l] = gamma_C * max(C_ref[l], 1e-8)
            M[l] = C_max[l]
        end
    end

    start_caps, start_ttc = nothing, nothing
    start_objective = Inf
    binding_bounds = Dict{Tuple{Int,Int},Float64}()
    if isempty(fixed_caps) && binding_candidates_per_txn == 0 && !isempty(Tf)
        start_caps, start_ttc =
            _conservative_capacity_start(ttc_orig, C_ref, Tf, PTDF, relevant_lines_per_txn)
        start_objective = sum((start_ttc[t] / ttc_orig[t] - 1)^2 for t in Tf)
        if safe_binding_screening
            binding_bounds =
                _binding_objective_bounds(ttc_orig, Tf, PTDF, relevant_txns_per_line)
        end
    end

    model = Model(optimizer_factory)
    model.ext[:calibrated_transaction_ids] = Tf
    name = solver_name(model)
    set_silent(model)
    time_limit_sec > 0.0 && set_time_limit_sec(model, time_limit_sec)
    gap_attribute = MathOptInterface.RelativeGapTolerance()
    if MathOptInterface.supports(JuMP.backend(model), gap_attribute)
        set_optimizer_attribute(model, gap_attribute, mip_rel_gap)
    else
        @warn "$name does not accept a relative gap tolerance; set it through " *
              "CONFIG.miqp_optimizer_attributes."
    end
    # A tight feasibility tolerance keeps the big-M binding equalities accurate
    # enough for the post-solve consistency check. For other solvers, set the
    # equivalent tolerance through CONFIG.miqp_optimizer_attributes.
    occursin("SCIP", uppercase(name)) &&
        set_optimizer_attribute(model, "numerics/feastol", 1e-9)
    for (attribute, setting) in CONFIG.miqp_optimizer_attributes
        set_optimizer_attribute(model, attribute, setting)
    end

    # C_k, (31f)
    @variable(model, C_eq[l in L] >= 0)
    for l in L
        if haskey(fixed_caps, l)
            fix(C_eq[l], fixed_caps[l]; force = true)
        else
            set_upper_bound(C_eq[l], C_max[l])
        end
    end

    # TTC_eq[t], bounded per-transaction by the original AC target.
    # Transactions outside T_f carry no AC fitting target here; their
    # true AC transfer capacity is recovered downstream from the final
    # exported capacities, independent of this variable.
    @variable(model, TTC_eq[t in TR] >= 0)
    for t in TR
        if t in Tf_set
            set_upper_bound(TTC_eq[t], ttc_orig[t])
        else
            fix(TTC_eq[t], 0.0; force = true)
        end
    end

    # Binary binding indicators b[t,l], pruned to kappa candidates
    # per transaction. Candidates are drawn from the FULL
    # relevant set K_t (fixed and optimisable branches alike).
    b = Dict{Tuple{Int,Int},VariableRef}()
    binding_candidates = Dict{Int,Vector{Int}}()
    for t in Tf
        rel_lines = relevant_lines_per_txn[t]
        candidates =
            if binding_candidates_per_txn == 0 ||
               length(rel_lines) <= binding_candidates_per_txn
                rel_lines
            else
                sorted = sort(rel_lines; by = l -> C_ref[l] / max(PTDF[(t, l)], 1e-12))
                sorted[1:binding_candidates_per_txn]
            end
        if !isempty(binding_bounds)
            # The margin retains borderline choices despite floating-point
            # cancellation in suffix sums; this is not heuristic top-k pruning.
            candidates = filter(
                l ->
                    binding_bounds[(t, l)] <=
                    start_objective + 1e-6 * max(1.0, start_objective),
                candidates,
            )
            isempty(candidates) &&
                error("Objective screening removed every binding choice for transaction $t")
        end
        binding_candidates[t] = candidates
        for l in candidates
            b[(t, l)] = @variable(model, binary = true, base_name = "b[$t,$l]")
        end
    end
    model[:b_bind] = b

    # Objective: normalised squared mismatch over T_f only.
    @objective(model, Min, sum((TTC_eq[t] / ttc_orig[t] - 1)^2 for t in Tf))

    # Constraint: thermal feasibility over the full relevant set K_t.
    for t in Tf, l in relevant_lines_per_txn[t]
        @constraint(model, PTDF[(t, l)] * TTC_eq[t] <= C_eq[l])
    end

    # Constraint: exactly one binding branch, converted to an
    # equality via the branch-wise big-M M[l].
    for t in Tf
        candidates = binding_candidates[t]
        @constraint(model, sum(b[(t, l)] for l in candidates) == 1)
        for l in candidates
            @constraint(model, C_eq[l] - PTDF[(t, l)] * TTC_eq[t] <= M[l] * (1 - b[(t, l)]))
        end
    end

    # A complete feasible start for the unrestricted, all-optimised model.
    # Scale the target envelope until every recomputed TTC is conservative,
    # then close capacities over those TTCs. Unlike (C_ref, original TTC),
    # this start satisfies the binding equalities as well as thermal limits.
    if !isnothing(start_caps)
        for l in L
            set_start_value(C_eq[l], start_caps[l])
        end
        for t in Tf
            set_start_value(TTC_eq[t], start_ttc[t])
            binding = argmin(l -> start_caps[l] / PTDF[(t, l)], relevant_lines_per_txn[t])
            for l in binding_candidates[t]
                set_start_value(b[(t, l)], l == binding ? 1.0 : 0.0)
            end
        end
        println(
            "Feasible envelope warm start: relative squared error = ",
            sum((start_ttc[t] / ttc_orig[t] - 1)^2 for t in Tf),
        )
    end

    n_binaries = length(b)
    n_relevant = sum((length(relevant_lines_per_txn[t]) for t in Tf); init = 0)
    println(
        "Solving MIQP with $name ($(length(Tf))/$(length(TR)) calibrated transactions, " *
        "$(length(L)) lines, $n_relevant physical constraints, " *
        "$n_binaries binding binaries)...",
    )
    optimize!(model)

    status = termination_status(model)
    println("MIQP status: $status")

    usable_status = status in [
        MathOptInterface.OPTIMAL,
        MathOptInterface.ALMOST_OPTIMAL,
        MathOptInterface.TIME_LIMIT,
    ]
    if !usable_status
        @warn "Unexpected MIQP termination status: $status"
    end
    if primal_status(model) != MathOptInterface.FEASIBLE_POINT
        error("MIQP did not find a feasible solution.")
    end
    model.ext[:solver_diagnostics] = (
        solver = name,
        termination_status = string(status),
        primal_status = string(primal_status(model)),
        objective = objective_value(model),
        objective_bound = objective_bound(model),
        relative_gap = relative_gap(model),
        solve_time_sec = solve_time(model),
        time_limit_sec = time_limit_sec,
        requested_relative_gap = mip_rel_gap,
        calibrated_transactions = length(Tf),
        synthetic_lines = length(L),
        binding_binaries = n_binaries,
        binding_candidates_per_txn = binding_candidates_per_txn,
        safe_binding_screening = safe_binding_screening,
        relevant_binding_choices_before_screening = n_relevant,
        initial_feasible_objective = start_objective,
        # Makes the MIQP's margin over the greedy conservative construction
        # explicit. A small margin does not invalidate the model, but the value
        # the MIQP adds is then the certified optimality gap rather than a large
        # objective improvement, and should be reported as such.
        improvement_over_heuristic_start_pct = isfinite(start_objective) &&
                                               start_objective > 0.0 ?
                                               100 * (
            start_objective - objective_value(model)
        ) / start_objective : NaN,
        errors_one_sided_by_construction = true,
        calibration_subset_active = !all(calibrated_mask),
    )
    println("Capacity-fit diagnostics: ", model.ext[:solver_diagnostics])

    TTC_star = [max(0.0, value(TTC_eq[t])) for t in TR]

    # ------------------------------------------------------------------
    deterministic_caps = collect(value.(C_eq))
    for l in L
        haskey(fixed_caps, l) && continue
        # Close over ptdf_full rather than the epsilon-filtered set. A branch
        # whose sensitivities all sit below epsilon is weakly coupled, not
        # absent: maximising over the filtered set returns an empty maximum and
        # exports 0 MW, which blocks that branch for any consumer applying a
        # tighter cutoff. The full closure gives it the smallest rating that
        # supports every fitted transfer and cannot change any TTC, because
        # C_l >= g_lt * TTC_t then holds for every loaded transaction.
        best = 0.0
        loaded = false
        for t in Tf
            g = get(ptdf_full, (t, l), 0.0)
            if g > 0.0
                best = max(best, g * TTC_star[t])
                loaded = true
            end
        end
        deterministic_caps[l] = loaded ? best : C_ref[l]
    end
    n_zero = count(l -> !haskey(fixed_caps, l) && deterministic_caps[l] <= 0.0, L)
    n_zero == 0 || @warn "$n_zero synthetic branches carry no calibrated load even at " *
          "full PTDF resolution and are exported with a zero rating. Review whether they " *
          "should be dropped from the equivalent together with their admittance."

    # Do not solve a second fixed-capacity problem: its OPTIMAL status says
    # nothing about the original MIQP gap and would reset the time allowance.
    #
    # Verify the EXPORTED artifact over the full sensitivity set a downstream
    # user would apply, not merely over the epsilon-filtered fit set. Checking
    # only the fit set is what allowed a zero-rated weakly-coupled branch to
    # pass validation while blocking transfers for any tighter cutoff.
    for t in Tf
        physical = minimum(
            deterministic_caps[l] / ptdf_full[(t, l)] for
            l in relevant_lines_full_per_txn[t]
        )
        isapprox(physical, TTC_star[t]; atol = 1e-6, rtol = 1e-6) || error(
            "Binding consistency failed for transaction $t: fitted=$(TTC_star[t]), recomputed=$physical",
        )
        physical <= ttc_orig[t] + 1e-6 * max(1.0, ttc_orig[t]) ||
            error("Conservativeness violated for transaction $t")
    end
    model.ext[:deterministic_capacities] = deterministic_caps

    TTC_vals = [max(0.0, value(TTC_eq[t])) for t in TR]
    binding_dict = _extract_miqp_binding(model, relevant_lines_per_txn, synth_lines, Tf)

    return model, TTC_vals, binding_dict
end

# ------------------------------------------------------------
# Recompute the MIQP binding-line dictionary from the current binary
# variable values so the exported "limiting synthetic line" reflects the
# final MIQP solution.
# ------------------------------------------------------------
function _extract_miqp_binding(
    model::Model,
    relevant_lines_per_txn::Vector{Vector{Int}},
    synth_lines::Vector{Tuple{Int,Int}},
    TR::AbstractVector{<:Integer},
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

function _capacity_values(model::Model)
    return haskey(model.ext, :deterministic_capacities) ?
           model.ext[:deterministic_capacities] : max.(0.0, collect(value.(model[:C_eq])))
end

function _extract_capacities(model::Model, synth_lines, L, Type = CONFIG.optimisation_type)
    if isempty(L) || length(synth_lines) == 0
        println("\n=== $Type Optimisation Results ===")
        println("No lines in reduced network → returning empty equivalent capacities")
        return DataFrame(
            synth_line_from = Int[],
            synth_line_to = Int[],
            C_eq_pu = Float64[],
        )
    end

    C_vals = _capacity_values(model)

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
    create_ttc_results_from_optimisation(ttc_eq_total, ttc_canonical; binding_dict)

Build the equivalent-TTC result table from the TTC of the exported network
(`TTC_eq = min C_eq/|PTDF| + DC`, see `_compute_equivalent_ttc`) and the
limiting synthetic line of each transaction.
"""
function create_ttc_results_from_optimisation(
    ttc_eq_total::Vector{Float64},
    ttc_canonical::DataFrame;
    binding_dict::Dict{Int,Tuple{Int,Int}} = Dict{Int,Tuple{Int,Int}}(),
)
    n_txn = length(ttc_eq_total)
    @assert n_txn == nrow(ttc_canonical) "TTC size mismatch"

    ttc_results = DataFrame(
        transaction_from = ttc_canonical.transaction_from,
        transaction_to = ttc_canonical.transaction_to,
        TTC_Equivalent_pu = ttc_eq_total,
    )

    binding_from = fill(0, n_txn)
    binding_to = fill(0, n_txn)
    for (t, (from, to)) in binding_dict
        binding_from[t] = from
        binding_to[t] = to
    end
    ttc_results[!, :limiting_synth_line_from] = binding_from
    ttc_results[!, :limiting_synth_line_to] = binding_to

    # Error statistics over transactions with a finite original TTC
    err = ttc_eq_total .- ttc_canonical.TTC_pu
    finite_err = err[isfinite.(ttc_canonical.TTC_pu)]
    println("\nTTC matching accuracy ($(length(finite_err)) finite-TTC transactions):")
    if isempty(finite_err)
        println("  No finite-TTC transactions to compare.")
    else
        println("  Max |error|  = $(round(maximum(abs, finite_err); digits=6)) pu")
        println("  Mean |error| = $(round(mean(abs, finite_err); digits=6)) pu")
    end

    println("\nSample TTC comparisons (first 5 transactions):")
    for t = 1:min(5, n_txn)
        println(
            "  T$t: Original=$(round(ttc_canonical.TTC_pu[t]; digits=6)), " *
            "Equivalent=$(round(ttc_eq_total[t]; digits=6)), " *
            "Error=$(round(err[t]; digits=6))",
        )
    end

    return ttc_results
end
