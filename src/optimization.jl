# --- OPTIMIZATION FUNCTIONS ---

"""
    optimize_equivalent_capacities(

    ttc_original::DataFrame,
    ptdf_reduced_results::DataFrame;
    Type::String = CONFIG.optimization_type,
    lambda::Float64 = CONFIG.lambda,
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0
    )

Optimize equivalent capacities for the reduced network using QP, MIQP, or LP.

This function solves an optimization problem to find synthetic line capacities
for the reduced network that best match the original network's TTC values.

# Arguments
- `ttc_original::DataFrame`: Original network TTC values
- `ptdf_reduced_results::DataFrame`: PTDF results from reduced network
- `Type::String`: Optimization type: "QP", "MIQP", or "LP"
- `bigM_factor::Float64`: Factor for big-M constraints (MIQP only)
- `lambda::Float64`: Regularization parameter for capacity smoothing

# Returns
- `equivalent_capacities::DataFrame`: Optimized synthetic line capacities

# Mathematical Formulation

## QP/LP Formulation:
Minimize: Σ(TTC_eq[t] - TTC_orig[t])² + λ*Σ(C_eq[l]²)  (QP)
or
Maximize: Σ TTC_eq[t] (LP with TTC_eq[t] ≤ TTC_orig[t])
Subject to: TTC_eq[t] ≤ C_eq[l] / |PTDF[t,l]| for all transactions t and lines l

## MIQP (Linearized as MILP) Formulation:
Minimize: Σ |TTC_eq[t] - TTC_orig[t]|  (L1 Norm for matching)
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

function optimize_equivalent_capacities(
    ttc_original::DataFrame,
    ptdf_reduced_results::DataFrame;
    Type::String = CONFIG.optimization_type,
    lambda::Float64 = CONFIG.lambda,
    bigM_factor::Float64 = 5.0,
    max_C_factor::Float64 = 3.0,
)
    println("\n--- OPTIMIZING EQUIVALENT CAPACITIES (Type: $Type) ---")

    # Display selected solver based on optimization type
    # Map MIQP to MILP

    if Type == "MIQP"
        println("Note: MIQP converted to MILP (linearized)")
    end
    println("Selected solver: Ipopt")

    # ------------------------------------------------------------
    # 1. DATA PREPARATION (COMMON FOR ALL MODELS)
    # ------------------------------------------------------------

    # Get unique synthetic lines
    synth_lines_df = unique(ptdf_reduced_results, [:synth_line_from, :synth_line_to])

    synth_lines = Tuple{Int,Int}[]
    synth_line_map = Dict{Tuple{Int,Int},Int}()

    for row in eachrow(synth_lines_df)
        u, v = min(row.synth_line_from, row.synth_line_to),
        max(row.synth_line_from, row.synth_line_to)
        key = (u, v)
        if !haskey(synth_line_map, key)
            push!(synth_lines, key)
            synth_line_map[key] = length(synth_lines)
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

    # Filter canonical transactions (from reduced network only)
    ttc_canonical = filter(
        r ->
            (r.transaction_from in rn_ids) &&
                (r.transaction_to in rn_ids) &&
                (r.transaction_from < r.transaction_to),
        ttc_original,
    )

    TR = 1:nrow(ttc_canonical)  # Transaction indices

    println("Synthetic lines: $(length(L))")
    println("Canonical transactions: $(length(TR))")

    # Create PTDF lookup dictionary: (t,l) → |PTDF|
    PTDF = Dict{Tuple{Int,Int},Float64}()
    epsilon = CONFIG.ptdf_epsilon

    for (t, row) in enumerate(eachrow(ttc_canonical))
        a, b = row.transaction_from, row.transaction_to

        # Get all PTDF entries for this transaction
        txn_rows = filter(
            r -> r.transaction_from_orig == a && r.transaction_to_orig == b,
            ptdf_reduced_results,
        )

        for r in eachrow(txn_rows)
            # Use canonical line ordering
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

    ttc_orig = ttc_canonical.TTC_pu  # Original TTC values

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

    # ------------------------------------------------------------
    # 2. MODEL SELECTION AND SETUP
    # ------------------------------------------------------------
    binding_dict = nothing
    if Type == "QP"
        model, TTC_vals = _solve_qp_model(
            ttc_orig,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            lambda,
        )

    elseif Type == "MIQP"
        model, TTC_vals, binding_dict = _solve_miqp_model(
            ttc_orig,
            synth_lines,
            L,
            TR,
            PTDF,
            relevant_lines_per_txn,
            relevant_txns_per_line;
            bigM_factor,
            max_C_factor,
        )

    elseif Type == "LP"
        model, TTC_vals, binding_dict =
            _solve_lp_model(ttc_orig, synth_lines, L, TR, PTDF, relevant_lines_per_txn)

    else
        error("Invalid Type: $Type. Choose from: QP, MIQP, LP")
    end

    # ------------------------------------------------------------
    # 3. EXTRACT BOTH CAPACITIES AND TTC RESULTS
    # ------------------------------------------------------------

    # Extract equivalent capacities
    equivalent_capacities = _extract_capacities(model, synth_lines, L, TR, ttc_orig, Type)

    # Create TTC results directly from optimization variables
    ttc_equivalent_results = create_ttc_results_from_optimization(
        TTC_vals,
        ttc_canonical,
        model = model,
        Type = Type,
        synth_lines = synth_lines,
        binding_dict = binding_dict,
    )

    return equivalent_capacities, ttc_equivalent_results
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
)
    println("Setting up QP model...")

    # Use Ipopt for QP
    model = Model(Ipopt.Optimizer)

    # Ipopt-specific settings
    set_silent(model)  # Suppress output

    # Variables
    @variable(model, C_eq[l in L] >= 0)           # Equivalent capacities
    @variable(model, TTC_eq[t in TR] >= 0)        # Equivalent TTCs
    @variable(model, V_mismatch[t in TR])         # TTC mismatches

    # Objective: Minimize squared error with regularization
    @objective(
        model,
        Min,
        sum(V_mismatch[t]^2 for t in TR) + lambda * sum(C_eq[l]^2 for l in L)
    )

    # Constraints
    # 1. Mismatch definition
    @constraint(model, [t in TR], V_mismatch[t] == TTC_eq[t] - ttc_orig[t])

    # 2. Physical constraints: TTC cannot exceed capacity/PTDF ratio
    for t in TR
        for l in relevant_lines_per_txn[t]
            @constraint(model, TTC_eq[t] <= C_eq[l] / PTDF[(t, l)])
        end
    end

    # Solve
    optimize!(model)

    status = termination_status(model)
    println("QP status: $status")

    if status != MathOptInterface.OPTIMAL
        println("Warning: QP solution status: $status")
    end

    # Extract results
    TTC_vals_raw = value.(model[:TTC_eq])
    TTC_vals = [TTC_vals_raw[t] for t in TR]

    binding_dict = nothing

    return model, TTC_vals, binding_dict
end

# ------------------------------------------------------------
# MIQP MODEL IMPLEMENTATION
# ------------------------------------------------------------
"""
Linearized MILP formulation using Ipopt that enforces **exactly one binding line** per transaction.
Objective: minimize sum of absolute TTC errors (L1 norm).

"""
function _solve_miqp_model(
    ttc_orig::Vector{Float64},
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    PTDF::Dict{Tuple{Int,Int},Float64},
    relevant_lines_per_txn::Vector{Vector{Int}},
    relevant_txns_per_line::Vector{Vector{Int}};
    bigM_factor::Float64 = 5.0,   # Add this parameter
    max_C_factor::Float64 = 3.0,
)
    println(
        "Setting up linearized MILP model (Ipopt) — exactly one binding line per transaction",
    )

    # ── Safeguards & big-M computation ──────────────────────────────────────
    max_ttc = isempty(ttc_orig) ? 1.0 : maximum(ttc_orig)
    max_ptdf = isempty(PTDF) ? 1.0 : maximum(abs.(values(PTDF))) + 1e-9
    bigM_ttc = bigM_factor * max_ttc
    bigM_Z = bigM_factor * max_ttc * max_ptdf
    C_ub = max_C_factor * max_ttc * max_ptdf

    # ── Model ───────────────────────────────────────────────────────────────
    model = Model(Ipopt.Optimizer)
    set_silent(model)


    # ── Variables ───────────────────────────────────────────────────────────
    @variable(model, 0 ≤ C_eq[l in L] ≤ C_ub)

    @variable(model, TTC_eq[t in TR] ≥ 0)

    # Sparse (t,l) variables — only for relevant pairs
    Z = Dict{Tuple{Int,Int},VariableRef}()
    b = Dict{Tuple{Int,Int},VariableRef}()

    for t in TR, l in relevant_lines_per_txn[t]
        Z[(t, l)] = @variable(model, lower_bound = 0.0, base_name = "Z[$t,$l]")
        b[(t, l)] = @variable(model, binary = true, base_name = "b[$t,$l]")
    end

    @variable(model, V_abs[t in TR] ≥ 0)

    # ── Objective ───────────────────────────────────────────────────────────
    @objective(model, Min, sum(V_abs[t] for t in TR))

    # ── Constraints ─────────────────────────────────────────────────────────

    # A. L1 error linearization
    for t in TR
        @constraint(model, V_abs[t] ≥ TTC_eq[t] - ttc_orig[t])
        @constraint(model, V_abs[t] ≥ ttc_orig[t] - TTC_eq[t])
    end

    # B. TTC definition = sum (allocated capacity / PTDF)
    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if isempty(rel_lines)
            @constraint(model, TTC_eq[t] == 0.0)
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

    # E. Physical upper bounds on TTC (very important)
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
    TTC_vals = [value(TTC_eq[t]) for t in TR]

    # Extract which line is binding for each transaction
    binding_dict = Dict{Int,Tuple{Int,Int}}()  # t → (from_bus, to_bus)

    for t in TR
        rel_lines = relevant_lines_per_txn[t]
        if !isempty(rel_lines)
            found = false
            for l in rel_lines
                if value(b[(t, l)]) > 0.5
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

    return model, TTC_vals, binding_dict
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
)
    println("Setting up LP model...")

    # Use Ipopt for LP
    model = Model(Ipopt.Optimizer)
    set_silent(model)

    # Variables
    @variable(model, C_eq[l in L] >= 0)           # Equivalent capacities
    @variable(model, TTC_eq[t in TR] >= 0)        # Equivalent TTCs

    # Objective: Maximize total TTC (subject to TTC_eq ≤ TTC_orig)
    @objective(model, Max, sum(TTC_eq[t] for t in TR))

    # Constraints

    # 1. TTC cannot exceed original TTC
    @constraint(model, [t in TR], TTC_eq[t] <= ttc_orig[t])

    # 2. Physical constraints: TTC cannot exceed capacity/PTDF ratio
    for t in TR
        for l in relevant_lines_per_txn[t]
            @constraint(model, TTC_eq[t] <= C_eq[l] / PTDF[(t, l)])
        end
    end

    # Solve
    optimize!(model)

    status = termination_status(model)
    println("LP status: $status")

    if status != MathOptInterface.OPTIMAL
        println("Warning: LP solution status: $status")
        if primal_status(model) == MathOptInterface.FEASIBLE_POINT
            println("But found a feasible solution")
        end
    end

    # Extract results
    TTC_vals = collect(value.(TTC_eq))
    binding_dict = Dict{Int,Tuple{Int,Int}}()

    # Identify binding constraints (where slack is nearly zero)
    for t in TR
        for l in relevant_lines_per_txn[t]
            if abs(value(TTC_eq[t]) - value(C_eq[l]) / PTDF[(t, l)]) < 1e-6
                binding_dict[t] = synth_lines[l]
                break
            end
        end
    end

    return model, TTC_vals, binding_dict
end
# ------------------------------------------------------------
# RESULT EXTRACTION FUNCTION
# ------------------------------------------------------------

function _extract_capacities(
    model::Model,
    synth_lines::Vector{Tuple{Int,Int}},
    L::UnitRange{Int},
    TR::UnitRange{Int},
    ttc_orig::Vector{Float64},
    Type::String = CONFIG.optimization_type,
)
    # Extract only capacities
    C_vals = value.(model[:C_eq])

    equivalent_capacities =
        DataFrame(synth_line_from = Int[], synth_line_to = Int[], C_eq_pu = Float64[])

    for (i, (u, v)) in enumerate(synth_lines)
        push!(equivalent_capacities, (u, v, C_vals[i]))
    end

    # Print statistics
    println("\n=== $Type Optimization Results ===")
    println("C_eq statistics:")
    println("  Min: $(round(minimum(C_vals); digits=6)) pu")
    println("  Max: $(round(maximum(C_vals); digits=6)) pu")
    println("  Mean: $(round(mean(C_vals); digits=6)) pu")
    println("  Std: $(round(std(C_vals); digits=6)) pu")

    return equivalent_capacities
end

"""
    create_ttc_results_from_optimization(
    ttc_vals::Vector{Float64},
    ttc_canonical::DataFrame;
    model=model,
    Type = CONFIG.optimization_type,
    synth_lines::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    binding_dict::Union{Dict,Nothing} = nothing
    )

Create TTC results directly from optimization variables.

"""
function create_ttc_results_from_optimization(
    ttc_vals::Vector{Float64},
    ttc_canonical::DataFrame;
    model = model,
    Type = CONFIG.optimization_type,
    synth_lines::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[],
    binding_dict::Union{Dict,Nothing} = nothing,
)

    n_txn = length(ttc_vals)
    @assert n_txn == nrow(ttc_canonical) "TTC size mismatch"

    # Base results (common for all types)
    ttc_results = DataFrame(
        transaction_from = ttc_canonical.transaction_from,
        transaction_to = ttc_canonical.transaction_to,
        TTC_Equivalent_pu = ttc_vals,
    )

    # ------------------------------------------------------------
    # MIQP / MILP: extract binding lines
    # ------------------------------------------------------------
    if Type in ("MIQP", "MILP")
        binding_from = fill(0, n_txn)
        binding_to = fill(0, n_txn)

        # Simply check the argument passed to the function
        if isnothing(binding_dict)
            @warn "Binding dictionary was not provided to the result extractor."
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

        # ------------------------------------------------------------
        # LP / QP: no binding line concept
        # ------------------------------------------------------------
    else
        ttc_results[!, :limiting_synth_line_from] = zeros(Int, n_txn)
        ttc_results[!, :limiting_synth_line_to] = zeros(Int, n_txn)
    end

    # Calculate error statistics
    err = ttc_vals .- ttc_canonical.TTC_pu
    println("\nTTC matching accuracy:")
    println("  Max |error| = $(round(maximum(abs.(err)); digits=6)) pu")
    println("  Mean |error| = $(round(mean(abs.(err)); digits=6)) pu")
    println("  RMS error  = $(round(sqrt(mean(err.^2)); digits=6)) pu")

    println("\nSample TTC comparisons (first 5 transactions):")
    for t = 1:min(5, length(ttc_vals))
        println(
            "  T$t: Original=$(round(ttc_canonical.TTC_pu[t]; digits=6)), " *
            "Estimated=$(round(ttc_vals[t]; digits=6)), " *
            "Error=$(round(err[t]; digits=6))",
        )
    end

    return ttc_results
end
