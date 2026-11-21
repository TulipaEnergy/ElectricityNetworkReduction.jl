# Contributing Guidelines

Great that you want to contribute to the development of the ElectricityNetworkReduction.jl! Please read these guidelines to get you started.

## GitHub Rules of Engagement

- If you want to discuss something that isn't immediately actionable, post under Discussions. Convert it to an issue once it's actionable.
- All PR's should have an associated issue (unless it's a very minor fix).
- Assign yourself to issues you want to address. Consider if you will be able to work on them in the near future (this week) — if not, leave them available for someone else.
- When finalizing a pull request, set the Status to "Ready for Review." If someone specific needs to review it, assign them as the reviewer (otherwise anyone can review).
- Issues without updates for 60 days (and PRs without updates in 30 days) will be labelled as "stale" and filtered out of view. There is a Stale project board to view and rev

## Contributing Workflow

Fork → Branch → Code → Push → Pull → Squash & Merge

1. Fork the repository (once)
2. Create a new branch (in your fork)
3. Do fantastic coding
4. Push to your fork
5. Create a pull request from your fork to the main repository
6. (After review) Squash and merge

## Validation

Run `julia --project=. test/runtests.jl` from the repository root. Tests write
case-study outputs to temporary directories and do not overwrite the saved
reference CSVs or plots in `test/outputs`. Plotting is exercised by default;
set the environment variable `ENR_TEST_PLOTS=false` to run mathematical and
export checks without generating plots. All test files are collected even when
a case study fails.

After a change that affects results, refresh the saved reference outputs by
running the tests with `ENR_UPDATE_REFERENCE_OUTPUTS=true` (and plotting
enabled). The reference case studies then write to `test/outputs/<case>`
instead of temporary directories; review the changes before committing them.

The European network in `test/inputs/case_EU` is not part of the batch suite
because of its run time, and its outputs are not versioned (`test/outputs/case_EU`
is ignored by git). After a change that affects results, run it manually as
described in the usage guide and check the reported TTC errors.

The batch suite verifies exported-network consistency, valid capacities and
the MIQP's binding and conservativeness constraints. It reports maximum
and mean TTC errors without a fixed accuracy threshold: aggressive reduction
necessarily trades detail for size, and one rating per equivalent branch
cannot generally reproduce every original transfer limit. Assess errors for
the intended study alongside solver status and optimality gap.
