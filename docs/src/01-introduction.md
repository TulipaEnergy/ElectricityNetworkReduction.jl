# Introduction

## Overview

**ElectricityNetworkReduction.jl** is a high-performance Julia package for physics-preserving reduction and equivalencing of large-scale electrical transmission networks.
It provides a mathematically rigorous and computationally efficient workflow for reducing full transmission system models into compact equivalent networks while preserving their power transfer characteristics, congestion behaviour, and operational limits.

The package is specifically designed for power system studies where full network models are too large or computationally expensive to embed inside:

- Optimal Power Flow (OPF)
- Unit Commitment (UC)
- Market simulation
- Adequacy and planning studies
- Long-term energy system models

It enables users to replace large meshed networks with accurate reduced equivalents at zonal, regional, national, or continental scale, including networks with **DC interconnectors**, **transformers**, and **AC/DC converter stations**.

---

## Modelling scope

ElectricityNetworkReduction.jl implements a **DC power flow based network equivalencing framework** built on the following modelling principles:

- Linearized DC power flow physics
- Exact Y-bus matrix formulation (AC lines and transformers)
- Topology-preserving Kron reduction
- PTDF-based transfer representation
- TTC-based interzonal capacity preservation, with additive DC line contributions
- Optimisation-based equivalent line fitting (QP, LP, MILP)

The model supports the following **network element types**:

| Element type | Role |
| :--- | :--- |
| AC lines | Form the Y-bus; carry AC power flows |
| AC tie-lines | Cross-zone AC connections; treated identically to AC lines in the Y-bus |
| Transformers | Merged into AC line set before Y-bus assembly |
| DC interconnectors | Excluded from Y-bus; capacity added additively to inter-zonal TTC |
| AC/DC converters | Remap DC cable terminals to their adjacent AC substation buses |

The reduced network preserves:

- Inter-zonal transfer capability (AC + DC)
- Congestion behaviour
- Electrical coupling between zones
- Power flow sensitivities
- Transfer bottlenecks

This allows the reduced network to reproduce the operational behaviour of the original system with orders-of-magnitude lower computational burden.

---

## What problems does it solve?

Large-scale power system models (ENTSO-E scale, national grids, offshore grids, energy island networks) often contain thousands of buses, tens of thousands of branches with complex meshed topologies. Embedding such detailed models within optimisation frameworks typically results in long solution times, memory bottlenecks, poor numerical conditioning, and limited scalability.

ElectricityNetworkReduction.jl solves this by:

- Reducing thousands of buses into tens of representative nodes
- Preserving inter-zonal power transfer limits (AC and DC)
- Maintaining physical consistency of flows
- Producing compact equivalent networks for fast simulation
- Supporting **high-resolution zones** — specific regions can be retained at full bus detail while all others are reduced to one equivalent node, enabling hybrid models (e.g., full-resolution France + one-bus-per-zone for the rest of Europe)

This enables fast, accurate, and scalable power system studies.

---

## Workflow at a glance

1. **Load and clean data** — Read the raw Excel workbook; process AC lines, tie-lines, transformers (merged into AC lines), DC interconnectors, and AC/DC converters. Remove invalid entries, remap DC cable terminals to AC buses, and assign consistent sequential IDs.
2. **Detect islands and plot original network** *(optional, when `enable_plots = true`)* — Build the network graph (AC + DC edges), label connected components, and save the original network plot.
3. **Build the admittance matrix and run diagnostics** — Assemble the full-network $Y_{bus}$ from AC lines and transformers only. Export island diagnostics, bus ID map, and detailed line information.
4. **Select representative nodes** — Group buses by zone, then keep the highest-degree nodes to serve as the reduced network boundary (automatically by degree, or manually from Excel). Zones listed in `high_res_zones` are retained at full bus resolution.
5. **Build virtual line filter and DC capacity map** — Determine which synthetic lines correspond to physically connected zone pairs. Aggregate DC line capacities by representative-node pair for additive TTC contribution, preserving DC bridges between separate AC islands even when they sit inside the same zone.
6. **Compute TTCs for the original network** — Calculate Power Transfer Distribution Factors and Total Transfer Capacities for all canonical inter-zonal transactions. DC capacity is added additively: $TTC = TTC_{AC} + C_{DC}$. The TTC enumeration loop is parallelised across CPU threads when `parallel_processing = true`.
7. **Apply Kron reduction** — Eliminate non-representative nodes while preserving admittance relationships, producing synthetic lines between representative nodes.
8. **Compute PTDFs for the reduced network** — Repeat the PTDF calculation on the reduced topology. Intra-high-res zone pairs are skipped (their limits come from the original network).
9. **Optimise equivalent line capacities** — Solve a QP, LP, or MILP program (via JuMP + Ipopt/HiGHS) to fit AC synthetic line thermal limits. DC interconnector capacity is handled additively in the reported TTC comparison and exported equivalent capacities.
10. **Visualise the reduced network** *(optional, when `enable_plots = true`)* — Save the reduced network and side-by-side comparison plots using GIS lon/lat coordinates. DC lines appear as curved blue edges; high-resolution zones are shaded.
11. **Export results** — Write CSV reports (bus maps, island diagnostics, TTC comparison, PTDF results, equivalent capacities with reactance and DC flags) for downstream use.

---

## Target audience

This package is intended for Transmission System Operators (TSOs), grid planning analysts, and energy system researchers involved in large-scale interconnection studies or long-term planning.

---
