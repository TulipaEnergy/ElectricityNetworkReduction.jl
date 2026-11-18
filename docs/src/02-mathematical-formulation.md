# Mathematical formulation

This document summarises the mathematical foundations of
**ElectricityNetworkReduction.jl**. The model builds a reduced electrical
network that preserves transfer-capacity behaviour between representative
nodes while greatly reducing network size.

---

## 1. DC network matrix

All transfer calculations use the lossless DC power-flow model. The network is
represented by its DC susceptance (Laplacian) matrix $B$, built from series
reactances only:

$$b_{ij} = \frac{1}{X_{ij}}, \qquad
B_{ij} = -\sum_{k \in (i,j)} b_k \;(i \ne j), \qquad
B_{ii} = \sum_{j \ne i} \sum_{k \in (i,j)} b_k$$

Resistance, line charging and bus shunts do not enter active-power PTDFs and
are ignored, so every row of $B$ sums to zero. Parallel branches between the
same buses add their susceptances. Transformers are treated as AC elements and
are merged into the line set before $B$ is assembled. (For compatibility with
the matrix API, $B$ is stored as the complex matrix $-jB$; it is not an AC
$Y_{bus}$.)

DC interconnectors are excluded from $B$. Their capacity contributes
additively to TTC after the AC reduction is complete. When converter data are
provided, a DC line's capacity is limited by the converters at both of its
terminals, $C_{DC} = \min(C_{line}, C_{conv,from}, C_{conv,to})$, and
several lines between the same representative-node pair are jointly capped,
on each side, by the total rating of the distinct converters they use.

---

## 2. PTDFs

Under the DC approximation, active power flow is:

$$P = B\theta$$

For a transaction from bus $a$ to bus $b$, the PTDF on line $l=(i,j)$ is:

$$PTDF_l^{a \to b} = b_{ij}(\theta_i^{a \to b} - \theta_j^{a \to b})$$

For multi-island AC networks, one reference bus is chosen per AC component.
Transactions between different AC islands have $TTC_{AC} = \infty$.

---

## 3. Original-network TTC

For transaction $t$, the AC transfer capacity is:

$$TTC_{AC,t} = \min_l \frac{C_l}{|PTDF_{t,l}|}$$

Lines with $|PTDF| \le \varepsilon$ are ignored, where $\varepsilon$ is
`CONFIG.ptdf_epsilon`. TTCs are computed for every pair of representative
nodes; these are the only transactions the reduction uses.

Parallel branches share one angle difference, so their combined limit is set
by the tightest individual branch rather than the sum of ratings:

$$C_{pair} = \Big(\sum_k b_k\Big) \min_k \frac{C_k}{b_k}$$

This equals the summed rating only when the ratings are proportional to the
branch susceptances.

DC interconnectors are additive:

$$TTC_t = TTC_{AC,t} + C_{DC,t}$$

For cross-island transactions:

$$TTC_t =
\begin{cases}
C_{DC,t}, & \text{if a DC bridge exists} \\
\infty, & \text{otherwise}
\end{cases}
$$

---

## 4. Kron reduction

Representative nodes are retained and all other nodes are eliminated from the
DC matrix:

$$B =
\begin{bmatrix}
B_{RR} & B_{RE} \\
B_{ER} & B_{EE}
\end{bmatrix}
$$

The reduced matrix is:

$$B_{red} = B_{RR} - B_{RE}B_{EE}^{-1}B_{ER}$$

$B_{red}$ is again a DC Laplacian; each non-zero off-diagonal entry is a
synthetic line between two representative nodes. If every bus is retained
(e.g. all zones at high resolution) there is nothing to eliminate and $B$ is
used as is.

In multi-island cases, a small diagonal regularisation is used when needed:

$$B_{EE}^{-1} \approx (B_{EE} + \epsilon I)^{-1}$$

The implementation uses a direct linear solve instead of forming an explicit
inverse.

### 4.1 Virtual-line filter

With `allow_virtual_lines = false`, a synthetic line is kept only if both
endpoints are in the same zone or their zones are directly connected in the
original network (AC or DC). A removed line's susceptance is taken out of both
the off-diagonal and the diagonal entries, so the filtered matrix is again a
DC Laplacian describing exactly the exported network. The reduced-network
PTDFs (and hence the fitted capacities and the equivalent TTC) are computed on
this filtered network, never on the unfiltered Kron network.

---

## 5. Equivalent capacity fitting

The model identifies synthetic AC capacities $C_l^{eq}$ for the reduced
network. DC capacities remain outside the AC equivalent and are added
additively to total TTC.

High-resolution zone mode fixes synthetic lines between two retained high-res
buses to their original physical capacity. Other synthetic capacities are
optimised or constructed according to `CONFIG.optimisation_type`.

### 5.1 Optimisation modes

`CONFIG.optimisation_type` controls how the synthetic AC capacities are
obtained:

| Type | Main purpose |
| :--- | :--- |
| `QP` | Fast continuous capacity fitting. Use it when you want a practical balance between TTC accuracy and computation time. |
| `LP` | Deterministic capacity-envelope construction. Use it when you want a solver-light capacity set based directly on PTDF envelopes. |
| `MIQP` | Binding-line formulation. Use it when identifying the limiting synthetic line and obtaining physically consistent capacities is more important than speed. |

In all modes, DC capacity remains additive:

$$TTC_t^{eq} = TTC_{AC,t}^{eq} + C_{DC,t}$$

For cross-island transactions, the transfer limit is the DC bridge capacity
when a bridge exists, or `Inf` otherwise.

### 5.2 QP

QP minimises squared error against the original AC TTC component:

$$
\min \sum_t (TTC_{AC,t}^{eq} - TTC_{AC,t}^{orig})^2

+ \lambda \sum_l (C_l^{eq})^2

$$

subject to:

$$TTC_{AC,t}^{eq}|PTDF_{t,l}| \le C_l^{eq} \quad \forall t,l$$

and non-negativity of capacities and equivalent AC TTCs. DC capacity is not
used as an AC floor; it is added back only in reporting.

### 5.3 LP

LP mode uses a deterministic capacity envelope rather than an iterative Ipopt
solve. For each synthetic line:

$$C_l^{eq} =
\max_{t \in \mathcal{T}_l}
\left(TTC_{AC,t}^{orig}|PTDF_{t,l}|\right)$$

The resulting TTC follows the same thermal-limit relation,
$\min_l C_l^{eq}/|PTDF_{t,l}|$. This is fast and deterministic. It guarantees
support for the original AC target when no fixed physical capacity is lower
than the envelope, but it can overestimate some transaction TTCs.

### 5.4 MIQP

MIQP (mixed-integer quadratic programming) mode adds binary variables that
choose, for every fitted transaction, the synthetic line that limits its TTC.
The objective is quadratic and the binding choices are integer, hence MIQP.

For transaction $t$, let $T_t > 0$ be the original AC TTC (the fitting target),
$p_{tl} = |PTDF_{t,l}|$, and $K_t$ the synthetic lines with
$p_{tl} > \varepsilon$. The fitted transactions $\mathcal{T}_f$ are those with
a finite positive target that load at least one optimisable (non-fixed) line.

The objective is the sum of squared relative TTC errors, so that transactions
of very different size contribute comparably:

$$\min \sum_{t\in\mathcal{T}_f}\left(\frac{TTC_{AC,t}^{eq}}{T_t}-1\right)^2$$

subject to, for every fitted transaction $t \in \mathcal{T}_f$:

* thermal limits on every relevant line,
  $p_{tl}\,TTC_{AC,t}^{eq} \le C_l \quad \forall l \in K_t$;
* a conservative fit, $0 \le TTC_{AC,t}^{eq} \le T_t$, so a fitted
  transaction is never over-estimated;
* exactly one binding line,

  $$\sum_{l\in K_t} b_{tl} = 1, \qquad
  C_l - p_{tl}\,TTC_{AC,t}^{eq} \le M_l\,(1-b_{tl}), \qquad
  b_{tl}\in\{0,1\}.$$

  With $b_{tl} = 1$ and the thermal limit, $C_l = p_{tl}\,TTC_{AC,t}^{eq}$, so
  the fitted TTC equals $\min_l C_l/p_{tl}$, the TTC the capacities deliver.

Capacities are bounded by a reference capacity, which also serves as big-M:

$$C_l^{ref}=\max_{t\in\mathcal{T}_f}p_{tl}T_t,\qquad
0\le C_l\le\gamma_C C_l^{ref},\qquad M_l=\gamma_C C_l^{ref}$$

$C_l^{ref}$ is the largest rating any fitted transaction needs from line $l$
at its target, so with $\gamma_C \ge 1$ (default `miqp_gamma_C = 1.0`) the
bound does not restrict the fit. Fixed high-resolution lines keep their
physical rating, which is also their big-M.

The objective does not price capacities, so several capacity sets can give
the same fitted TTCs. After the solve, each optimised rating is therefore set
to the smallest value that supports every fitted TTC,
$C_l = \max_{t\in\mathcal{T}_f} p_{tl}\,TTC_{AC,t}^{eq}$, taken over all
retained PTDFs (including those below $\varepsilon$). This does not change any
fitted TTC and makes the exported capacities unique. The exported network is
then checked to reproduce the fitted TTCs and to remain conservative.

By default every relevant line is a binding candidate
(`miqp_binding_candidates_per_txn = 0`); choices that provably cannot improve
on a feasible starting solution are screened out, without loss of optimality.
A positive value keeps only that many most likely lines per transaction,
which is faster but heuristic and can change the best attainable fit. The
solver starts from a complete feasible solution (capacities, TTCs and binding
choices) built from the reference capacities.

Reducing thousands of buses to a few dozen cannot generally reproduce every
pairwise TTC or the complete congestion behaviour of the original network.
Maximum and mean TTC errors quantify that compromise; they are not universal
pass/fail thresholds. Export consistency and calibrated-transfer
conservativeness are correctness requirements. Even a globally solved MIQP
minimises the sum of squared relative errors, not the worst relative error.

---

## 6. Implementation notes

1. `ptdf_epsilon` removes near-zero PTDF entries to avoid unstable divisions.
2. Optimisation is performed in per-unit and exported in MW using `CONFIG.base`.
3. Parallel AC circuits are aggregated consistently: susceptances are summed
   in $B$ and the pair's thermal limit is the tightest individual angle limit.
4. `lambda` regularises QP capacities; MIQP uses deterministic capacity closure.
5. Equivalent reactance is back-computed from the (filtered) reduced matrix as
   $X^{eq} = -1 / B_{red,ij}$, i.e. $1 / \operatorname{Im}(Y_{kron,ij})$ in
   the stored $-jB$ form.
6. DC lines are appended to `Equivalent_Capacities` with `is_dc = true` and
   `X_pu = 0`.
