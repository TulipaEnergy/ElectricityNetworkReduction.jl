# Mathematical formulation

This document summarises the mathematical foundations of
**ElectricityNetworkReduction.jl**. The model builds a reduced electrical
network that preserves transfer-capacity behaviour between representative
nodes while greatly reducing network size.

---

## 1. Network admittance matrix

The network is represented by its nodal admittance matrix:

$$Y = G + jB$$

Each AC branch between buses $i$ and $j$ has series admittance
$y_{ij} = 1/(R_{ij} + jX_{ij})$. Line charging and bus shunts are included in
the diagonal terms. Transformers are treated as AC elements and are merged into
the line set before $Y_{bus}$ assembly.

DC interconnectors are excluded from $Y_{bus}$. Their capacity contributes
additively to TTC after the AC reduction is complete.

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

Lines with $|PTDF| < \varepsilon$ are ignored, where $\varepsilon$ is
`CONFIG.ptdf_epsilon`.

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

Representative nodes are retained and all other nodes are eliminated:

$$Y =
\begin{bmatrix}
Y_{RR} & Y_{RE} \\
Y_{ER} & Y_{EE}
\end{bmatrix}
$$

The reduced admittance matrix is:

$$Y_{red} = Y_{RR} - Y_{RE}Y_{EE}^{-1}Y_{ER}$$

In multi-island cases, a small diagonal regularisation is used when needed:

$$Y_{EE}^{-1} \approx (Y_{EE} + \epsilon I)^{-1}$$

The implementation uses a direct linear solve instead of forming an explicit
inverse.

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

### 5.4 MIQP / MILP binding formulation

MIQP mode is implemented as a HiGHS MILP that selects a binding synthetic line
for each transaction from a pruned candidate set.

Decision variables:

* $C_l^{eq} \ge 0$: synthetic capacities
* $TTC_{AC,t}^{eq} \ge 0$: equivalent AC TTC
* $z_{t,l} \in \{0,1\}$: binding-line indicator for candidate lines
* $V_t^{abs} \ge 0$: absolute TTC error

Objective:

$$
\min \sum_t V_t^{abs} + \lambda\sum_l C_l^{eq}
$$

with:

$$V_t^{abs} \ge TTC_{AC,t}^{eq} - TTC_{AC,t}^{orig}$$

$$V_t^{abs} \ge TTC_{AC,t}^{orig} - TTC_{AC,t}^{eq}$$

Physical upper-bound constraints:

$$C_l^{eq} \ge TTC_{AC,t}^{eq}|PTDF_{t,l}| \quad \forall t,l$$

Binding candidate selection:

$$\sum_{l \in \mathcal{K}_t} z_{t,l} = 1$$

where $\mathcal{K}_t$ is the pruned set of likely limiting lines for
transaction $t$.

Big-M binding logic:

$$C_l^{eq} \le TTC_{AC,t}^{eq}|PTDF_{t,l}| + M_l(1-z_{t,l}) \quad \forall l \in \mathcal{K}_t$$

Controls:

* `CONFIG.miqp_binding_candidates_per_txn`
* `CONFIG.miqp_time_limit_sec`
* `CONFIG.miqp_mip_rel_gap`

---

## 6. Implementation notes

1. `ptdf_epsilon` removes near-zero PTDF entries to avoid unstable divisions.
2. Optimisation is performed in per-unit and exported in MW using `CONFIG.base`.
3. Parallel AC circuits are aggregated consistently: admittances are summed in
   $Y_{bus}$ and capacities are summed for TTC limits.
4. `lambda` discourages unnecessarily large equivalent capacities.
5. Equivalent reactance is back-computed from the Kron-reduced matrix as
   $X^{eq} = 1 / \operatorname{Im}(Y_{kron,ij})$.
6. DC lines are appended to `Equivalent_Capacities` with `is_dc = true` and
   `X_pu = 0`.
