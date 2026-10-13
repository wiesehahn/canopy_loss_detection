# Canopy loss over time for one whole LGLN tile, as one image: where the canopy
# disappeared, coloured by the year it went, over a hillshade. For looking at
# any place in Lower Saxony.
#
# Give it any EPSG:25832 coordinate; it draws the 1 x 1 km tile that point falls
# in. From the project root:
#
#   Rscript scripts/image_tile.R 600445,5741390
#   Rscript scripts/image_tile.R 600445,5741390 out/my_tile.webp
#
# or set `coord` below and source it. The image goes to the system temp folder
# unless a path is given - not tempdir(), which an Rscript session deletes as it
# exits.
#
# The detection is tile_loss(), the same as process_tiles.R runs, with the same
# thresholds, so the image shows exactly what the mosaic holds for this tile.
# Next to the plot images in lidar-biodiversity-plots:
#
#   - The shading is the tile's first DOM1 at 1 m rather than a plot's ALS
#     surface at 0.25 m, so it is coarser, and shows the stand before the
#     losses drawn over it.
#   - The colour ramp starts in 2010, the first DOM1 year LGLN holds, rather
#     than 2013, so a colour here is not the same year as in the plot images.
#   - `deshift` levels every step on the median of the whole (buffered) tile.
#     A tile that is mostly field is levelled on the field, so read a tile with
#     little forest in it with more care.
#
# data/lgln_coverage.gpkg (get_lgln_coverage.R) says beforehand which tiles
# have two epochs or more to compare.
library(terra)
library(rvtr)

invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))

coord     <- c(600445, 5741390)  # EPSG:25832, any point inside the tile
out_path  <- NULL                # NULL: <temp>/canopy_loss_<tile_id>.webp
year_span <- c(2010, 2026)       # fixed colour ramp, from the first DOM1 year
p <- list(
  res_m       = 1,      # m, DOM1's native grid; bDOM is resampled onto it
  veg_months  = 5:10,   # vegetation period, bDOM only
  min_cover   = 0.05,   # smallest share of the tile an epoch must reach
  loss_drop   = -5,     # m, drop below the stand's own median counted as loss
  open_radius = 1.5,    # m, morphological opening, drops speckle
  min_gap     = 20,     # m², smallest loss patch kept
  deshift     = TRUE,   # level each step on its median, see R/detection.R
  buffer      = 50)     # m, read past the tile edge, see R/tile_loss.R

args <- commandArgs(trailingOnly = TRUE)
if (length(args) >= 1) coord <- as.numeric(strsplit(args[1], ",")[[1]])
if (length(args) >= 2) out_path <- args[2]
if (length(coord) != 2 || anyNA(coord))
  stop("Give the coordinate as x,y in EPSG:25832, e.g. 600445,5741390.",
       call. = FALSE)

tile_id <- tile_of(coord)
if (is.null(out_path))
  out_path <- file.path(dirname(tempdir()), paste0("canopy_loss_", tile_id, ".webp"))

message("tile ", tile_id)
tl <- tile_loss(tile_id, p)
print(tl$ep[c("product", "year", "first_date", "last_date", "coverage", "used", "reason")],
      row.names = FALSE)
if (is.null(tl$year))
  stop("Tile ", tile_id, " cannot be measured: ",
       setdiff(unique(tl$ep$reason), "")[1], call. = FALSE)

# Losses dated outside the colour ramp would not be drawn at all, which reads
# as no loss. Say so rather than hide them; widen year_span if they matter.
outside <- unlist(global(tl$year < year_span[1] | tl$year > year_span[2], "sum",
                         na.rm = TRUE))
if (outside > 0)
  message("  ", outside, " loss cells dated outside year_span, not drawn")

# The first DOM1 for the shading, so every gap reads against the stand it was
# cut out of. Its holes, and the part of the tile it does not reach, are closed
# from the epochs, oldest first.
ep <- tl$ep
dsm_years <- ep$year[ep$product == "dsm" & ep$coverage > 0]
if (length(dsm_years)) {
  shade_dsm <- rast(rvt_data_lgln(tl$grid, product = "dsm", year = min(dsm_years)))
  shade_dsm <- Reduce(cover, as.list(tl$srf), init = shade_dsm)
} else {
  shade_dsm <- Reduce(cover, as.list(tl$srf))
}

render_loss(tl$year, crop(shade_dsm, tile_ext(tile_id)), out_path, year_span)
message("written to ", normalizePath(out_path))
