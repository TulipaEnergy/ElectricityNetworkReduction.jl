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
"""
function kron_reduce_ybus(Ybus::SparseMatrixCSC{ComplexF64}, rep_node_ids::Vector{Int})
    N = size(Ybus, 1)

    if isempty(rep_node_ids) || length(rep_node_ids) >= N
        error(
            "Invalid set of representative nodes for Kron reduction. Need at least one non-representative node.",
        )
    end

    N_R = length(rep_node_ids)
    RN_set = Set(rep_node_ids)
    NE_set = setdiff(1:N, RN_set)
    NE_ids = collect(NE_set)

    # Create the permutation vector: [RN_nodes, NE_nodes]
    perm = vcat(rep_node_ids, NE_ids)
    Ybus_permuted = Ybus[perm, perm]

    K = Ybus_permuted[1:N_R, 1:N_R]
    L = Ybus_permuted[N_R+1:end, 1:N_R]
    L_T = Ybus_permuted[1:N_R, N_R+1:end]
    M = Ybus_permuted[N_R+1:end, N_R+1:end]

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
