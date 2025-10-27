# --- KRON REDUCTION FUNCTION ---

"""
    kron_reduce_ybus(Ybus, rep_node_ids)

Perform Kron reduction on the original Ybus matrix to eliminate non-representative nodes.

The Kron reduction technique eliminates internal nodes while preserving the electrical
relationships between the representative nodes. This creates an equivalent network
with fewer nodes but equivalent transfer characteristics.

# Arguments
- `Ybus::SparseArrays.SparseMatrixCSC{ComplexF64}`: Original network admittance matrix
- `rep_node_ids::Vector{Int}`: Indices of representative nodes to retain

# Returns
- `Y_kron::SparseArrays.SparseMatrixCSC{ComplexF64}`: Reduced admittance matrix

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
function kron_reduce_ybus(
    Ybus::SparseArrays.SparseMatrixCSC{ComplexF64},
    rep_node_ids::Vector{Int},
)
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
    perm = DataFrames.vcat(rep_node_ids, NE_ids)
    Ybus_permuted = Ybus[perm, perm]

    K = Ybus_permuted[1:N_R, 1:N_R]
    L = Ybus_permuted[N_R+1:end, 1:N_R]
    L_T = Ybus_permuted[1:N_R, N_R+1:end]
    M = Ybus_permuted[N_R+1:end, N_R+1:end]

    M_dense = LinearAlgebra.Matrix(M)

    M_inv = try
        LinearAlgebra.inv(M_dense)
    catch e
        if isa(e, SingularException)
            @warn "Submatrix M for Kron reduction is singular, using pseudoinverse (pinv)."
            LinearAlgebra.pinv(M_dense)
        else
            rethrow(e)
        end
    end

    # Y_kron = K - L_T * M_inv * L
    Y_kron_dense = LinearAlgebra.Matrix(K) - L_T * M_inv * L
    Y_kron = SparseArrays.sparse(Y_kron_dense)

    println("\nKron reduction complete: Original $(N) buses -> Reduced $(N_R) buses.")

    return Y_kron
end
