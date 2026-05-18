# add_second_target.R
#
# Adds `wk inc flu death` as a SECOND target to the existing quantile/sample
# model_tasks block, mirroring the multi-target-per-block pattern from CDC's
# COVID-19 Forecast Hub that surfaced hubverse-org/hub-dashboard-predtimechart#88.
#
# This script runs AFTER create_model_output_data.R and create_target_data.R.
# It is idempotent: re-running on an already-patched hub is a no-op.
#
# Resilience to upstream merges from example-complex-forecast-hub:
#   * tasks.json edits use *content lookup* (find the block whose output_type
#     contains "quantile"; find the `target` task_id by name) so upstream
#     block reordering or schema-key tweaks don't break it.
#   * Data edits append new rows; do not touch or reorder existing rows.
#
# Recovery flow after upstream merge:
#   git merge upstream/main
#   git checkout --theirs hub-config/tasks.json model-output/ target-data/
#   Rscript internal-data-raw/create_target_data.R
#   Rscript internal-data-raw/create_model_output_data.R
#   Rscript internal-data-raw/add_second_target.R

library(fs)
library(readr)
library(dplyr)
library(tidyr)
library(jsonlite)
library(hubAdmin)
library(distfromq)
library(here)
setwd(here())

set.seed(20260518)

NEW_TARGET        <- "wk inc flu death"
BASE_TARGET       <- "wk inc flu hosp"
DEATH_SCALE_MEAN  <- 0.05
DEATH_SCALE_SD    <- 0.005
DEATH_SCALE_FLOOR <- 1e-4
# Offset for death sample output_type_ids. With compound_taskid_set =
# [reference_date, location, target], death samples must occupy a disjoint
# sample-id range from hosp samples — otherwise the validator infers samples
# are jointly indexed across targets (coarser-than-configured compound).
SAMPLE_ID_OFFSET  <- 1000000L

# ---- helpers (copied from create_model_output_data.R to keep this script
#      self-contained and decoupled from upstream-derived generation logic) ----

schaake_shuffle <- function(sim, obs) {
  stopifnot(all(dim(sim) == dim(obs)))
  result <- matrix(NA, nrow = nrow(sim), ncol = ncol(sim))
  for (j in seq_len(ncol(sim))) {
    result[order(obs[, j]), j] <- sort(sim[, j])
  }
  result
}

schaake_shuffle_ar <- function(value, horizon, sample_index, rho) {
  H <- max(horizon)
  n <- max(sample_index)
  x <- matrix(NA, nrow = n, ncol = H)
  x[cbind(sample_index, horizon)] <- value
  innovations <- matrix(rnorm(n * H, sd = 1), nrow = n, ncol = H)
  y_0 <- rnorm(n, mean = 0, sd = sqrt(1 / (1 - rho^2)))
  y <- matrix(NA, nrow = n, ncol = H)
  y[, 1] <- rho * y_0 + innovations[, 1]
  for (i in seq(from = 2, to = H)) {
    y[, i] <- rho * y[, i - 1] + innovations[, i]
  }
  x_ordered <- schaake_shuffle(sim = x, obs = y)
  x_ordered[cbind(sample_index, horizon)]
}

get_median_forecasts_from_q <- function(df) {
  df |>
    dplyr::filter(abs(as.numeric(output_type_id) - 0.5) < 0.0001) |>
    dplyr::mutate(output_type = "median", output_type_id = "NA")
}

get_mean_forecasts_from_q <- function(df) {
  df |>
    dplyr::filter(output_type == "quantile") |>
    dplyr::group_by(location, reference_date, horizon, target_end_date, target) |>
    dplyr::summarize(
      value = distfromq::make_r_fn(
        ps = as.numeric(output_type_id), qs = as.numeric(value)
      )(1e5) |> mean(),
      .groups = "drop"
    ) |>
    dplyr::mutate(output_type = "mean", output_type_id = "NA")
}

get_sample_forecasts_from_q <- function(df, n = 100, rho = 0.9, locations = NULL) {
  df_names <- colnames(df)
  df <- df |>
    dplyr::filter(output_type == "quantile") |>
    dplyr::group_by(location, reference_date, horizon, target_end_date, target) |>
    dplyr::summarize(
      value = list(
        distfromq::make_r_fn(
          ps = as.numeric(output_type_id), qs = as.numeric(value)
        )(n) |> round()
      ),
      sample_index = list(seq_len(n)),
      .groups = "drop"
    ) |>
    tidyr::unnest(cols = c(value, sample_index)) |>
    dplyr::group_by(location, reference_date) |>
    dplyr::mutate(
      output_type = "sample",
      value = schaake_shuffle_ar(value, horizon + 1, sample_index, rho)
    ) |>
    dplyr::ungroup()

  if (is.null(locations)) {
    locations <- df |> dplyr::distinct(location)
  }

  locations |>
    dplyr::arrange(location) |>
    tibble::rownames_to_column(var = "fips_index") |>
    dplyr::full_join(df, by = "location") |>
    dplyr::mutate(
      output_type_id = as.character(
        sample_index + n * (as.integer(fips_index) - 1)
      ),
      value = pmax(value, 0)
    ) |>
    dplyr::select(dplyr::all_of(df_names)) |>
    tidyr::drop_na() |>
    dplyr::ungroup()
}

# ---- tasks.json patch (via hubAdmin) ----
#
# Strategy: read raw JSON, surgically mutate the nested list to add the new
# target / target_metadata / compound entry, then write back via
# hubAdmin::write_config — which handles autoboxing, null preservation, and
# schema-compliant formatting (a jsonlite-only round-trip silently rewrites
# JSON `null` as `{}`, breaking the nullable `required` schema).

patch_tasks_json <- function(path = "hub-config/tasks.json") {
  config <- jsonlite::read_json(path, simplifyVector = FALSE)

  rounds <- config$rounds
  for (r_idx in seq_along(rounds)) {
    blocks <- rounds[[r_idx]]$model_tasks
    for (b_idx in seq_along(blocks)) {
      block <- blocks[[b_idx]]
      if (!"quantile" %in% names(block$output_type)) next

      target_ids <- vapply(
        block$target_metadata, function(tm) tm$target_id, character(1)
      )
      if (NEW_TARGET %in% target_ids) {
        message("tasks.json already contains '", NEW_TARGET, "' - skipping")
        return(invisible(FALSE))
      }

      # 1. Extend `target` task_id optional list.
      target_task <- block$task_ids$target
      if (is.null(target_task)) {
        stop("Quantile block missing `target` task_id at rounds[", r_idx,
             "]$model_tasks[[", b_idx, "]]")
      }
      config$rounds[[r_idx]]$model_tasks[[b_idx]]$task_ids$target$optional <-
        c(target_task$optional, list(NEW_TARGET))

      # 2. Add `target` to sample compound_taskid_set so the new target has an
      #    independent sample population (existing target1 samples retain their
      #    original joint-over-horizon meaning within ref_date x location).
      if ("sample" %in% names(block$output_type)) {
        cset <- block$output_type$sample$output_type_id_params$compound_taskid_set
        if (!"target" %in% unlist(cset)) {
          config$rounds[[r_idx]]$model_tasks[[b_idx]]$
            output_type$sample$output_type_id_params$compound_taskid_set <-
            c(cset, list("target"))
        }
      }

      # 3. Build + append new target_metadata entry via hubAdmin (handles
      #    schema_id attributes + field shape correctly).
      new_metadata <- hubAdmin::create_target_metadata_item(
        target_id     = NEW_TARGET,
        target_name   = "incident influenza deaths",
        target_units  = "count",
        target_keys   = list(target = NEW_TARGET),
        target_type   = "continuous",
        description   = paste(
          "This target represents the count of new influenza-attributed",
          "deaths in the week ending on the date [horizon] weeks after the",
          "reference_date, on the target_end_date."
        ),
        is_step_ahead = TRUE,
        time_unit     = "week"
      )
      config$rounds[[r_idx]]$model_tasks[[b_idx]]$target_metadata <-
        c(block$target_metadata, list(new_metadata))

      hubAdmin::write_config(
        hubAdmin::as_config(config),
        hub_path = ".", overwrite = TRUE, silent = TRUE
      )
      message("Patched tasks.json: added '", NEW_TARGET,
              "' to quantile block at rounds[", r_idx, "]$model_tasks[[",
              b_idx, "]]")
      return(invisible(TRUE))
    }
  }
  stop("Could not locate any model_tasks block with quantile output_type in ", path)
}

# ---- derive new-target rows for a model-output file ----

derive_new_target_rows <- function(df, locations) {
  hosp_q <- df |>
    dplyr::filter(target == BASE_TARGET, output_type == "quantile")
  if (nrow(hosp_q) == 0) {
    warning("No '", BASE_TARGET, "' quantile rows; returning empty")
    return(df[0, ])
  }

  scale_factors <- hosp_q |>
    dplyr::distinct(location, reference_date, horizon) |>
    dplyr::mutate(
      scale = pmax(
        DEATH_SCALE_MEAN + rnorm(dplyr::n(), 0, DEATH_SCALE_SD),
        DEATH_SCALE_FLOOR
      )
    )

  death_q <- hosp_q |>
    dplyr::left_join(scale_factors,
                     by = c("location", "reference_date", "horizon")) |>
    dplyr::mutate(
      value          = pmax(round(as.numeric(value) * scale), 0),
      target         = NEW_TARGET,
      output_type_id = as.character(output_type_id)
    ) |>
    dplyr::select(-scale)

  death_med <- get_median_forecasts_from_q(death_q)
  death_mean <- get_mean_forecasts_from_q(death_q)
  death_samp <- get_sample_forecasts_from_q(death_q, locations = locations) |>
    dplyr::mutate(
      output_type_id = as.character(
        as.integer(output_type_id) + SAMPLE_ID_OFFSET
      )
    )

  dplyr::bind_rows(death_q, death_med, death_mean, death_samp) |>
    dplyr::mutate(value = pmax(as.numeric(value), 0)) |>
    dplyr::select(dplyr::all_of(names(df)))
}

process_model_output_files <- function() {
  locations <- readr::read_csv(
    "auxiliary-data/locations.csv", show_col_types = FALSE
  ) |>
    dplyr::select(location)

  files <- Sys.glob("model-output/*/*.csv")
  for (f in files) {
    df <- readr::read_csv(f, show_col_types = FALSE)

    if (NEW_TARGET %in% df$target) {
      message("Skipping ", f, " - already contains '", NEW_TARGET, "'")
      next
    }

    new_rows <- derive_new_target_rows(df, locations)
    if (nrow(new_rows) == 0) next

    out_df <- dplyr::bind_rows(df, new_rows)

    neg <- sum(as.numeric(out_df$value) < 0, na.rm = TRUE)
    if (neg > 0) {
      stop("Refusing to write ", f, ": ", neg, " negative `value` rows.")
    }

    readr::write_csv(out_df, f)
    message("Wrote ", nrow(new_rows), " '", NEW_TARGET, "' rows to ", f)
  }
}

# ---- target-data patch ----

patch_target_data <- function() {
  ts_path <- "target-data/time-series.csv"
  oo_path <- "target-data/oracle-output.csv"

  # time-series.csv: derive death observations from hosp observations
  ts <- readr::read_csv(ts_path, show_col_types = FALSE)
  if (NEW_TARGET %in% ts$target) {
    message("time-series.csv already contains '", NEW_TARGET, "' - skipping")
  } else {
    hosp_ts <- ts |> dplyr::filter(target == BASE_TARGET)
    if (nrow(hosp_ts) == 0) {
      warning("No '", BASE_TARGET, "' rows in time-series.csv; skipping")
    } else {
      sf_ts <- hosp_ts |>
        dplyr::distinct(location, target_end_date) |>
        dplyr::mutate(
          scale = pmax(
            DEATH_SCALE_MEAN + rnorm(dplyr::n(), 0, DEATH_SCALE_SD),
            DEATH_SCALE_FLOOR
          )
        )
      death_ts <- hosp_ts |>
        dplyr::left_join(sf_ts, by = c("location", "target_end_date")) |>
        dplyr::mutate(
          observation = pmax(round(observation * scale), 0),
          target = NEW_TARGET
        ) |>
        dplyr::select(-scale)

      out_ts <- dplyr::bind_rows(ts, death_ts)
      if (any(out_ts$observation < 0, na.rm = TRUE)) {
        stop("Refusing to write time-series.csv: negative observation values.")
      }
      readr::write_csv(out_ts, ts_path)
      message("Appended ", nrow(death_ts), " '", NEW_TARGET, "' rows to ", ts_path)
    }
  }

  # oracle-output.csv: clone the structure of BASE_TARGET rows, swap target,
  #  and join in the new observations from the updated time-series.
  oo <- readr::read_csv(oo_path, show_col_types = FALSE)
  if (NEW_TARGET %in% oo$target) {
    message("oracle-output.csv already contains '", NEW_TARGET, "' - skipping")
    return(invisible(FALSE))
  }

  ts_updated <- readr::read_csv(ts_path, show_col_types = FALSE)
  death_obs <- ts_updated |>
    dplyr::filter(target == NEW_TARGET) |>
    dplyr::select(location, target_end_date, oracle_value = observation)

  template <- oo |>
    dplyr::filter(target == BASE_TARGET) |>
    dplyr::select(-oracle_value, -target) |>
    dplyr::mutate(target = NEW_TARGET, .after = "target_end_date") |>
    dplyr::left_join(death_obs, by = c("location", "target_end_date"))

  out_oo <- dplyr::bind_rows(oo, template)
  if (any(out_oo$oracle_value < 0, na.rm = TRUE)) {
    stop("Refusing to write oracle-output.csv: negative oracle_value rows.")
  }
  readr::write_csv(out_oo, oo_path)
  message("Appended ", nrow(template), " '", NEW_TARGET, "' rows to ", oo_path)
  invisible(TRUE)
}

# ---- run ----

patch_tasks_json()
process_model_output_files()
patch_target_data()
message("Done.")
