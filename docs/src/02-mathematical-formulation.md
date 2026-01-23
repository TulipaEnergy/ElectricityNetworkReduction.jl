# Mathematical Formulation

This document presents the mathematical foundations of the **NetworkReduction.jl** model.
The objective of the model is to construct a reduced electrical network that preserves the
power transfer characteristics of the original system while significantly reducing its size.

---

## 1. Network Admittance Matrix ($Y_{bus}$)

The electrical network is represented by its nodal admittance matrix:

$$Y = G + jB$$

where:

- $G$ is the conductance matrix.
- $B$ is the susceptance matrix.
- $j = \sqrt{-1}$.

Each transmission line between buses $i$ and $j$ is modeled by its series admittance $y_{ij} = \frac{1}{R_{ij} + jX_{ij}}$. Including shunt susceptance $B_{ij}$, the $Y_{bus}$ is assembled as:

- **Diagonal elements:**
  $$Y_{ii} = \sum_{j \in \mathcal{N}(i)} \left( y_{ij} + j\frac{B_{ij}}{2} \right) + (G_{i}^{shunt} + jB_{i}^{shunt})$$

- **Off-diagonal elements:**
  $$Y_{ij} = -y_{ij}$$

---

## 2. DC Power Flow and PTDFs

Under the DC approximation (negligible resistance, flat voltage magnitudes, small angles), active power flow is:

$$P = B \theta$$

### 2.1 Power Transfer Distribution Factors (PTDF)

The PTDF for a line $l$ (from bus $i$ to $j$) during a transaction between buses $a$ and $b$ is:

$$PTDF_{l}^{a \to b} = b_{ij} (\theta_i^{a \to b} - \theta_j^{a \to b})$$

In the code, this is solved by calculating the sensitivity of bus angles to injections at buses $a$ and $b$ relative to a slack bus.

---

## 3. Total Transfer Capacity (TTC)

The TTC for a transaction $t$ (from $a$ to $b$) is the maximum power flow possible before any line hits its thermal limit $C_l$:

$$TTC_{t} = \min_{l \in \text{Lines}} \left( \frac{C_l}{|PTDF_{t,l}|} \right)$$

---

## 4. Network Reduction (Kron)

The system is partitioned into **Representative Nodes (R)** and **Eliminated Nodes (E)**:

$$Y = \begin{bmatrix} Y_{RR} & Y_{RE} \\ Y_{ER} & Y_{EE} \end{bmatrix}$$

The reduced admittance matrix $Y_{reduced}$ (Kron Reduction) is:

$$Y_{reduced} = Y_{RR} - Y_{RE} Y_{EE}^{-1} Y_{ER}$$

---

## 5. Optimization of Equivalent Capacities

The package identifies synthetic capacities $C_l^{eq}$ for the reduced network to match the original $TTC^{orig}$. Based on `optimization.jl`, three methods are available:

### 5.1 Quadratic Programming (QP)

**Objective:** Minimize the squared error between original and equivalent TTC, with a regularization term to keep capacities realistic.

$$\min \sum_{t \in \mathcal{T}} (TTC_t^{eq} - TTC_t^{orig})^2 + \lambda \sum_{l \in \mathcal{L}_{red}} (C_l^{eq})^2$$

**Constraints:**

1. **Flow Limit:** For every transaction $t$ and every synthetic line $l$:
   $$TTC_t^{eq} \cdot |PTDF_{t,l}| \le C_l^{eq} \quad \forall t, \forall l$$
2. **Non-negativity:**
   $$C_l^{eq} \ge 0, \quad TTC_t^{eq} \ge 0$$

### 5.2 Linear Programming (LP)

**Objective:** Maximize the total transfer capacity of the reduced network while ensuring it never exceeds the original limits.

$$\max \sum_{t \in \mathcal{T}} TTC_t^{eq}$$

**Constraints:**

1. **Upper Bound:**
   $$TTC_t^{eq} \le TTC_t^{orig} \quad \forall t$$
2. **Physical Limit:**
   $$TTC_t^{eq} \cdot |PTDF_{t,l}| \le C_l^{eq} \quad \forall t, \forall l$$
3. **Capacity Ceiling:** (Optional scaling)
   $$C_l^{eq} \le \text{max\_factor} \cdot \max(TTC^{orig})$$

## 7.2 MIQP (Original Mixed-Integer Quadratic Programming)

This formulation is used when we want to identify which synthetic line is **binding** (limiting) for each transaction.

### Decision Variables

- $C_l^{eq} \ge 0$: synthetic line capacities
- $TTC_t^{eq} \ge 0$: equivalent TTC values
- $z_{t,l} \in \{0,1\}$: binding indicator ($z_{t,l} = 1$ means line $l$ limits transaction $t$)

### Objective

$$\min \sum_{t\in\mathcal{T}} (TTC_t^{eq}-TTC_t^{orig})^2 + \lambda\sum_{l\in\mathcal{L}} (C_l^{eq})^2$$

### Constraints

1. **General physical TTC upper bound:**
   $$TTC_t^{eq} \le \frac{C_l^{eq}}{|PTDF_{t,l}|}\qquad \forall t,l$$

2. **Exactly one binding line per transaction:**
   $$\sum_{l\in\mathcal{L}} z_{t,l} = 1 \qquad \forall t$$

3. **Big-M binding constraint (enforcing equality on chosen line):**
   $$\frac{C_l^{eq}}{|PTDF_{t,l}|} - TTC_t^{eq} \le M(1-z_{t,l}) \qquad \forall t,l$$

---

## 7.3 Linearized MIQP → MILP (HiGHS-Compatible)

To make the MIQP practical for large networks, the implementation uses a **linearized MILP** solved by **HiGHS**.

### Decision Variables (MILP)

- $C_l^{eq} \ge 0$: synthetic line capacity
- $TTC_t^{eq} \ge 0$: equivalent TTC
- $b_{t,l}\in\{0,1\}$: binding selection
- $Z_{t,l}\ge 0$: allocated capacity for transaction $t$ on line $l$
- $V_t^{abs}\ge 0$: absolute TTC error (L1 linearization)

### Objective (L1 TTC matching)

$$\min \sum_{t\in\mathcal{T}} V_t^{abs}$$

**Linearization of absolute value:**
$$V_t^{abs} \ge TTC_t^{eq}-TTC_t^{orig}, \qquad \forall t$$
$$V_t^{abs} \ge TTC_t^{orig}-TTC_t^{eq}, \qquad \forall t$$

### MILP Constraints

#### A) TTC definition using allocated capacity $Z$

$$TTC_t^{eq} = \sum_{l\in\mathcal{L}_t} \frac{Z_{t,l}}{|PTDF_{t,l}|} \qquad \forall t$$

#### B) Capacity allocation limits

$$Z_{t,l} \le C_l^{eq}\qquad \forall t,l$$

#### C) Exactly one binding line per transaction

$$\sum_{l\in\mathcal{L}_t} b_{t,l} = 1\qquad \forall t$$

#### D) Big-M logic

- if $b_{t,l}=1$, then $Z_{t,l}=C_l^{eq}$
- if $b_{t,l}=0$, then $Z_{t,l}=0$

$$Z_{t,l} \le M_Z\, b_{t,l}\qquad \forall t,l$$
$$Z_{t,l} \ge C_l^{eq} - M_Z(1-b_{t,l})\qquad \forall t,l$$

#### E) Numerical stability bounds

$$TTC_t^{eq} \le M_{TTC}\qquad \forall t$$

## Important Implementation Notes

1. **PTDF Epsilon:** The optimization ignores lines where $|PTDF| < \epsilon$ (defined in `config.jl`) to avoid numerical instability (division by zero).
2. **MW Conversion:** While the optimization typically occurs in per-unit (p.u.), the `main-analysis.jl` script converts final $C_l^{eq}$ results to MW using the `Sbase` defined in `CONFIG`.
3. **Regularization ($\lambda$):** The $\lambda$ parameter is crucial. Without it, the solver may assign infinitely high capacities to lines that don't participate in any binding constraints. A small $\lambda$ (e.g., $10^{-6}$) ensures the smallest sufficient capacity is chosen.
