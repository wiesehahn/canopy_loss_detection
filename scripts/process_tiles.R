# Canopy loss for every LGLN tile in Lower Saxony that has two epochs or more
# to compare - the statewide run. Each tile is fetched, differenced and written
# on its own, so the run can be stopped and picked up again at any point, and
# tried on a few tiles before it is let loose on all of them.
#
# Per tile, two files:
#
#   data/tiles/<tile_id>.tif    three layers, 1 m, the tile's own 1 x 1 km:
#     loss_year  the year the canopy went, NA where it never did.
#     observed   1 where some epoch could be differenced, 0 where none could.
#                loss_year is NA both where nothing was lost and where nothing
#                was ever looked at, and this is what tells the two apart.
#     canopy     1 where the stand stood above `canopy_height` when the record
#                starts, over LGLN's DGM1 - the area that had something to lose.
#   data/epochs/<tile_id>.csv   the tile's epoch table, as lgln_epochs() gives
#                it. Written last, for every tile tried, measurable or not, so
#                it is what marks a tile done.
#
# A tile that fails leaves its error in data/log/<tile_id>.txt and no epoch
# file, so the next run tries it again. Losses are found by tile_loss() - see
# R/tile_loss.R for why the epochs are picked on the tile and the detection run
# past its edge.
#
# Tiles come from data/lgln_coverage.gpkg (get_lgln_coverage.R), `comparable`
# ones only. Narrow them with `bbox` or `tile_ids` for a pilot. Every tile is
# read remotely, nothing is downloaded, so the run is bound by the network and
# `n_workers` is worth tuning on a pilot. build_outputs.R turns the tiles into
# a mosaic and a table.
#
# Run from the project root:  Rscript scripts/process_tiles.R
library(sf)
library(terra)
library(rvtr)
library(parallel)

invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))

p <- list(
  res_m         = 1,      # m, DOM1's native grid; bDOM is resampled onto it
  veg_months    = 5:10,   # vegetation period, bDOM only
  min_cover     = 0.05,   # smallest share of the tile an epoch must reach
  loss_drop     = -5,     # m, lasting drop in canopy height counted as loss
  open_radius   = 1.5,    # m, morphological opening, drops speckle
  min_gap       = 20,     # m², smallest loss patch kept
  buffer        = 50,     # m, read past the tile edge, see R/tile_loss.R
  canopy_height = 5)      # m, canopy vs. open
n_workers <- 8            # parallel tiles; 1 runs in this session, for debugging
chunk     <- 4            # tiles per worker between progress reports
bbox      <- NULL         # c(xmin, ymin, xmax, ymax) in EPSG:25832, NULL for all
tile_ids  <- NULL         # tile ids to run, NULL for all

coverage_file <- "data/lgln_coverage.gpkg"
tile_dir      <- "data/tiles"
epoch_dir     <- "data/epochs"
log_dir       <- "data/log"
for (d in c(tile_dir, epoch_dir, log_dir))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)

# What is left to do: comparable tiles, inside the selection, without an epoch
# file yet.
cov <- st_read(coverage_file, query = "SELECT tile_id, comparable FROM tiles",
               quiet = TRUE)
todo <- cov$tile_id[cov$comparable == 1]
if (!is.null(bbox)) {
  x <- as.numeric(substr(todo, 3, 5)) * 1000
  y <- as.numeric(substr(todo, 6, 9)) * 1000
  todo <- todo[x + 1000 > bbox[1] & x < bbox[3] & y + 1000 > bbox[2] & y < bbox[4]]
}
if (!is.null(tile_ids)) todo <- intersect(todo, tile_ids)
done <- sub("\\.csv$", "", list.files(epoch_dir, "\\.csv$"))
message(length(todo), " tiles selected, ", sum(todo %in% done), " already done")
todo <- setdiff(todo, done)

process_tile <- function(tile_id) {
  tl <- tile_loss(tile_id, p)
  on.exit(unlink(tl$grid))
  if (!is.null(tl$year)) {
    dtm <- rast(rvt_data_lgln(tl$grid, product = "dtm"))
    canopy <- starting_canopy(tl$srf, dtm, p$canopy_height) |>
      crop(tile_ext(tile_id))
    out <- c(tl$year, tl$seen, canopy)
    names(out) <- c("loss_year", "observed", "canopy")
    writeRaster(out, file.path(tile_dir, paste0(tile_id, ".tif")),
                datatype = "INT2U", overwrite = TRUE,
                gdal = c("COMPRESS=DEFLATE", "PREDICTOR=2"))
  }
  write.csv(cbind(tile_id = tile_id, tl$ep),
            file.path(epoch_dir, paste0(tile_id, ".csv")), row.names = FALSE)
  if (is.null(tl$year)) "skipped" else "measured"
}

# One tile, never stopping the run: an error goes to the log. The session's
# temp folder is emptied after every tile - the grids, VRTs and terra's own
# scratch files are a few MB a tile, which over the state would fill a disk.
run_one <- function(tile_id) {
  t0 <- Sys.time()
  status <- tryCatch(suppressMessages(process_tile(tile_id)),
                     error = function(e) {
                       writeLines(conditionMessage(e),
                                  file.path(log_dir, paste0(tile_id, ".txt")))
                       "failed"
                     })
  unlink(list.files(tempdir(), full.names = TRUE), recursive = TRUE)
  data.frame(tile_id = tile_id, status = status,
             seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1))
}

if (n_workers > 1) {
  cl <- makeCluster(n_workers)
  clusterCall(cl, setwd, getwd())
  clusterEvalQ(cl, {
    library(terra)
    library(rvtr)
    invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))
    terraOptions(progress = 0)
    NULL
  })
  clusterExport(cl, c("p", "tile_dir", "epoch_dir", "log_dir",
                      "process_tile", "run_one"))
  apply_tiles <- function(ids) parLapplyLB(cl, ids, run_one)
} else {
  apply_tiles <- function(ids) lapply(ids, run_one)
}

# In chunks, so there is progress to report and a run log that survives an
# interruption.
run_log <- file.path(log_dir, "runs.csv")
t_start <- Sys.time()
batches <- split(todo, ceiling(seq_along(todo) / (chunk * n_workers)))
n_done <- 0
for (ids in batches) {
  res <- do.call(rbind, apply_tiles(ids))
  started <- file.exists(run_log)
  write.table(cbind(res, finished = format(Sys.time())), run_log, sep = ",",
              row.names = FALSE, col.names = !started, append = started)
  n_done <- n_done + length(ids)
  per_tile <- as.numeric(difftime(Sys.time(), t_start, units = "secs")) / n_done
  message(sprintf("%d / %d tiles  (%s)  %.1f s per tile, about %.1f h left",
                  n_done, length(todo),
                  paste(names(table(res$status)), table(res$status),
                        collapse = ", "),
                  per_tile, per_tile * (length(todo) - n_done) / 3600))
}

if (n_workers > 1) stopCluster(cl)
