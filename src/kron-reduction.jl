# --- KRON REDUCTION FUNCTION ---

"""
    kron_reduce_ybus(Ybus, rep_node_ids)

Perform Kron reduction on the original Ybus matrix to eliminate non-representative nodes.

The Kron reduction technique eliminates internal nodes while preserving the electrical
relationships between the representative nodes. This creates an equivalent network
with fewer nodes but equivalent transfer characteristics.

# Arguments
- `Ybus::SparseMatrixCSC{ComplexF64}`: Original network admittance matrix
- `rep_node_ids::Vector{Int}`: Indices of representative nodes to retain

# Returns
- `Y_kron::SparseMatrixCSC{ComplexF64}`: Reduced admittance matrix

# Mathematical Background
The Kron reduction partitions the admittance matrix as:
```
Y = [K   L_T]
    [L   M  ]
```
where K connects representative nodes, M connects eliminated nodes,
and L connects representative to eliminated nodes.

The reduced matrix is: Y_kron = K - L_T * M^(-1) * L

When every bus is retained (e.g. all zones in `CONFIG.high_res_zones`) there is
nothing to eliminate and the matrix is returned reordered to `rep_node_ids`.
"""
function kron_reduce_ybus(Ybus::SparseMatrixCSC{ComplexF64}, rep_node_ids::Vector{Int})
    N = size(Ybus, 1)

    if isempty(rep_node_ids) ||
       !allunique(rep_node_ids) ||
       !all(id -> 1 <= id <= N, rep_node_ids)
        error(
            "Invalid set of representative nodes for Kron reduction: ids must be unique bus ids in 1:$N.",
        )
    end

    N_R = length(rep_node_ids)
    if N_R == N
        println("\nKron reduction: all $(N) buses retained, nothing to eliminate.")
        return Ybus[rep_node_ids, rep_node_ids]
    end
    RN_set = Set(rep_node_ids)
    NE_set = setdiff(1:N, RN_set)
    NE_ids = collect(NE_set)

    # Create the permutation vector: [RN_nodes, NE_nodes]
    perm = vcat(rep_node_ids, NE_ids)
    Ybus_permuted = Ybus[perm, perm]

    K = Ybus_permuted[1:N_R, 1:N_R]
    L = Ybus_permuted[(N_R+1):end, 1:N_R]
    L_T = Ybus_permuted[1:N_R, (N_R+1):end]
    M = Ybus_permuted[(N_R+1):end, (N_R+1):end]

    M_dense = Matrix(M)
    L_dense = Matrix(L)

    # For multi-island networks the AC Y-bus has one zero eigenvalue per island,
    # making M singular. A small shunt regularisation (ε·I) is the standard
    # power-systems technique: it is equivalent to adding a tiny conductance to
    # ground at every eliminated bus, negligibly affecting the electrical solution
    # while making M numerically invertible. This is faster and more accurate
    # than the Moore-Penrose pseudoinverse (which requires a full SVD).
    #
    # M_inv * L is obtained via a direct solve (M \ L) rather than forming the
    # explicit inverse: mathematically equivalent, but noticeably more stable
    # and avoids materialising a dense N_E×N_E inverse just to multiply it away.
    X = try
        M_dense \ L_dense
    catch e
        if isa(e, SingularException)
            n_elim = size(M_dense, 1)
            ε = 1e-8
            @warn "Submatrix M is singular (multi-island network with $(n_elim) " *
                  "eliminated buses). Applying shunt regularisation ε=$(ε) before solving."
            (M_dense + ε * I(n_elim)) \ L_dense
        else
            rethrow(e)
        end
    end

    # Y_kron = K - L_T * (M \ L)
    Y_kron_dense = Matrix(K) - L_T * X
    Y_kron = sparse(Y_kron_dense)

    println("\nKron reduction complete: Original $(N) buses -> Reduced $(N_R) buses.")

    return Y_kron
end

"""
    filter_reduced_network(Y_kron, rep_node_ids, allowed_pairs)

Remove virtual lines from a Kron-reduced DC network. A synthetic line (u, v)
is kept only if `(min(u,v), max(u,v)) ∈ allowed_pairs` (bus ids, not local
indices). Removed lines have their susceptance taken out of both the
off-diagonal and the diagonal terms, so the result is again a DC Laplacian
(zero row sums) describing exactly the network that is exported.

Reduced-network PTDFs must be computed on the returned matrix: PTDFs of the
unfiltered Kron network describe a different network once lines are removed.

If no line would survive, the unfiltered network is returned with a warning.
A warning is also printed when filtering splits an AC island of the reduced
network, since transactions across the split lose their AC transfer path.
"""
function filter_reduced_network(
    Y_kron::SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int},
    allowed_pairs::Set{Tuple{Int,Int}},
)
    B = -imag(Y_kron)
    N_R = size(B, 1)
    tol = 1e-10

    B_f = spzeros(Float64, N_R, N_R)
    g_before = SimpleGraph(N_R)
    g_after = SimpleGraph(N_R)
    n_before = n_after = 0
    for i = 1:N_R, j = (i+1):N_R
        b = -B[i, j]
        abs(b) > tol || continue
        n_before += 1
        add_edge!(g_before, i, j)
        u, v = rep_node_ids[i], rep_node_ids[j]
        (min(u, v), max(u, v)) in allowed_pairs || continue
        n_after += 1
        add_edge!(g_after, i, j)
        B_f[i, j] = B_f[j, i] = -b
        B_f[i, i] += b
        B_f[j, j] += b
    end

    println(
        "Virtual-line filter: kept $(n_after) of $(n_before) synthetic lines " *
        "(all intra-zone + directly connected inter-zone pairs).",
    )

    if n_after == 0
        @warn "No synthetic lines survive the virtual-line filter. " *
              "Keeping the unfiltered Kron network (virtual lines allowed) for this run."
        return Y_kron
    end

    n_split = length(connected_components(g_after)) - length(connected_components(g_before))
    if n_split > 0
        @warn "Virtual-line filtering split the reduced network into $(n_split) more " *
              "AC island(s). Transactions across the split have no AC path in the " *
              "exported network (equivalent AC TTC = 0)."
    end

    return sparse(-im * B_f)
end
