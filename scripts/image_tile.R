# Canopy loss over time for one whole LGLN tile, as one image: where the canopy
# disappeared, coloured by the year it went, over a hillshade. For looking at
# any place in Lower Saxony.
#
# Give it any EPSG:25832 coordinate; it draws the 1 x 1 km tile that point falls
# in. From the project root:
#
#   options(cld.coord = c(600445, 5741390))
#   source("scripts/image_tile.R")
#
# The image goes to data/images/canopy_loss_<tile_id>.webp, or to
# options(cld.image = "path.webp").
#
# The detection is tile_loss() with R/params.R, the same as process_tiles.R
# runs, so the image shows exactly what the mosaic holds for this tile.
# Next to the plot images in lidar-biodiversity-plots:
#
#   - The shading is the tile's first DOM1 at 1 m rather than a plot's ALS
#     surface at 0.25 m, so it is coarser, and shows the stand before the
#     losses drawn over it.
#   - The colour ramp starts in 2010, the first DOM1 year LGLN holds, rather
#     than 2013, so a colour here is not the same year as in the plot images.
#
# data/lgln_coverage.gpkg (get_lgln_coverage.R) says beforehand which tiles
# have two epochs or more to compare.
library(terra)
library(rvtr)

invisible(lapply(list.files("R", "\\.R$", full.names = TRUE), source))

coord     <- getOption("cld.coord")  # EPSG:25832, any point inside the tile
out_path  <- getOption("cld.image")  # NULL: data/images/canopy_loss_<tile_id>.webp
year_span <- c(2010, 2026)           # fixed colour ramp, from the first DOM1 year
p         <- detection_params        # see R/params.R

if (length(coord) != 2 || !is.numeric(coord) || anyNA(coord))
  stop("Set the coordinate first, e.g. options(cld.coord = c(600445, 5741390)).",
       call. = FALSE)

tile_id <- tile_of(coord)
if (is.null(out_path)) {
  dir.create("data/images", recursive = TRUE, showWarnings = FALSE)
  out_path <- file.path("data/images", paste0("canopy_loss_", tile_id, ".webp"))
}

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

render_loss(tl$year, crop(first_dom1(tl), tile_ext(tile_id)), out_path, year_span)
message("written to ", normalizePath(out_path))
