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
#   data/canopy_loss_<layer>.vrt.ovr  its overviews, 8 m and coarser, so a
#                                zoomed-out view does not open every tile.
#   data/canopy_loss_<layer>.qml the QGIS style it opens with (not for species,
#                                which has its own colours, nor crown).
#   data/canopy_loss_tiles.gpkg  two layers:
#     tiles        one polygon per tile in lgln_coverage.gpkg, with its
#                  coverage columns, and for every measured tile the figures
#                  process_tiles.R stored in tile_results.csv: the areas from
#                  loss_metrics() (R/metrics.R), the loss per year as
#                  loss_<year>_m2, and the number of lost trees, in all and
#                  as lost_trees_<year> and lost_trees_<species>. A tile without
#                  them keeps NA, and `reason` says why: too few epochs, no
#                  DGM1, not processed yet, or what stopped it.
#     tile_epochs  every finished tile's epoch table, bound together.
#
# Reads the tables, the headers of a few tiles, and for the overviews the
# tiles' own 8 m overviews: about a minute per mosaic for 5,000 tiles. Skipped
# when the outputs are newer than the tables and the coverage they come from.
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
vrt_files <- setNames(paste0("data/canopy_loss_", names(layers), ".vrt"), names(layers))
outputs   <- c(out_file, vrt_files, paste0(vrt_files, ".ovr"))

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
#
# `hide_nodata` writes the mosaic write_overview() reads: NoData passed through
# as a value, and the band's NoData, which fills the space between the tiles,
# not declared as such.
write_mosaic <- function(ids, band, file, stats, classes = NULL, hide_nodata = FALSE) {
  x0 <- as.numeric(substr(ids, 3, 5)) * 1000         # left edge
  y1 <- as.numeric(substr(ids, 6, 9)) * 1000 + 1000  # top edge
  xmin <- min(x0)
  ymax <- max(y1)
  sources <- sprintf(paste0(
    '    <ComplexSource>\n',
    '      <SourceFilename relativeToVRT="1">tiles/%s.tif</SourceFilename>\n',
    '      <SourceBand>%d</SourceBand>\n',
    '      <SourceProperties RasterXSize="1000" RasterYSize="1000" DataType="UInt32" ',
    'BlockXSize="256" BlockYSize="256" />\n',
    '      <SrcRect xOff="0" yOff="0" xSize="1000" ySize="1000" />\n',
    '      <DstRect xOff="%.0f" yOff="%.0f" xSize="1000" ySize="1000" />\n',
    if (hide_nodata) '' else '      <NODATA>4294967295</NODATA>\n',
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
    if (hide_nodata) '    <HideNoDataValue>1</HideNoDataValue>',
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

# The mosaic's overviews, <file>.ovr: the mosaic at 8 m and coarser in one
# GeoTIFF, which GDAL takes for every zoom level it covers. A view of the whole
# state then reads this one file instead of every tile; zoomed in further, the
# tiles' own overviews serve. Built from those 8 m overviews, like them by the
# most common value with NoData counted as a value (process_tiles.R). Outside
# the tiles it is NoData too.
write_overview <- function(ids, band, file, classes = NULL) {
  src  <- sub("[.]vrt$", "_overview_source.vrt", file)
  ovr  <- paste0(file, ".ovr")
  part <- paste0(ovr, ".part")
  on.exit(unlink(c(src, part)))
  # UInt32 even for a classified mosaic: converted only on writing, the tiles
  # would be read at full resolution (four times as long) for a slightly
  # different mode
  write_mosaic(ids, band, src, rep(0, 4), hide_nodata = TRUE)
  ds <- methods::new(gdalraster::GDALRaster, file, read_only = TRUE)
  size <- ceiling(ds$dim()[1:2] / 8)
  ds$close()
  gdal_utils("translate", src, part, options = c(
    "-of", "GTiff", "-outsize", size, "-r", "mode",
    if (!is.null(classes)) c("-ot", "Byte"),  # NoData 4294967295 becomes 255
    "-co", "TILED=YES", "-co", "COMPRESS=ZSTD", "-co", "ZSTD_LEVEL=15",
    "-co", "BIGTIFF=IF_SAFER"))  # compressed as the tiles are (process_tiles.R)
  ds <- methods::new(gdalraster::GDALRaster, part, read_only = FALSE)
  ds$quiet <- TRUE
  ds$buildOverviews("MODE", 2^(1:7), 0)  # down to 1 km
  ds$setNoDataValue(1, if (is.null(classes)) 4294967295 else 255)
  ds$close()
  if (file.exists(ovr) && !file.remove(ovr))
    cli_abort(c("{.file {ovr}} is in use (open in QGIS?).",
                i = "Close it and run again."))
  invisible(file.rename(part, ovr))
}

# A QGIS style, <file> with .qml, which QGIS applies when the mosaic is added:
# survey years in magma, tree heights in viridis, the 0/1 layers as two
# classes. NoData stays transparent. The species mosaic carries its colours
# itself, and the tree IDs have no useful colouring.
write_style <- function(layer, file, years) {
  item <- \(value, colour, label) sprintf(
    '          <item value="%s" color="%s" alpha="255" label="%s"/>', value, colour, label)
  pseudocolor <- \(type, values, colours, labels) c(
    sprintf(paste0('    <rasterrenderer type="singlebandpseudocolor" band="1" opacity="1" ',
                   'alphaBand="-1" nodataColor="" classificationMin="%s" classificationMax="%s">'),
            min(values), max(values)),
    '      <rastershader>',
    sprintf(paste0('        <colorrampshader colorRampType="%s" classificationMode="1" clip="0" ',
                   'minimumValue="%s" maximumValue="%s" labelPrecision="0">'),
            type, min(values), max(values)),
    item(values, colours, labels),
    '        </colorrampshader>',
    '      </rastershader>',
    '    </rasterrenderer>')
  paletted <- \(colours, labels) c(
    '    <rasterrenderer type="paletted" band="1" opacity="1" alphaBand="-1" nodataColor="">',
    '      <colorPalette>',
    sprintf('        <paletteEntry value="%d" color="%s" alpha="255" label="%s"/>',
            seq_along(colours) - 1L, colours, labels),
    '      </colorPalette>',
    '    </rasterrenderer>')
  hex <- \(x) substr(x, 1, 7)  # viridisLite adds an alpha
  renderer <- switch(layer,
    year = , from = pseudocolor("EXACT", years, hex(viridisLite::magma(length(years), end = 0.9)),
                                years),
    tree_top = pseudocolor("INTERPOLATED", c(50, 500), hex(viridisLite::viridis(2)),
                           c("5 m", "50 m")),
    observed = paletted(c("#636363", "#E0E0E0"), c("not observed", "observed")),
    canopy   = paletted(c("#F0F0F0", "#4D9221"), c("no canopy", "canopy")))
  if (is.null(renderer)) return(invisible())
  writeLines(c("<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>",
               '<qgis styleCategories="Symbology">', '  <pipe>', renderer, '  </pipe>',
               '</qgis>'), sub("[.]vrt$", ".qml", file))
}

inputs <- c(coverage_file, result_file, epoch_file, run_log)
if (!file.exists(result_file)) {
  cli_alert_warning("No tiles processed yet ({.file {result_file}} is missing): nothing to build")
} else if (all(file.exists(outputs)) &&
           min(file.mtime(outputs)) > max(file.mtime(inputs))) {
  cli_alert_success("Mosaics and tile table are up to date: skipped")
} else {
  # The text columns as text: one that is empty in every row would otherwise
  # read as NA throughout.
  text_cols <- intersect(c("tile_id", "epoch_dates", "params", "loss_by_year",
                           "trees_by_year", "trees_by_species"),
                         names(read.csv(result_file, nrows = 0)))
  results <- read.csv(result_file, colClasses = setNames(rep("character", length(text_cols)),
                                                         text_cols))
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
      write_mosaic(measured, layers[[l]], vrt_files[[l]], c(r, s),
                   if (l == "species") species_classes)
      write_style(l, vrt_files[[l]], sort(unique(epochs$year[epochs$used])))
    }
    cli_progress_step("Overviews of the {length(layers)} mosaics")
    for (l in names(layers))
      write_overview(measured, layers[[l]], vrt_files[[l]],
                     if (l == "species") species_classes)
  }

  # The loss and the lost trees per year, and the trees per species, from
  # "2018:1234;2022:567" to a column per key, over every key some tile has.
  # NA for tiles not measured, and for tiles measured before the column was
  # recorded (an empty text is a measured tile with none: zeros).
  cli_progress_step("Tile table")
  for (s in list(list(col = "loss_by_year", name = \(k) paste0("loss_", k, "_m2")),
                 list(col = "trees_by_year", name = \(k) paste0("lost_trees_", k)),
                 list(col = "trees_by_species", name = \(k) paste0("lost_trees_", k),
                      keys = species_classes$name))) {
    text <- results[[s$col]]
    if (is.null(text)) next
    text <- as.character(text)
    counts <- lapply(text, \(x) {
      if (is.na(x) || x == "") return(numeric())
      kv <- do.call(rbind, strsplit(strsplit(x, ";")[[1]], ":"))
      setNames(as.numeric(kv[, 2]), kv[, 1])
    })
    keys <- unique(unlist(lapply(counts, names)))
    keys <- if (is.null(s$keys)) sort(keys) else intersect(s$keys, keys)
    for (k in keys) {
      v <- vapply(counts, \(x) if (k %in% names(x)) x[[k]] else 0, 0)
      v[results$status != "measured" | is.na(text)] <- NA
      results[[s$name(tolower(gsub(" ", "_", k)))]] <- v
    }
    results[[s$col]] <- NULL
  }
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
