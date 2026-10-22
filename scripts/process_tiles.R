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
#                Buildings are 0.
#     loss_from  the year of the last survey before the loss - the earliest
#                year it can have gone. The loss lies between the two flights.
#     species    the lost trees (R/trees.R), on their crowns: the tree's
#                species code (0 none, 1-12 as in scripts/get_species.R).
#     crown      the tree's ID on its crown, unique across all tiles.
#     tree_top   the tree's height in dm, on its top pixel only.
#                All three NA off the lost trees; trees_from_tiles() reads them
#                back as one row per tree.
#
# and two tables for all tiles, appended by this session after every batch -
# only it writes them, so the parallel workers never collide:
#
#   data/epochs.csv   every tile's epoch table, as lgln_epochs() gives it, for
#                every tile tried, measurable or not. A tile is done once its
#                rows are here; a run stopped mid-batch redoes that batch.
#   data/runs.csv     one row per attempt: status, seconds, and the error of a
#                failed tile, which has no epoch rows and is tried again.
#
# Losses are found by tile_loss() - see R/tile_loss.R for why the epochs are
# picked on the tile and the detection run past its edge. Run one session at a
# time: two appending to the same tables would mix their rows.
#
# Tiles come from data/lgln_coverage.gpkg (get_lgln_coverage.R), `comparable`
# ones only: two epochs or more, and a DGM1 for the starting canopy. Every tile
# is read remotely, nothing is downloaded, so the run is bound partly by the
# network; beyond about 12 workers it got no faster in testing.
# build_outputs.R turns the tiles into a mosaic and a table.
#
# Usually run through run.R. Options, set before sourcing:
#   options(cld.bbox = c(xmin, ymin, xmax, ymax))  only tiles in this box (EPSG:25832)
#   options(cld.tile_ids = c("326005741"))         only these tiles
#   options(cld.workers = 4)                       parallel workers; 1 runs here, for debugging
library(sf)
library(terra)
library(rvtr)
library(parallel)

invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))

p         <- detection_params  # see R/params.R
bbox      <- getOption("cld.bbox")
tile_ids  <- getOption("cld.tile_ids")
n_workers <- getOption("cld.workers", max(1, detectCores() %/% 2))
chunk     <- 4                 # tiles per worker between progress reports

coverage_file <- "data/lgln_coverage.gpkg"
tile_dir      <- "data/tiles"
epoch_file    <- "data/epochs.csv"
run_log       <- "data/runs.csv"
dir.create(tile_dir, recursive = TRUE, showWarnings = FALSE)
if (!file.exists(p$buildings))
  stop("No building footprints at ", p$buildings, ". Run scripts/get_buildings.R first.",
       call. = FALSE)
if (!file.exists(p$species))
  stop("No tree species map at ", p$species, ". Run scripts/get_species.R first.",
       call. = FALSE)

# What is left to do: comparable tiles, inside the selection, without epoch
# rows yet.
cov <- st_read(coverage_file, query = "SELECT tile_id, comparable FROM tiles",
               quiet = TRUE)
todo <- cov$tile_id[cov$comparable == 1]
if (!is.null(bbox)) {
  x <- as.numeric(substr(todo, 3, 5)) * 1000
  y <- as.numeric(substr(todo, 6, 9)) * 1000
  todo <- todo[x + 1000 > bbox[1] & x < bbox[3] & y + 1000 > bbox[2] & y < bbox[4]]
}
if (!is.null(tile_ids)) todo <- intersect(todo, tile_ids)
done <- if (file.exists(epoch_file))
  unique(read.csv(epoch_file, colClasses = c(tile_id = "character"))$tile_id)
message(length(todo), " tiles selected, ", sum(todo %in% done), " already done")
todo <- setdiff(todo, done)

process_tile <- function(tile_id) {
  tl <- tile_loss(tile_id, p)
  on.exit(unlink(tl$grid))
  if (!is.null(tl$year)) {
    dtm <- rast(rvt_data_lgln(tl$grid, product = "dtm"))
    canopy <- starting_canopy(tl$srf, dtm, p$canopy_height) |>
      crop(tile_ext(tile_id))
    canopy <- ifel(tl$built, 0, canopy)
    trees <- lost_trees(tl, dtm, tile_id, p)
    if (is.null(trees)) trees <- rast(tl$year, nlyrs = 3, vals = NA)
    out <- c(tl$year, tl$seen, canopy, tl$from, trees)
    names(out) <- c("loss_year", "observed", "canopy", "loss_from",
                    "species", "crown", "tree_top")
    # Copied through gdal_translate -stats, so complete band statistics sit
    # inside the GeoTIFF. terra writes only min and max, and a viewer such as
    # QGIS would compute the rest and leave them beside it as .aux.xml. The
    # temporary file goes with the session's temp folder (run_one()).
    tmp <- tempfile(fileext = ".tif")
    writeRaster(out, tmp, datatype = "INT4U")
    sf::gdal_utils("translate", tmp, file.path(tile_dir, paste0(tile_id, ".tif")),
                   options = c("-stats", "-co", "COMPRESS=DEFLATE", "-co", "PREDICTOR=2"),
                   config_options = c(GTIFF_SRS_SOURCE = "EPSG"))
  }
  list(status = if (is.null(tl$year)) "skipped" else "measured",
       ep = cbind(tile_id = tile_id, tl$ep))
}

# One tile, never stopping the run: an error is returned for the run log. The
# session's temp folder is emptied after every tile - the grids, VRTs and
# terra's own scratch files are a few MB a tile, which over the state would
# fill a disk.
run_one <- function(tile_id) {
  t0 <- Sys.time()
  out <- tryCatch(suppressMessages(process_tile(tile_id)),
                  error = function(e)
                    list(status = "failed", ep = NULL,
                         error = gsub("\\s+", " ", conditionMessage(e))))
  unlink(list.files(tempdir(), full.names = TRUE), recursive = TRUE)
  out$run <- data.frame(
    tile_id = tile_id, status = out$status,
    seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1),
    error = if (is.null(out$error)) "" else out$error)
  out
}

# Append rows to a CSV, with the header only when the file is new.
append_csv <- function(x, file) {
  if (is.null(x) || !nrow(x)) return(invisible())
  new <- !file.exists(file)
  write.table(x, file, sep = ",", row.names = FALSE, col.names = new, append = !new)
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
  clusterExport(cl, c("p", "tile_dir", "process_tile", "run_one"))
  apply_tiles <- function(ids) parLapplyLB(cl, ids, run_one)
} else {
  apply_tiles <- function(ids) lapply(ids, run_one)
}

# In chunks, so there is progress to report and tables that survive an
# interruption. The epoch rows go last: they are what marks a tile done.
t_start <- Sys.time()
batches <- split(todo, ceiling(seq_along(todo) / (chunk * n_workers)))
n_done <- 0
for (ids in batches) {
  out <- apply_tiles(ids)
  res <- do.call(rbind, lapply(out, `[[`, "run"))
  append_csv(cbind(res, finished = format(Sys.time())), run_log)
  append_csv(do.call(rbind, lapply(out, `[[`, "ep")), epoch_file)
  n_done <- n_done + length(ids)
  per_tile <- as.numeric(difftime(Sys.time(), t_start, units = "secs")) / n_done
  message(sprintf("%d / %d tiles  (%s)  %.1f s per tile, about %.1f h left",
                  n_done, length(todo),
                  paste(names(table(res$status)), table(res$status),
                        collapse = ", "),
                  per_tile, per_tile * (length(todo) - n_done) / 3600))
}

if (n_workers > 1) stopCluster(cl)
