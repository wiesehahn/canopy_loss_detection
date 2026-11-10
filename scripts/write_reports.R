# Two short pages from the tables the other steps keep in data/, no raster
# read, so this takes seconds:
#
#   docs/status.md   how far processing is: tiles done, to redo and to do, the
#                    survey years tiles can show a loss in, and how the runs go.
#   docs/results.md  what has been detected so far, over the tiles done with
#                    the current settings only, so every figure comes from one
#                    method: areas, loss and lost trees per year, lost trees
#                    per species.
#
# run.R writes both at the end of every run. Source this by hand to look at a
# run that is still going: it only reads the tables. A page is rewritten only
# when its content changes, so both can be kept in git.
library(sf)
library(cli)

source("R/params.R")
source("R/status.R")  # tile_state()
source("R/trees.R")   # species_classes

coverage_file <- "data/lgln_coverage.gpkg"
result_file   <- "data/tile_results.csv"
epoch_file    <- "data/epochs.csv"
run_log       <- "data/runs.csv"
params_dir    <- "data/params"
status_file   <- "docs/status.md"
results_file  <- "docs/results.md"

# A table as process_tiles.R writes it, `text` columns read as text (one empty
# in every row would otherwise read as NA). Missing, it is empty, with `cols`.
read_table <- function(file, text, cols) {
  x <- if (file.exists(file)) {
    have <- intersect(text, names(read.csv(file, nrows = 0)))
    read.csv(file, colClasses = setNames(rep("character", length(have)), have))
  } else {
    data.frame(matrix(character(), 0, length(cols), dimnames = list(NULL, cols)))
  }
  for (col in setdiff(cols, names(x))) x[[col]] <- rep(NA_character_, nrow(x))
  x
}

# Years as the coverage lists them, "2013,2018", one sorted vector per tile.
parse_years <- function(x)
  lapply(strsplit(ifelse(is.na(x), "", x), ","),
         \(v) sort(unique(as.integer(trimws(v[nzchar(trimws(v))])))))

# Counts as process_tiles.R writes them, "2018:12;2022:340", summed over all
# rows into one named vector.
parse_counts <- function(x) {
  x <- x[!is.na(x) & x != ""]
  if (!length(x)) return(setNames(numeric(), character()))
  kv <- strsplit(unlist(strsplit(x, ";")), ":")
  tapply(as.numeric(vapply(kv, `[`, "", 2)), vapply(kv, `[`, "", 1), sum)
}

fmt <- function(x, digits = 0) formatC(x, format = "f", digits = digits, big.mark = ",")
pct <- function(a, b) if (b > 0) paste0(fmt(100 * a / b, 1), " %") else "–"
ha  <- function(m2) paste(fmt(m2 / 1e4), "ha")

# A Markdown table, the first column left-aligned, the others right.
md_table <- function(df) {
  df[] <- lapply(df, \(x) gsub("|", "/", as.character(x), fixed = TRUE))
  rows <- do.call(paste, c(unname(as.list(df)), sep = " | "))
  c(paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(c(":--", rep("--:", ncol(df) - 1)), collapse = "|"), "|"),
    paste0("| ", rows, " |"))
}

# Write `lines` to `file` unless it already holds exactly them.
write_page <- function(lines, file, note) {
  lines <- enc2utf8(lines)
  old <- if (file.exists(file)) readLines(file, encoding = "UTF-8", warn = FALSE)
  if (identical(old, lines)) {
    cli_alert_success("{.file {file}} is up to date")
  } else {
    con <- file(file, open = "w", encoding = "UTF-8")
    writeLines(lines, con)
    close(con)
    cli_alert_success(paste0("{.file {file}} written: ", note))
  }
}

if (!file.exists(coverage_file)) {
  cli_alert_warning("No coverage yet ({.file {coverage_file}} is missing): no reports written")
} else {
  pid <- params_id(detection_params)

  cov <- st_read(coverage_file, quiet = TRUE, query = paste(
    "SELECT tile_id, epoch_years, epoch_dates, dgm1, comparable FROM tiles"))
  cov$dgm1       <- as.logical(cov$dgm1)
  cov$comparable <- as.logical(cov$comparable)
  results <- read_table(result_file,
    text = c("tile_id", "status", "epoch_dates", "params", "processed",
             "loss_by_year", "trees_by_year", "trees_by_species"),
    cols = c("tile_id", "status", "epoch_dates", "params", "processed",
             "observed_m2", "forest_m2", "loss_m2", "loss_forest_m2", "lost_trees",
             "loss_by_year", "trees_by_year", "trees_by_species"))
  runs   <- read_table(run_log, text = c("tile_id", "status", "error", "finished"),
                       cols = c("tile_id", "status", "seconds", "error", "finished"))
  epochs <- read_table(epoch_file, text = "tile_id", cols = c("tile_id", "year", "used"))

  # What every processable tile needs (R/status.R), and the tiles done now.
  comp   <- cov[cov$comparable, ]
  state  <- tile_state(comp, results, pid)
  prev   <- results[match(comp$tile_id, results$tile_id), ]
  done   <- comp$tile_id[state == "done"]
  last_run <- runs[!duplicated(runs$tile_id, fromLast = TRUE), ]
  failed <- state == "new" & comp$tile_id %in% last_run$tile_id[last_run$status == "failed"]
  n_comp <- nrow(comp)
  n_done <- length(done)
  latest <- \(x) { x <- x[!is.na(x) & x != ""]; if (length(x)) max(x) else NA }
  updated <- latest(c(results$processed, runs$finished))
  updated <- if (is.na(updated)) "no tile processed yet" else paste("updated", substr(updated, 1, 16))

  # --- status -------------------------------------------------------------------
  method_of <- function(id) {
    f <- file.path(params_dir, paste0(id, ".txt"))
    m <- if (file.exists(f)) tryCatch(eval(parse(f))$method, error = \(e) NULL)
    if (is.null(m)) "?" else as.character(m)
  }
  older <- sort(unique(vapply(unique(prev$params[state == "new_params"]), method_of, "")))
  counts <- c(
    "done" = n_done,
    "to redo: older method" = sum(state == "new_params"),
    "to redo: new LGLN flights" = sum(state == "new_data"),
    "not processed yet" = sum(state == "new" & !failed),
    "failed (tried again next run)" = sum(failed))
  if (length(older)) names(counts)[2] <- paste0("to redo: older method (", paste(older, collapse = ", "), ")")
  counts <- counts[counts > 0 | names(counts) %in% c("done", "not processed yet")]
  tiles <- data.frame(tiles = names(counts), count = fmt(counts),
                      share = vapply(counts, pct, "", n_comp))

  # Per survey year: tiles where that year has an earlier survey to compare
  # with, and of them how many are done (the year used, and not the tile's
  # first survey).
  ep_years <- parse_years(comp$epoch_years)
  y     <- unlist(ep_years)
  tile  <- rep(seq_along(ep_years), lengths(ep_years))
  shows <- duplicated(tile)  # every survey but a tile's first
  used  <- epochs[as.logical(epochs$used) %in% TRUE & epochs$tile_id %in% done, ]
  used  <- used[!duplicated(used[c("tile_id", "year")]), ]
  used  <- used[order(used$tile_id, used$year), ]
  used  <- used[duplicated(used$tile_id), ]
  years <- sort(unique(y[shows]))
  per_year <- data.frame(
    year = years,
    `tiles that can show loss` = fmt(as.vector(table(factor(y[shows], levels = years)))),
    done = fmt(as.vector(table(factor(as.integer(used$year), levels = years)))),
    check.names = FALSE)

  secs <- as.numeric(last_run$seconds[last_run$tile_id %in% done])
  secs <- secs[!is.na(secs)]
  errors <- last_run$error[last_run$tile_id %in% comp$tile_id[failed]]
  errors <- head(sort(table(substr(errors, 1, 160)), decreasing = TRUE), 5)
  flights <- unlist(strsplit(cov$epoch_dates[!is.na(cov$epoch_dates)], ","))

  status <- c(
    "# Processing status",
    "",
    paste0(toupper(substr(updated, 1, 1)), substring(updated, 2), " · method ", detection_params$method,
           " · LGLN data up to ", latest(flights)),
    "",
    paste0("**", fmt(n_done), " of ", fmt(n_comp), " tiles done (", pct(n_done, n_comp), ")**"),
    "",
    md_table(tiles),
    "",
    paste0(fmt(n_comp), " of LGLN's ", fmt(nrow(cov)), " tiles (1 km² each) can be processed. ",
           "The others have fewer than two usable surveys (",
           fmt(sum(!cov$comparable & cov$dgm1)), ") or no terrain model (",
           fmt(sum(!cov$dgm1)), ")."),
    "",
    "## Survey years",
    "",
    md_table(per_year),
    "",
    "## Runs",
    "",
    paste0(if (length(secs)) paste0(fmt(median(secs)), " s per tile and worker (median) · ") else "",
           fmt(sum(failed)), " failed"),
    if (length(errors)) c("", md_table(data.frame(error = names(errors),
                                                  tiles = fmt(as.vector(errors))))),
    "")
  write_page(status, status_file, paste(fmt(n_done), "of", fmt(n_comp), "tiles done"))

  # --- results ------------------------------------------------------------------
  cur <- results[results$tile_id %in% done & results$status == "measured", ]
  num <- \(x) sum(as.numeric(x), na.rm = TRUE)
  results_page <- c(
    "# Canopy loss: results",
    "",
    paste0(fmt(n_done), " tiles processed (", pct(n_done, n_comp), " of the state) · ", updated),
    "")
  if (!nrow(cur)) {
    results_page <- c(results_page, "No tile processed with the current method yet.", "")
  } else {
    forest <- num(cur$forest_m2)
    totals <- data.frame(
      ` ` = c("area observed", "canopy at the start", "lost area", "canopy lost",
              "lost trees"),
      value = c(ha(num(cur$observed_m2)), ha(forest), ha(num(cur$loss_m2)),
                pct(num(cur$loss_forest_m2), forest), fmt(num(cur$lost_trees))),
      check.names = FALSE)

    loss_year  <- parse_counts(cur$loss_by_year)
    trees_year <- parse_counts(cur$trees_by_year)
    ly <- sort(union(names(loss_year), names(trees_year)))
    get0 <- \(v, k) ifelse(is.na(v[k]), 0, v[k])
    by_year <- data.frame(year = ly, `lost area (ha)` = fmt(get0(loss_year, ly) / 1e4),
                          `lost trees` = fmt(get0(trees_year, ly)), check.names = FALSE)

    sp <- sort(parse_counts(cur$trees_by_species), decreasing = TRUE)
    if (length(sp) > 7) sp <- c(sp[1:6], other = sum(sp[-(1:6)]))
    by_species <- data.frame(species = names(sp), trees = fmt(sp),
                             share = vapply(sp, pct, "", sum(sp)))

    results_page <- c(results_page,
      if (n_done < n_comp)
        c("> Partial result: only the tiles processed so far, not a statewide figure.", ""),
      md_table(totals),
      "",
      "## By year",
      "",
      "Year of the first survey that shows the loss.",
      "",
      md_table(by_year),
      if (length(sp)) c("", "## Lost trees by species", "", md_table(by_species)),
      "")
  }
  write_page(results_page, results_file, paste(fmt(nrow(cur)), "measured tiles"))
}
