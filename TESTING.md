# Dashboard Test Hub

This repository is a fork of [example-complex-forecast-hub](https://github.com/hubverse-org/example-complex-forecast-hub), repurposed as a dedicated test fixture for the hubverse dashboard pipeline.

## Purpose

The dashboard pipeline spans multiple repos (predtimechart, hubPredEvalsData, predevals, site-builder, control-room) but had no controlled environment for:

- Testing tool changes against a known-good hub and dashboard config
- Testing new config schema versions against realistic data
- Staging changes end-to-end before releasing
- Running CI smoke tests for PRs to component repos

This test hub, paired with its companion [dashboard-test-hub-dashboard](https://github.com/hubverse-org/dashboard-test-hub-dashboard), fills that gap.

## What's in this hub

Forked from `example-complex-forecast-hub`, this hub contains:

- **3 models**: Flusight-baseline, MOBS-GLEAM_FLUH, PSI-DICE
- **4 reference dates**: 2022-10-22, 2022-11-19, 2022-12-17, 2023-01-14
- **52 locations**: US national + 50 states + DC + Puerto Rico
- **3 targets** with multiple output types: PMF, CDF, quantile, mean, median, sample

The data volume is intentionally small (~24 MB) to keep pipeline runs fast.

## How to use

### Stable baseline testing

The `main` branch provides a known-good baseline. Run the dashboard pipeline against it to verify tool changes don't break anything.

### Branch-based development

For changes that affect hub structure (e.g., new output types, modified round structure):

1. Create a branch on this repo with the modified hub config and data
2. Create a matching branch on the dashboard repo with updated config
3. Run the pipeline against both branches to verify end-to-end

### Regenerating data

The `internal-data-raw/` directory contains R scripts to regenerate model output and target data from original sources. See `internal-data-raw/README.md` for instructions.

## Syncing with upstream

This repo maintains a fork relationship with `example-complex-forecast-hub`. To pull upstream changes (e.g., hub schema updates):

```bash
git fetch upstream
git merge upstream/main
```

## Related

- [dashboard-test-hub-dashboard](https://github.com/hubverse-org/dashboard-test-hub-dashboard): Companion dashboard repo
- [hub-dashboard-control-room](https://github.com/hubverse-org/hub-dashboard-control-room): Workflow orchestration and reusable CI workflows
- [hubverse-claude-skills](https://github.com/hubverse-org/hubverse-claude-skills): Claude Code skills for dashboard operations, which depend on this test hub
