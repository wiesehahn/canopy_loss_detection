# The statewide outputs, from whatever process_tiles.R has finished so far -
# so this can run on a pilot, halfway through, or at the end:
#
#   data/canopy_loss_<layer>.vrt all measured tiles as one mosaic, one
#                                single-band VRT per layer of data/tiles/*.tif
#                                - year, observed, canopy, from, species,
#                                crown, tree_top - so the year opens in QGIS as
#                                the one band it is, not as an RGB image. The
#                                species mosaic carries the species' names and
#                                colours, and a raster attribute table.
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
# Reads the tables and the headers of a few tiles, no pixels, so it takes
# seconds even for the whole state. Skipped when the outputs are newer than the
# tables and the coverage they come from.
library(sf)
library(cli)

source("R/trees.R")  # species_classes

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

# Mean and standard deviation of each band over a sample of tiles, one row per
# band, from the statistics process_tiles.R stored in each tile's header. Tiles
# weigh in by their valid cells; a band empty in a tile has no statistics and is
# left out. NA where no sampled tile has the band.
sample_stats <- function(ids, n = 50) {
  gdalraster::set_config_option("GTIFF_SRS_SOURCE", "EPSG")
  on.exit(gdalraster::set_config_option("GTIFF_SRS_SOURCE", ""))
  set.seed(20261109)
  ids <- sort(ids)
  read_tile <- function(id) {
    ds <- methods::new(gdalraster::GDALRaster,
                       file.path(tile_dir, paste0(id, ".tif")), read_only = TRUE)
    on.exit(ds$close())
    item <- \(b, key) as.numeric(ds$getMetadataItem(b, key, ""))
    do.call(rbind, lapply(layers, \(b) c(m = item(b, "STATISTICS_MEAN"),
                                         s = item(b, "STATISTICS_STDDEV"),
                                         n = item(b, "STATISTICS_VALID_PERCENT"))))
  }
  tiles <- lapply(ids[sample(length(ids), min(n, length(ids)))], read_tile)
  do.call(rbind, lapply(seq_along(layers), \(b) {
    x <- do.call(rbind, lapply(tiles, \(t) t[b, ]))
    x <- x[!is.na(x[, "m"]) & !is.na(x[, "s"]) & x[, "n"] > 0, , drop = FALSE]
    m <- sum(x[, "n"] * x[, "m"]) / sum(x[, "n"])
    v <- sum(x[, "n"] * (x[, "s"]^2 + x[, "m"]^2)) / sum(x[, "n"]) - m^2
    c(mean = m, sd = sqrt(max(v, 0)))
  })) |> `rownames<-`(names(layers))
}

# A mosaic VRT, written as text straight from the tile IDs. Every tile raster
# has the same layout - 1000 x 1000 cells of 1 m, UInt32, process_tiles.R's
# NoData - and its lower-left corner is in its ID (R/tiles.R), so no tile has to
# be opened. gdalbuildvrt would open every tile for every band on every build,
# about an hour statewide. The paths are relative to the VRT in data/, so the
# folder can be reached under any path.
#
# `stats` (minimum, maximum, mean, sd) goes into the VRT. Without it GDAL
# calculates a mosaic's statistics when QGIS opens it, tile by tile, and leaves
# an .aux.xml beside every tile. Minimum and maximum are declared ranges, mean
# and sd sampled estimates: exact ones would mean opening every tile, and they
# only serve to display the mosaic.
#
# `classes` (code, name, colour; codes 0, 1, 2, ...) makes it a classified
# layer: Byte, so it is a plain paletted raster to any viewer, with a colour
# table, class names and a raster attribute table.
write_mosaic <- function(ids, band, file, stats, classes = NULL) {
  x0 <- as.numeric(substr(ids, 3, 5)) * 1000         # left edge
  y1 <- as.numeric(substr(ids, 6, 9)) * 1000 + 1000  # top edge
  xmin <- min(x0)
  ymax <- max(y1)
  sources <- sprintf(paste0(
    '    <ComplexSource>\n',
    '      <SourceFilename relativeToVRT="1">tiles/%s.tif</SourceFilename>\n',
    '      <SourceBand>%d</SourceBand>\n',
    '      <SourceProperties RasterXSize="1000" RasterYSize="1000" DataType="UInt32" ',
    'BlockXSize="1000" BlockYSize="1" />\n',
    '      <SrcRect xOff="0" yOff="0" xSize="1000" ySize="1000" />\n',
    '      <DstRect xOff="%.0f" yOff="%.0f" xSize="1000" ySize="1000" />\n',
    '      <NODATA>4294967295</NODATA>\n',
    '    </ComplexSource>'), ids, band, x0 - xmin, ymax - y1)
  band_type <- if (is.null(classes)) "UInt32" else "Byte"
  nodata    <- if (is.null(classes)) "4294967295" else "255"
  interp    <- if (is.null(classes)) "Gray" else "Palette"
  class_xml <- NULL
  if (!is.null(classes)) {
    rgb <- t(col2rgb(classes$colour))
    field <- \(i, name, type, usage) sprintf(paste0(
      '      <FieldDefn index="%d"><Name>%s</Name><Type>%d</Type>',
      '<Usage>%d</Usage></FieldDefn>'), i, name, type, usage)
    class_xml <- c(
      '    <ColorTable>',
      sprintf('      <Entry c1="%d" c2="%d" c3="%d" c4="255"/>', rgb[, 1], rgb[, 2], rgb[, 3]),
      '    </ColorTable>',
      '    <CategoryNames>',
      sprintf('      <Category>%s</Category>', classes$name),
      '    </CategoryNames>',
      '    <GDALRasterAttributeTable tableType="thematic">',
      field(0, "Value", 0, 5), field(1, "Name", 2, 2),  # types 0 integer, 2 text
      field(2, "Red", 0, 6), field(3, "Green", 0, 7), field(4, "Blue", 0, 8),
      sprintf('      <Row index="%d"><F>%d</F><F>%s</F><F>%d</F><F>%d</F><F>%d</F></Row>',
              seq_along(classes$code) - 1L, classes$code, classes$name,
              rgb[, 1], rgb[, 2], rgb[, 3]),
      '    </GDALRasterAttributeTable>')
  }
  writeLines(c(
    sprintf('<VRTDataset rasterXSize="%.0f" rasterYSize="%.0f">',
            max(x0) + 1000 - xmin, ymax - min(y1) + 1000),
    sprintf('  <SRS dataAxisToSRSAxisMapping="1,2">%s</SRS>', st_crs(25832)$wkt),
    sprintf('  <GeoTransform>%.0f, 1, 0, %.0f, 0, -1</GeoTransform>', xmin, ymax),
    sprintf('  <VRTRasterBand dataType="%s" band="1">', band_type),
    sprintf('    <NoDataValue>%s</NoDataValue>', nodata),
    sprintf('    <ColorInterp>%s</ColorInterp>', interp),
    class_xml,
    sprintf(paste0('    <Metadata><MDI key="STATISTICS_MINIMUM">%.10g</MDI>',
                   '<MDI key="STATISTICS_MAXIMUM">%.10g</MDI>',
                   '<MDI key="STATISTICS_MEAN">%.10g</MDI>',
                   '<MDI key="STATISTICS_STDDEV">%.10g</MDI></Metadata>'),
            stats[1], stats[2], stats[3], stats[4]),
    sources,
    '  </VRTRasterBand>',
    '</VRTDataset>'), file)
}

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
  # a tile redone in the same session after its results could not be written
  epochs  <- epochs[!duplicated(epochs[c("tile_id", "product", "year")], fromLast = TRUE), ]

  # The mosaics, over the measured tiles only: a raster left behind by a tile
  # that is being redone, or that failed, stays out.
  measured <- results$tile_id[results$status == "measured"]
  cli_progress_step("Mosaics of {length(measured)} measured tile{?s}")
  if (length(measured)) {
    years <- range(epochs$year[epochs$used])
    ranges <- list(year = years, observed = c(0, 1), canopy = c(0, 1), from = years,
                   species = c(0, 12), crown = c(0, 4294967294), tree_top = c(50, 500))
    sampled <- sample_stats(measured)
    for (l in names(layers)) {
      r <- ranges[[l]]
      s <- sampled[l, ]
      if (anyNA(s)) s <- c(mean(r), diff(r) / 4)
      write_mosaic(measured, layers[[l]], paste0("data/canopy_loss_", l, ".vrt"),
                   c(r, s), if (l == "species") species_classes)
    }
  }

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
