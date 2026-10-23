# The statewide outputs, from whatever process_tiles.R has finished so far -
# so this can run on a pilot, halfway through, or at the end:
#
#   data/canopy_loss_<layer>.vrt all measured tiles as one mosaic, one
#                                single-band VRT per layer of data/tiles/*.tif
#                                - year, observed, canopy, from, species,
#                                crown, tree_top - so the year opens in QGIS as
#                                the one band it is, not as an RGB image.
#   data/canopy_loss_tiles.gpkg  two layers:
#     tiles        one polygon per tile in lgln_coverage.gpkg, with its
#                  coverage columns, and for every measured tile the figures
#                  process_tiles.R stored in tile_results.csv: the areas from
#                  loss_metrics() (R/metrics.R), the loss per year as
#                  loss_<year>_m2, and the number of lost trees. A tile without
#                  them keeps NA, and `reason` says why: too few epochs, no
#                  DGM1, not processed yet, or what stopped it.
#     tile_epochs  every finished tile's epoch table, bound together.
#
# Reads only the tables, not the rasters, so it takes seconds even for the
# whole state. Skipped when the outputs are newer than the tables and the
# coverage they come from.
library(sf)
library(terra)
library(cli)

coverage_file <- "data/lgln_coverage.gpkg"
tile_dir      <- "data/tiles"
result_file   <- "data/tile_results.csv"
epoch_file    <- "data/epochs.csv"
run_log       <- "data/runs.csv"
out_file      <- "data/canopy_loss_tiles.gpkg"

# band of the tile rasters -> name of its mosaic
layers <- c(year = 1, observed = 2, canopy = 3, from = 4, species = 5, crown = 6,
            tree_top = 7)
vrt_files <- paste0("data/canopy_loss_", names(layers), ".vrt")

inputs <- c(coverage_file, result_file, epoch_file, run_log)
if (!file.exists(result_file)) {
  cli_alert_warning("No tiles processed yet ({.file {result_file}} is missing): nothing to build")
} else if (all(file.exists(c(out_file, vrt_files))) &&
           min(file.mtime(c(out_file, vrt_files))) > max(file.mtime(inputs))) {
  cli_alert_success("Mosaics and tile table are up to date: skipped")
} else {
  results <- read.csv(result_file, colClasses = c(tile_id = "character",
                                                  epoch_dates = "character",
                                                  params = "character"))
  epochs  <- read.csv(epoch_file, colClasses = c(tile_id = "character"))

  # The mosaics, over the measured tiles only: a raster left behind by a tile
  # that is being redone, or that failed, stays out.
  measured <- results$tile_id[results$status == "measured"]
  tile_files <- file.path(tile_dir, paste0(measured, ".tif"))
  tile_files <- tile_files[file.exists(tile_files)]
  cli_progress_step("Mosaics of {length(tile_files)} measured tile{?s}")
  if (length(tile_files))
    for (l in names(layers))
      vrt(tile_files, paste0("data/canopy_loss_", l, ".vrt"),
          options = c("-b", layers[[l]]), overwrite = TRUE)

  # The loss per year, from "2018:1234;2022:567" to a column per year, over
  # every year that lost anything in some tile.
  cli_progress_step("Tile table")
  by_year <- lapply(results$loss_by_year, \(s) {
    if (is.na(s) || s == "") return(numeric())
    kv <- do.call(rbind, strsplit(strsplit(s, ";")[[1]], ":"))
    setNames(as.numeric(kv[, 2]), kv[, 1])
  })
  for (y in sort(unique(unlist(lapply(by_year, names))))) {
    col <- vapply(by_year, \(v) if (y %in% names(v)) v[[y]] else 0, 0)
    col[results$status != "measured"] <- NA
    results[[paste0("loss_", y, "_m2")]] <- col
  }
  results$loss_by_year <- NULL
  results$epoch_dates  <- NULL  # the coverage's own, current, is in the table

  tiles <- st_read(coverage_file, "tiles", quiet = TRUE)
  tiles <- merge(tiles, results, by = "tile_id", all.x = TRUE)

  # Why a tile has no figures. A failed tile has no result row, only its error
  # in the run log.
  runs <- read.csv(run_log, colClasses = c(tile_id = "character"))
  runs <- runs[!duplicated(runs$tile_id, fromLast = TRUE), ]  # the last attempt
  runs <- runs[runs$status == "failed", ]
  error <- runs$error[match(tiles$tile_id, runs$tile_id)]
  failed <- is.na(tiles$status) & !is.na(error)
  tiles$reason[is.na(tiles$reason)] <- ""
  tiles$reason[failed] <- paste("failed:", error[failed])
  tiles$reason[!tiles$comparable] <- "fewer than two epochs in the tile index"
  tiles$reason[!tiles$dgm1] <- "no DGM1 terrain model"
  tiles$reason[tiles$reason == "" & is.na(tiles$status)] <- "not processed yet"
  tiles <- tiles[c(setdiff(names(st_drop_geometry(tiles)), "reason"), "reason")]

  # Written beside the old file and swapped in at the end, so a file open in
  # QGIS stops the build with a message instead of leaving half a table.
  cli_progress_step("Writing {.file {out_file}}")
  tmp <- sub("[.]gpkg$", "_part.gpkg", out_file)
  unlink(tmp)
  st_write(tiles, tmp, layer = "tiles", quiet = TRUE)
  st_write(epochs, tmp, layer = "tile_epochs", append = TRUE, quiet = TRUE)
  if (file.exists(out_file) && !file.remove(out_file))
    cli_abort(c("{.file {out_file}} is in use (open in QGIS?).",
                i = "Close it and run again; the new table is in {.file {tmp}}."))
  invisible(file.rename(tmp, out_file))
  cli_progress_done()

  cli_alert_success(paste(
    "{sum(tiles$status == 'measured', na.rm = TRUE)} of {sum(tiles$comparable)}",
    "comparable tiles measured, {sum(tiles$status == 'skipped', na.rm = TRUE)} skipped,",
    "{sum(failed)} failed"))
}
