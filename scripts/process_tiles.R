# Canopy loss for every LGLN tile in Lower Saxony that has two epochs or more
# to compare - the statewide run. Each tile is fetched, differenced and written
# on its own, so the run can be stopped and picked up again at any point, and
# tried on a few tiles before it is let loose on all of them.
#
# Writes
#
#   data/tiles/<tile_id>.tif  one raster per measured tile, seven layers, 1 m,
#                32-bit (for the tree IDs), the tile's own 1 x 1 km:
#     loss_year  the year of the first survey that shows the loss, NA where
#                the canopy never went - the latest year it can have gone.
#     observed   1 where some epoch could be differenced, 0 where none could
#                or a building stands. loss_year is NA both where nothing was
#                lost and where nothing was looked at, and this is what tells
#                the two apart.
#     canopy     1 where the stand stood above `canopy_height` when the record
#                starts, over LGLN's DGM1 - the area that had something to lose.
#                Buildings are 0, and so is what tile_loss() finds is no tree:
#                over max_height, or a lake under an old lidar surface.
#     loss_from  the year of the last survey before the loss - the earliest
#                year it can have gone. The loss lies between the two flights.
#     species    the lost trees (R/trees.R), on their crowns: the tree's
#                species code (0 none, 1-12 as in scripts/get_species.R).
#     crown      the tree's ID on its crown, unique across all tiles.
#     tree_top   the tree's height in dm, on its top pixel only.
#                All three NA off the lost trees; trees_from_tiles() reads them
#                back as one row per tree.
#
# and three tables for all tiles, appended by this session after every tile -
# only it writes them, so the parallel workers never collide:
#
#   data/tile_results.csv  one row per finished tile, measured or skipped: its
#                areas (R/metrics.R), loss per year, lost trees in all and per
#                year and species, and what it
#                was made from - the coverage's epoch_dates and the settings'
#                params_id(). A tile is done once its row is here.
#   data/epochs.csv  every finished tile's epoch table, as lgln_epochs() gives
#                it: which surveys were used, and why the others were not.
#   data/runs.csv    one row per attempt: status, seconds, and the error of a
#                failed tile, which has no result row and is tried again.
#
# What runs: tiles not done yet, and done tiles whose epoch_dates in the
# coverage have changed since (LGLN published a new or repeated flight) or
# that were made with other settings (R/params.R) - tile_state() in
# R/status.R, which write_reports.R reports from too. A tile to be redone loses
# its old rows first; its raster is overwritten. A stopped run redoes only the
# tiles that were still in the workers. Every combination of settings used is
# kept as data/params/<params_id>.txt.
#
# Losses are found by tile_loss() - see R/tile_loss.R for why the epochs are
# picked on the tile and the detection run past its edge. Run one session at a
# time: two appending to the same tables would mix their rows.
#
# Tiles come from data/lgln_coverage.gpkg (get_lgln_coverage.R), `comparable`
# ones only: two epochs or more, and a DGM1 for the starting canopy. Every tile
# is read remotely, nothing is downloaded (DGM1 excepted, if a local copy is
# there, see cld.dgm_dir below), so LGLN's servers and the network
# set the pace: in testing, 4.7 s per tile at 16 workers, slower at 32, and at
# 64 reads began to fail (docs/findings.md, 2026-10-23). Hence at most 16 by
# default.
# A tile that fails is tried once more after a pause, and a worker that dies
# is replaced, so a run of several days does not stop on one of either.
# build_outputs.R turns the results into a mosaic and a table.
#
# Usually run through run.R. Options, set before sourcing:
#   options(cld.bbox = c(xmin, ymin, xmax, ymax))  only tiles in this box (EPSG:25832)
#   options(cld.tile_ids = c("326005741"))         only these tiles
#   options(cld.workers = 4)                       parallel workers, default half the
#                                                  cores, at most 16; 1 runs here, for debugging
#   options(cld.dgm_dir = "")                      where a local copy of DGM1 is
#                                                  (scripts/get_dgm1.R), default data/dgm1;
#                                                  "" or none there: DGM1 is streamed
library(sf)
library(terra)
library(rvtr)
library(parallel)
library(cli)

invisible(lapply(list.files("R", "[.]R$", full.names = TRUE), source))

p         <- detection_params  # see R/params.R
pid       <- params_id(p)
bbox      <- getOption("cld.bbox")
tile_ids  <- getOption("cld.tile_ids")
n_workers <- getOption("cld.workers", min(16, max(1, detectCores() %/% 2)))
dgm_dir   <- getOption("cld.dgm_dir", "data/dgm1")
dgm_dir   <- if (length(dgm_dir) && nzchar(dgm_dir) && file.exists(file.path(dgm_dir, "index.csv")))
  normalizePath(dgm_dir, "/") else ""

coverage_file <- "data/lgln_coverage.gpkg"
tile_dir      <- "data/tiles"
result_file   <- "data/tile_results.csv"
epoch_file    <- "data/epochs.csv"
run_log       <- "data/runs.csv"
dir.create(tile_dir, recursive = TRUE, showWarnings = FALSE)
for (f in c(p$buildings, p$lakes, p$species, coverage_file))
  if (!file.exists(f))
    cli_abort("{.file {f}} is missing. Run {.file run.R}, which fetches it first.")

# How GDAL reads LGLN's files, for this session and the workers it starts: no
# listing of the remote folder at every open, two threads to read and decode
# (about 20 % faster at 6 workers, the same values; docs/findings.md,
# 2026-11-09), and a limit on how long one request may hang.
Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR", GDAL_NUM_THREADS = "2",
           GDAL_HTTP_TIMEOUT = "300", GDAL_HTTP_MAX_RETRY = "3",
           GDAL_HTTP_RETRY_DELAY = "10")

# The settings, kept under their fingerprint, so any tile's row can be traced
# back to the values it was made with.
dir.create("data/params", showWarnings = FALSE)
params_file <- file.path("data/params", paste0(pid, ".txt"))
if (!file.exists(params_file)) writeLines(deparse(p), params_file)

read_table <- function(file, text = "tile_id")
  if (file.exists(file))
    read.csv(file, colClasses = setNames(rep("character", length(text)), text))

replace_file <- function(tmp, file) {
  if (!suppressWarnings(file.rename(tmp, file)))
    cli_abort(c("{.file {file}} cannot be replaced (open in another program?).",
                i = "Close it and run again."))
}

# A session killed while appending leaves half a line, which would read as a
# finished tile and take the next row onto it. Cut back to the last whole line:
# the tile then counts as not done and is redone.
repair_table <- function(file) {
  if (!file.exists(file)) return(invisible())
  b <- readBin(file, "raw", file.size(file))
  ends <- which(b == as.raw(10))
  if (!length(ends) || max(ends) == length(b)) return(invisible())
  cli_alert_warning("{.file {file}} ended in half a line: removed it")
  tmp <- paste0(file, ".part")
  writeBin(b[seq_len(max(ends))], tmp)
  replace_file(tmp, file)
}
for (f in c(result_file, epoch_file, run_log)) repair_table(f)
unlink(list.files(tile_dir, "[.]part$", full.names = TRUE))  # from a killed run

# The selection: comparable tiles inside the box or list.
cov <- st_read(coverage_file, quiet = TRUE,
               query = "SELECT tile_id, comparable, epoch_dates FROM tiles")
if (is.null(cov$epoch_dates))
  cli_abort(c("{.file {coverage_file}} predates the {.field epoch_dates} column.",
              i = "Delete {.file data/lgln_coverage_source.csv} and run {.file run.R} to rebuild it."))
cov <- cov[cov$comparable == 1, ]
if (!is.null(bbox)) {
  x <- as.numeric(substr(cov$tile_id, 3, 5)) * 1000
  y <- as.numeric(substr(cov$tile_id, 6, 9)) * 1000
  cov <- cov[x + 1000 > bbox[1] & x < bbox[3] & y + 1000 > bbox[2] & y < bbox[4], ]
}
if (!is.null(tile_ids)) cov <- cov[cov$tile_id %in% tile_ids, ]

# What of it is done, and done from what it would be made from today.
results <- read_table(result_file, c("tile_id", "epoch_dates", "params"))
if (is.null(results))
  results <- data.frame(tile_id = character(), epoch_dates = character(),
                        params = character())
state    <- tile_state(cov, results, pid)  # R/status.R
n        <- table(factor(state, c("done", "new", "new_data", "new_params")))
runs     <- read_table(run_log)
n_failed <- sum(state == "new" & cov$tile_id %in% runs$tile_id[runs$status == "failed"])
todo     <- cov$tile_id[state != "done"]

cli_alert_info("{nrow(cov)} tile{?s} selected")
cli_bullets(c(
  "*" = if (n[["done"]]) "{n[['done']]} done and unchanged: skipped",
  "*" = if (n[["new"]]) paste0("{n[['new']]} not done yet",
               if (n_failed) " ({n_failed} of them failed before and are retried)"),
  "*" = if (n[["new_data"]]) "{n[['new_data']]} with new LGLN flights since: redone",
  "*" = if (n[["new_params"]])
          "{n[['new_params']]} made with other settings: redone (settings now {.val {pid}})"))
if (length(todo))
  cli_alert_info(if (nzchar(dgm_dir)) "DGM1 read from the local copy in {.file {dgm_dir}}"
                 else "DGM1 streamed from LGLN (no local copy)")

# Rows of the tiles about to run go first, so no tile ends up with two sets.
# A tile with epoch rows but no result was stopped halfway, and loses them too.
drop_rows <- function(file, ids) {
  if (!file.exists(file)) return(invisible())
  x <- read.csv(file, colClasses = "character")  # written back exactly as read
  if (!any(x$tile_id %in% ids)) return(invisible())
  tmp <- paste0(file, ".part")
  write.csv(x[!x$tile_id %in% ids, ], tmp, row.names = FALSE)
  replace_file(tmp, file)
}
drop_rows(result_file, todo)
drop_rows(epoch_file, todo)

# The columns of the result table. Rows are appended without a header, so a
# table written before a column was added gets that column first, empty: its
# old rows then line up with the new ones.
result_cols <- c("tile_id", "status", "reason", "epoch_dates", "params", "processed",
                 "first_year", "last_year", "n_used", "observed_m2", "observed_pct",
                 "forest_m2", "loss_m2", "loss_pct", "loss_forest_m2",
                 "loss_pct_forest", "lost_trees", "loss_by_year", "trees_by_year",
                 "trees_by_species")
if (file.exists(result_file)) {
  x <- read.csv(result_file, colClasses = "character")  # written back exactly as read
  if (!identical(names(x), result_cols)) {
    added <- setdiff(result_cols, names(x))
    x[added] <- NA
    tmp <- paste0(result_file, ".part")
    write.csv(x[result_cols], tmp, row.names = FALSE)
    replace_file(tmp, result_file)
    if (length(added))
      cli_alert_info("{.file {result_file}}: added the column{?s} {.field {added}}, empty for the tiles done before")
  }
  rm(x)
}

# Ground lost per year, as "2018:1234;2022:567" - one text column, since the
# years differ from tile to tile. build_outputs.R spreads it into columns.
years_text <- function(r, years) {
  a <- loss_by_year(r, years)
  a <- a[a > 0]
  paste(names(a), a, sep = ":", collapse = ";")
}

# How often each value occurs, in the same form: "2018:12;2022:340" for the
# lost trees' years, "beech:30;spruce:310" for their species. Values that do
# not occur are left out; a factor keeps its level order.
counts_text <- function(x) {
  n <- table(x)
  n <- n[n > 0]
  paste(names(n), as.vector(n), sep = ":", collapse = ";")
}

process_tile <- function(tile_id) {
  tl <- tile_loss(tile_id, p, dgm_dir)
  on.exit(unlink(tl$grid))
  used <- tl$ep[tl$ep$used, ]
  file <- file.path(tile_dir, paste0(tile_id, ".tif"))
  row  <- data.frame(tile_id = tile_id,
                     status = if (is.null(tl$year)) "skipped" else "measured",
                     reason = tl$reason)
  if (is.null(tl$year)) {
    unlink(file)  # from an earlier run, if the tile could be measured then
    return(list(row = row, ep = cbind(tile_id = tile_id, tl$ep)))
  }

  canopy <- starting_canopy(tl$srf, tl$dtm, p$canopy_height) |>
    crop(tile_ext(tile_id))
  canopy <- ifel(tl$built | tl$no_canopy, 0, canopy)
  trees <- lost_trees(tl, tl$dtm, tile_id, p)
  if (is.null(trees)) trees <- rast(tl$year, nlyrs = 3, vals = NA)
  out <- c(tl$year, tl$seen, canopy, tl$from, trees)
  names(out) <- c("loss_year", "observed", "canopy", "loss_from",
                  "species", "crown", "tree_top")
  # Copied through gdal_translate -stats, so complete band statistics sit
  # inside the GeoTIFF. terra writes only min and max, and a viewer such as
  # QGIS would compute the rest and leave them beside it as .aux.xml. The
  # temporary file goes with the session's temp folder (run_one()). Written
  # under another name and renamed when complete, so a raster under the tile's
  # name is always a whole one.
  tmp <- tempfile(fileext = ".tif")
  writeRaster(out, tmp, datatype = "INT4U")
  part <- paste0(file, ".part")
  sf::gdal_utils("translate", tmp, part,
                 options = c("-of", "GTiff", "-stats", "-co", "COMPRESS=DEFLATE", "-co", "PREDICTOR=2"),
                 config_options = c(GTIFF_SRS_SOURCE = "EPSG"))
  if (!file.rename(part, file)) stop("cannot replace ", file, call. = FALSE)

  # The tile's row, measured here while the raster is in hand, so the tile
  # table never has to read the rasters again. A tree is its top pixel, which
  # carries the tree's loss year and species.
  v   <- values(out[[c("loss_year", "species", "tree_top")]], mat = TRUE)
  top <- !is.na(v[, "tree_top"])
  species <- factor(species_classes$name[match(v[top, "species"], species_classes$code)],
                    levels = species_classes$name)
  row <- cbind(row,
               first_year = min(used$year), last_year = max(used$year),
               n_used = nrow(used),
               round(loss_metrics(out), 1),
               lost_trees = sum(top),
               loss_by_year = years_text(out, used$year),
               trees_by_year = counts_text(v[top, "loss_year"]),
               trees_by_species = counts_text(species))
  list(row = row, ep = cbind(tile_id = tile_id, tl$ep))
}

# One tile, never stopping the run: an error is returned for the run log. A
# read from LGLN can fail under load, so a failed tile is tried once more after
# a pause before it counts as failed. The session's temp folder is emptied
# after every attempt - the grids, VRTs and terra's own scratch files are a few
# MB a tile, which over the state would fill a disk.
run_one <- function(tile_id) {
  t0 <- Sys.time()
  attempt <- function() {
    out <- tryCatch(suppressMessages(process_tile(tile_id)), error = \(e) e)
    unlink(list.files(tempdir(), full.names = TRUE), recursive = TRUE)
    out
  }
  out <- attempt()
  if (inherits(out, "error")) {
    Sys.sleep(15)
    out <- attempt()
  }
  if (inherits(out, "error"))
    out <- list(row = NULL, ep = NULL, error = gsub("\\s+", " ", conditionMessage(out)))
  out$run <- data.frame(
    tile_id = tile_id,
    status = if (is.null(out$row)) "failed" else out$row$status,
    seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1),
    error = if (is.null(out$error)) "" else out$error)
  out
}

# Append rows to a CSV, with the header only when the file is new. The columns
# of a result row depend on its status, so rows are first put in one shape
# (result_cols, above).
append_csv <- function(x, file) {
  if (is.null(x) || !nrow(x)) return(invisible())
  new <- !file.exists(file)
  write.table(x, file, sep = ",", row.names = FALSE, col.names = new, append = !new)
}

# A finished tile into the tables. The result row goes last: it is what marks
# the tile done.
record <- function(out) {
  append_csv(cbind(out$run, finished = format(Sys.time())), run_log)
  append_csv(out$ep, epoch_file)
  if (!is.null(out$row)) {
    res <- out$row
    res[setdiff(result_cols, names(res))] <- NA
    res$epoch_dates <- cov$epoch_dates[match(res$tile_id, cov$tile_id)]
    res$params      <- pid
    res$processed   <- format(Sys.time())
    append_csv(res[result_cols], result_file)
  }
}

# The workers, each with the packages, the functions in R/ and this script's
# settings. Their process IDs are kept, so stop_workers() can end them even
# when one no longer answers.
start_workers <- function() {
  cl <- makeCluster(n_workers)
  worker_pids <<- unlist(clusterCall(cl, Sys.getpid))
  clusterCall(cl, setwd, getwd())
  clusterEvalQ(cl, {
    library(terra)
    library(rvtr)
    invisible(lapply(list.files("R", "[.]R$", full.names = TRUE), source))
    terraOptions(progress = 0)
    NULL
  })
  clusterExport(cl, c("p", "dgm_dir", "tile_dir", "process_tile", "run_one", "years_text",
                      "counts_text"),
                envir = globalenv())
  cl
}
stop_workers <- function() {
  try(stopCluster(cl), silent = TRUE)
  tools::pskill(worker_pids)
  for (node in cl) try(close(node$con), silent = TRUE)
}

# Tiles handed to the workers one by one, each to the next that is free.
send <- get("sendCall", asNamespace("parallel"))
recv <- get("recvOneResult", asNamespace("parallel"))
# `on_send` is told every tile handed out.
dispatch <- function(ids, done, on_send) {
  sent <- 0
  for (w in seq_len(min(n_workers, length(ids)))) {
    sent <- sent + 1
    on_send(ids[sent])
    send(cl[[w]], run_one, list(ids[sent]), tag = sent)
  }
  for (k in seq_along(ids)) {
    r <- recv(cl)
    if (sent < length(ids)) {
      sent <- sent + 1
      on_send(ids[sent])
      send(cl[[r$node]], run_one, list(ids[sent]), tag = sent)
    }
    if (inherits(r$value, "try-error")) stop(r$value, call. = FALSE)
    done(r$value)
  }
}

# Every tile, recorded and counted as soon as it is back - so a stopped run
# loses only the tiles still in the workers. This is what parLapplyLB() does
# inside, minus waiting for the whole list. A worker that dies (lost
# connection) takes its tile with it: the workers are then restarted, and the
# tiles not yet recorded are handed out again. A tile that was in a worker
# during two such deaths is logged as failed, so it cannot stop the run; the
# next run tries it again.
run_all <- function(ids) {
  status <- c(measured = 0, skipped = 0, failed = 0)
  bar <- cli_progress_bar(
    total = length(ids), clear = FALSE,
    format = paste("{cli::pb_current}/{cli::pb_total} tiles",
                   "· {status[['measured']]} measured · {status[['skipped']]} skipped",
                   "· {status[['failed']]} failed · {cli::pb_elapsed} · ETA {cli::pb_eta}"))
  cli_progress_update(id = bar, force = TRUE, set = 0)
  recorded <- character()
  done <- function(out) {
    record(out)
    recorded <<- c(recorded, out$run$tile_id)
    status[[out$run$status]] <<- status[[out$run$status]] + 1
    if (out$run$status == "failed")
      cli_alert_danger("{out$run$tile_id} failed: {out$run$error}")
    cli_progress_update(id = bar)
  }

  if (n_workers == 1) {
    for (id in ids) done(run_one(id))
  } else {
    restarts <- 0
    handed   <- character()
    crashes  <- setNames(numeric(length(ids)), ids)
    repeat {
      lost <- tryCatch({
        dispatch(setdiff(ids, recorded), done, \(id) handed <<- c(handed, id))
        NULL
      }, error = \(e) e)
      if (is.null(lost)) break
      restarts <- restarts + 1
      if (restarts > 20) stop(lost)
      cli_alert_warning(paste("A worker stopped ({conditionMessage(lost)}):",
                              "restarting the workers ({restarts}) and carrying on"))
      stop_workers()
      in_worker <- setdiff(handed, recorded)
      crashes[in_worker] <- crashes[in_worker] + 1
      for (id in names(crashes)[crashes >= 2 & !names(crashes) %in% recorded])
        done(list(run = data.frame(tile_id = id, status = "failed", seconds = NA,
                                   error = "its worker died twice while on it")))
      cl <<- start_workers()
    }
  }
  cli_progress_done(id = bar)
  status
}

if (!length(todo)) {
  cli_alert_success("Nothing to process")
} else {
  if (n_workers > 1) {
    cli_progress_step("Starting {n_workers} workers")
    cl <- start_workers()
    cli_progress_done()
  }
  cli_alert_info("A tile takes about 30 s per worker; progress shows as each one finishes")

  status <- tryCatch(
    run_all(todo),
    interrupt = \(e) {
      cli_alert_warning("Stopped. Finished tiles are kept; the next run picks up the rest.")
      NULL
    },
    finally = if (n_workers > 1) stop_workers())
  if (!is.null(status) && status[["failed"]])
    cli_alert_warning("{status[['failed']]} tile{?s} failed (see {.file {run_log}}); the next run tries again")
}
