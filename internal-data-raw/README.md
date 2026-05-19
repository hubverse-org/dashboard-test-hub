# Source data for examples

This folder is not part of the official hubverse structure, and should not be included in repositories used to house new modeling hubs. It contains the original data files and code used to create the target data and model output files for this example hub.

## Recreating the target data and model output files

The hub data is built in three steps, in this order:

```bash
Rscript internal-data-raw/create_target_data.R
Rscript internal-data-raw/create_model_output_data.R
Rscript internal-data-raw/add_second_target.R
```

1. `create_target_data.R` — derives `target-data/{time-series,oracle-output}.csv` for the single-target baseline (`wk inc flu hosp`, `wk flu hosp rate`, `wk flu hosp rate category`) from upstream raw data in `target-data-orig/`.
2. `create_model_output_data.R` — derives `model-output/<model>/*.csv` for the same baseline from raw quantile submissions in `model-output-orig/`.
3. `add_second_target.R` — patches `hub-config/tasks.json` (via `hubAdmin`) to add `wk inc flu death` as a second target in the existing quantile/sample `model_tasks` block (multi-target-per-block fixture for hubverse-org/hub-dashboard-predtimechart#88), and appends matched derived rows for the new target to model-output and target-data files. Idempotent.

### Syncing with upstream after a merge from `example-complex-forecast-hub`

The fork carries patches (notably the second target) that conflict with upstream on `hub-config/tasks.json`, `model-output/`, and `target-data/`. The intended resolution is to take upstream verbatim, then re-derive:

```bash
git merge upstream/main
git checkout --theirs hub-config/tasks.json model-output/ target-data/
Rscript internal-data-raw/create_target_data.R
Rscript internal-data-raw/create_model_output_data.R
Rscript internal-data-raw/add_second_target.R
```

`add_second_target.R` is written defensively against upstream changes — it locates the quantile `model_tasks` block by content (`output_type` contains `quantile`), looks up the `target` task_id by name, and appends rather than overwrites. Upstream is free to reorder blocks, add output types, or extend value lists without breaking the patch.
