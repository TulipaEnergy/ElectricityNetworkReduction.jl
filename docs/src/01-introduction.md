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

It enables users to replace large meshed networks with accurate reduced equivalents at zonal, regional, national, or continental scale.

---

## Modelling scope

ElectricityNetworkReduction.jl implements a **DC power flow based network equivalencing framework** built on the following modelling principles:

- Linearized DC power flow physics
- Exact Y-bus matrix formulation
- Topology-preserving Kron reduction
- PTDF-based transfer representation
- TTC-based interzonal capacity preservation
- Optimization-based equivalent line fitting

The reduced network preserves:

- Inter-zonal transfer capability
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
- Preserving inter-zonal power transfer limits
- Maintaining physical consistency of flows
- Producing compact equivalent networks for fast simulation

This enables fast, accurate, and scalable power system studies.

---

## Workflow at a glance

1. **Load and clean data** — Read the raw data, remove invalid entries, assign consistent sequential IDs, and convert line parameters to per-unit values.
2. **Build the admittance matrix** — Assemble the full-network $Y_{bus}$ from line resistance, reactance, and shunt susceptance.
3. **Compute PTDFs for the original network** — Calculate Power Transfer Distribution Factors for all canonical inter-zonal transactions.
4. **Detect islands** *(optional, when `enable_plots = true`)* — Find connected components and label nodes for visualisation colouring.
5. **Select representative nodes** — Group buses by zone, then keep the highest-degree nodes to serve as the reduced network boundary (automatically by degree, or manually from Excel).
6. **Apply Kron reduction** — Eliminate non-representative nodes while preserving admittance relationships, producing synthetic lines between representative nodes.
7. **Filter virtual lines** *(when `allow_virtual_lines = false`)* — Remove synthetic lines between zones with no direct physical connection in the original network.
8. **Compute PTDFs for the reduced network** — Repeat the PTDF calculation on the reduced topology.
9. **Optimise equivalent line capacities** — Solve a QP, LP, or MILP program (via JuMP + Ipopt/HiGHS) to find synthetic line thermal limits that reproduce the original inter-zonal TTCs.
10. **Export results** — Write CSV reports (bus maps, TTC comparison, PTDF results, equivalent capacities) for downstream use.

---

## Target audience

This package is intended for Transmission System Operators (TSOs), grid planning analysts, and energy system researchers involved in large-scale interconnection studies or long-term planning.

---
