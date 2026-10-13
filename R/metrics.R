# A loss raster - the three layers loss_year, observed and canopy that the
# statewide tiles and the plot circles are both written as - turned into areas.
# Shared so a tile's row and a plot's row are measured the same way. terra is
# the caller's to load.
#
# Three areas, because a share on its own would hide what it was taken from:
#
#   observed_m2  the part of the raster some epoch could difference. LGLN tiles
#                stop partway across a plot often enough that this is well
#                under the whole for a few of them. Every share below is taken
#                against it rather than against the whole, which would read a
#                half-measured place as half as disturbed as it is.
#   forest_m2    the observed part that stood above the canopy threshold when
#                the record starts. Only canopy can be lost, so this is the
#                denominator that lets a closed stand be compared with one that
#                is half meadow.
#   loss_m2      canopy that went and stayed gone. Not quite all of it falls
#                inside forest_m2 - a loss on the very edge of the starting
#                canopy need not have its cell centre inside it - so
#                loss_pct_forest measures only the part that does overlap.

# Ground covered by a 0/1 raster, counted on its own grid rather than from a
# radius or a tile size, so every area in a row is measured the same way and
# they divide cleanly into each other.
area_m2 <- function(x) unname(unlist(global(x, "sum", na.rm = TRUE))) * prod(res(x))

# One row of areas and shares for a loss raster `r`.
loss_metrics <- function(r) {
  seen   <- r$observed == 1
  forest <- r$canopy == 1 & seen
  lost   <- !is.na(r$loss_year) & seen

  row <- data.frame(
    observed_m2 = area_m2(seen),
    observed_pct = 100 * area_m2(seen) / area_m2(!is.na(r$observed)),
    forest_m2 = area_m2(forest),
    loss_m2 = area_m2(lost),
    loss_pct = NA_real_,
    loss_forest_m2 = area_m2(lost & forest),
    loss_pct_forest = NA_real_)
  row$loss_pct <- 100 * row$loss_m2 / row$observed_m2
  row$loss_pct_forest <- 100 * row$loss_forest_m2 / row$forest_m2
  row
}

# Loss area per year (m²) within the observed part, as a named vector over
# `years`, zero for a year that lost nothing.
loss_by_year <- function(r, years) {
  y <- mask(r$loss_year, r$observed, maskvalues = c(0, NA))
  f <- freq(y)
  out <- setNames(numeric(length(years)), years)
  if (!is.null(f) && nrow(f)) {
    f <- f[f$value %in% years, ]
    out[as.character(f$value)] <- f$count * prod(res(r))
  }
  out
}
