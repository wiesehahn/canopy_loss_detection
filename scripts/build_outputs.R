# The statewide outputs, from whatever process_tiles.R has written so far - so
# this can run on a pilot, halfway through, or at the end:
#
#   data/canopy_loss_<layer>.vrt all tiles as one mosaic, one single-band VRT
#                                per layer of data/tiles/*.tif - year,
#                                observed, canopy, from - so the year opens in
#                                QGIS as the one band it is, not as an RGB
#                                image.
#   data/canopy_loss_tiles.gpkg  two layers:
#     tiles        one polygon per tile in lgln_coverage.gpkg, with its
#                  coverage columns, and for every measured tile the areas
#                  from loss_metrics() (R/metrics.R) and the loss per year as
#                  loss_<year>_m2. A tile with no raster keeps NA and `reason`
#                  says why: too few epochs, no DGM1, not processed yet, or
#                  what stopped it.
#     tile_epochs  every tile's epoch table, bound together.
#
# Reads only what is on disk, nothing remote.
library(sf)
library(terra)

invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))

years         <- 2010:2026  # columns of loss area per year
coverage_file <- "data/lgln_coverage.gpkg"
tile_dir      <- "data/tiles"
epoch_file    <- "data/epochs.csv"
out_file      <- "data/canopy_loss_tiles.gpkg"

# band of the tile rasters -> name of its mosaic
layers <- c(year = 1, observed = 2, canopy = 3, from = 4)

tile_files <- list.files(tile_dir, "\\.tif$", full.names = TRUE)
message(length(tile_files), " tile rasters")

for (l in names(layers))
  vrt(tile_files, paste0("data/canopy_loss_", l, ".vrt"),
      options = c("-b", layers[[l]]), overwrite = TRUE)

epochs <- read.csv(epoch_file, colClasses = c(tile_id = "character"))

# One row per measured tile.
tile_row <- function(f) {
  id <- sub("\\.tif$", "", basename(f))
  r <- rast(f)
  used <- epochs[epochs$tile_id == id & epochs$used, ]
  by_year <- loss_by_year(r, years)
  cbind(data.frame(tile_id = id, first_year = min(used$year),
                   last_year = max(used$year), n_used = nrow(used)),
        loss_metrics(r),
        as.data.frame(as.list(setNames(by_year, paste0("loss_", years, "_m2")))))
}
measured <- do.call(rbind, lapply(tile_files, tile_row))

# Why a tile has no raster. The reasons that stop a tile outright, as
# tile_loss() sets them, are the only ones that can apply to a tile that was
# processed and still has no raster.
stopped <- epochs[epochs$reason %in% c("only epoch, nothing to compare",
                                       "no epoch overlaps another"), ]
stopped <- stopped[!duplicated(stopped$tile_id), c("tile_id", "reason")]

tiles <- st_read(coverage_file, "tiles", quiet = TRUE)
tiles <- merge(tiles, measured, by = "tile_id", all.x = TRUE)
tiles <- merge(tiles, stopped, by = "tile_id", all.x = TRUE)
tiles$reason[is.na(tiles$reason)] <- ""
tiles$reason[!tiles$comparable] <- "fewer than two epochs in the tile index"
tiles$reason[!tiles$dgm1] <- "no DGM1 terrain model"
tiles$reason[tiles$reason == "" & is.na(tiles$observed_m2)] <- "not processed yet"

num <- vapply(st_drop_geometry(tiles), is.double, TRUE)
tiles[names(num)[num]] <- lapply(st_drop_geometry(tiles)[num], round, 1)

if (file.exists(out_file)) file.remove(out_file)
st_write(tiles, out_file, layer = "tiles", quiet = TRUE)
st_write(epochs, out_file, layer = "tile_epochs", append = TRUE, quiet = TRUE)

message(sum(!is.na(tiles$observed_m2)), " of ", sum(tiles$comparable),
        " comparable tiles measured")
