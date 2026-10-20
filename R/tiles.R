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
