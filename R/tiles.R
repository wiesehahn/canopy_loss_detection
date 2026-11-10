# LGLN's 1 x 1 km tiles, by the id LGLN gives them: "32" for the UTM zone, then
# the lower-left corner in km, three digits east and four north - 326005741 is
# the tile from 600000,5741000 to 601000,5742000. EPSG:25832 throughout.
# terra is the caller's to load.

# The tile a point falls in, `xy` as c(x, y).
tile_of <- function(xy) {
  sprintf("32%03d%04d", floor(xy[1] / 1000), floor(xy[2] / 1000))
}

# The tile's extent, grown by `buffer` metres on every side.
tile_ext <- function(tile_id, buffer = 0) {
  x <- as.numeric(substr(tile_id, 3, 5)) * 1000
  y <- as.numeric(substr(tile_id, 6, 9)) * 1000
  ext(x - buffer, x + 1000 + buffer, y - buffer, y + 1000 + buffer)
}

# TRUE where a building footprint, grown by `grow` metres, covers a cell of
# `template`. Reads only the footprints near the template from `file`, the
# GeoPackage scripts/get_buildings.R writes.
built_up <- function(template, file, grow = 1) {
  if (!file.exists(file))
    stop("No building footprints at ", file, ". Run scripts/get_buildings.R first.",
         call. = FALSE)
  v <- vect(file, layer = "buildings", extent = ext(template) + grow + 1)
  if (!nrow(v)) return(init(template, FALSE))
  rasterize(buffer(v, grow), template, background = 0) == 1
}

# TRUE where standing water covers a cell of `template`, from the GeoPackage
# scripts/get_lakes.R writes.
lakes_on <- function(template, file) {
  if (!file.exists(file))
    stop("No lakes at ", file, ". Run scripts/get_lakes.R first.", call. = FALSE)
  v <- vect(file, layer = "lakes", extent = ext(template))
  if (!nrow(v)) return(init(template, FALSE))
  rasterize(v, template, background = 0) == 1
}

# DGM1 over `grid` (a raster file such as tile_grid() writes), the same cells
# rvt_data_lgln(grid, product = "dtm") gives. With `dir`, the local copy that
# scripts/get_dgm1.R keeps is read instead of LGLN's server: per DGM1 tile under
# the grid its file there, or, if that one is missing, the same flight streamed
# from the URL in the copy's index.csv. Tiles the index does not list have no
# DGM1 at all and stay NA, as they do from rvtr. Without `dir`, with no index
# there, or on a grid other than DGM1's own 1 m (which rvtr resamples), all is
# streamed through rvtr. The copy is only read, so parallel workers can share it.
tile_dtm <- function(grid, dir = NULL) {
  stream <- function() rast(rvt_data_lgln(grid, product = "dtm"))
  index <- if (length(dir) && nzchar(dir)) file.path(dir, "index.csv") else ""
  if (!file.exists(index)) return(stream())
  g <- rast(grid)
  if (!isTRUE(all.equal(res(g), c(1, 1)))) return(stream())

  # The DGM1 tiles the grid touches: lower-left corners in km.
  e  <- as.vector(ext(g))  # xmin, xmax, ymin, ymax
  kx <- seq(floor(e[1] / 1000), ceiling(e[2] / 1000) - 1)
  ky <- seq(floor(e[3] / 1000), ceiling(e[4] / 1000) - 1)
  ids <- sprintf("32%03d%04d", rep(kx, length(ky)), rep(ky, each = length(kx)))

  idx <- read.csv(index, colClasses = "character")
  idx <- idx[idx$tile_id %in% ids, ]
  if (!nrow(idx)) return(stream())  # no DGM1 here at all, rvtr says so its way
  local <- file.path(dir, paste0(idx$tile_id, ".tif"))
  src <- ifelse(file.exists(local), local, paste0("/vsicurl/", idx$dgm1))

  # The VRT rvtr builds at the native resolution (rvtr:::.lgln_vrt), over
  # these sources instead.
  out <- tempfile(fileext = ".vrt")
  gdalraster::buildVRT(out, src, quiet = TRUE, cl_arg = c(
    "-te", sprintf("%.6f", e[c(1, 3, 2, 4)]), "-tr", "1", "1",
    "-allow_projection_difference", "-a_srs", "EPSG:25832"))
  rast(out)
}

# A grid over the tile for rvt_data_lgln(), written out as write_grid() does
# for a plot. The tile's corners already sit on whole metres, so every product
# lands on its own cells. `buffer` reaches into the neighbouring tiles, for
# anything that has to see past the tile's edge to get the edge right.
tile_grid <- function(tile_id, buffer = 0, res_m = 1) {
  f <- tempfile(fileext = ".tif")
  rast(tile_ext(tile_id, buffer), resolution = res_m, crs = "EPSG:25832",
       vals = 0) |>
    writeRaster(f, datatype = "INT1U")
  f
}
