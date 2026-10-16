# The change detection run over one LGLN tile, the way the statewide mosaic
# needs it: shared by process_tiles.R, which writes it, and image_tile.R, which
# draws it, so an image and the mosaic under it agree cell for cell.
#
# Two grids, because a tile is one piece of a mosaic:
#
#   - The epochs are chosen on the bare tile. Chosen on the buffered one, a
#     year flown only over a neighbour could pass min_cover on the buffer strip
#     alone and come in as an epoch that says nothing about the tile itself.
#   - The detection runs on the tile grown by `buffer` and is cropped back.
#     The opening and the min_gap sieve judge a patch by its size, and at a
#     bare tile edge they would see only the part on this side - a cut split
#     by the boundary would be dropped on both sides, or kept on one, and the
#     mosaic would show the tile grid as seams.
#
# `p` holds the detection parameters, as the scripts' config blocks set them:
# res_m, veg_months, min_cover, loss_drop, open_radius, min_gap and buffer.
# epochs.R, detection.R and tiles.R have to be sourced, terra and rvtr loaded.

# A list of:
#   ep     the tile's epoch table, `used` and `reason` filled in, as
#          lgln_epochs() gives it - with `used` cleared and `reason` set when
#          the tile cannot be measured at all.
#   year   loss_year() over the tile, NULL if the tile cannot be measured.
#   seen   observed() over the tile, likewise.
#   grid, srf   the buffered grid and the surfaces on it, for anything else
#          the caller wants read on the same cells (starting canopy, shading).
#          The grid is a temporary file, the caller's to unlink.
tile_loss <- function(tile_id, p) {
  bare <- tile_grid(tile_id, 0, p$res_m)
  on.exit(unlink(bare))
  ep <- lgln_epochs(bare, p$veg_months, p$min_cover)
  used <- ep[ep$used, , drop = FALSE]

  unusable <- function(reason) {
    ep$reason[ep$used] <- reason
    ep$used <- FALSE
    list(ep = ep, year = NULL, seen = NULL, grid = NULL, srf = NULL)
  }
  if (nrow(used) < 2) return(unusable("only epoch, nothing to compare"))

  grid <- tile_grid(tile_id, p$buffer, p$res_m)
  srf  <- surfaces(grid, used)
  d    <- canopy_steps(srf)
  tile <- tile_ext(tile_id)
  seen <- crop(observed(d), tile)

  # Two epochs whose tiles do not meet share no cell, so the one step between
  # them can be read nowhere. That is not a tile with no loss, it is a tile
  # nothing was measured over, and a raster of zeroes would read as the first.
  if (unlist(global(seen, "max", na.rm = TRUE)) == 0)
    return(unusable("no epoch overlaps another"))

  year <- loss_year(d, used$year, p$loss_drop, p$open_radius, p$min_gap) |>
    crop(tile)
  list(ep = ep, year = year, seen = seen, grid = grid, srf = srf)
}
