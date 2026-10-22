# Maps of what LGLN data each tile holds, from data/lgln_coverage.gpkg, as
# PNGs in docs/images/: a quick look at where loss can be measured and how
# well. run.R redraws them whenever it rebuilds the coverage file.
#
#   coverage_epochs.png  usable surveys per tile (lidar any season, photo-based
#                        May-October, one per year)
#   coverage_lidar.png   lidar (DOM1) years per tile
#   coverage_latest.png  year of the latest usable survey
library(sf)
library(terra)

coverage_file <- "data/lgln_coverage.gpkg"
out_dir       <- "docs/images"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tiles <- vect(st_read(coverage_file, "tiles", quiet = TRUE))
grid  <- rast(ext(tiles), resolution = 1000, crs = crs(tiles))

# One map: a tile column on the 1 km grid, one colour per value.
draw <- function(field, title, file) {
  r <- rasterize(tiles, grid, field = field)
  v <- sort(unique(na.omit(values(r)[, 1])))
  png(file.path(out_dir, file), width = 1100, height = 1000, res = 130)
  plot(r, type = "classes", col = hcl.colors(length(v), "viridis"), axes = FALSE,
       box = FALSE, mar = c(0.5, 0.5, 2.5, 7),
       plg = list(title = "", cex = 0.9, x = "right"))
  title(title, cex.main = 1.1)
  dev.off()
}

draw("n_epochs", "Usable surveys per 1 × 1 km tile", "coverage_epochs.png")
draw("dom1_n", "Lidar surveys (DOM1) per tile", "coverage_lidar.png")
draw("last_epoch", "Year of the latest usable survey", "coverage_latest.png")
message("maps written to ", out_dir)
