# Which LGLN surfaces the change detection takes, and the grid it fetches them
# onto. Shared by everything that draws or measures a loss - the statewide
# tiles here, and the plot circles in lidar-biodiversity-plots - so that a map
# and the check drawn beside it never work from different rules. Drifting
# copies of these rules would make the check lie.
#
# Everything works in EPSG:25832. terra and rvtr are the caller's to load.

# A grid every LGLN product can be fetched onto, written out because
# rvt_data_lgln() takes a location as a file path, not as a SpatRaster. Handing
# it the same path for every product and year lands them all on exactly this
# extent and resolution, so they stack without aligning anything afterwards.
# Snapped to whole multiples of res_m, so the fetch sits on the data's own grid
# and is cropped rather than interpolated onto a half-cell offset.
write_grid <- function(dsm, res_m) {
  e <- ext(dsm)
  e <- ext(floor(e[1] / res_m) * res_m, ceiling(e[2] / res_m) * res_m,
           floor(e[3] / res_m) * res_m, ceiling(e[4] / res_m) * res_m)
  f <- tempfile(fileext = ".tif")
  dsm |>
    resample(rast(e, resolution = res_m, crs = crs(dsm)), method = "max") |>
    writeRaster(f)
  f
}

# Every LGLN surface year for a grid, oldest first, with `used` saying whether
# the change detection will take it and `reason` why not.
#
#   dsm   DOM1, measured by lidar, so the season does not matter.
#   bdom  bDOM20, matched from overlapping aerial photographs, so only the
#         vegetation period counts. A bare broadleaf canopy gives the matcher
#         no texture and it falls through to the forest floor, which would read
#         as the whole stand having vanished.
#
# A year whose tiles stop partway across the grid is kept rather than dropped.
# The fetch returns NoData over the rest, and the differencing reads NoData as
# "this epoch has nothing to say here", so the year still dates the losses in
# the part it does reach. A plot sitting on a tile boundary whose two sides were
# flown in different years is the usual cause, and throwing out both halves left
# those plots with a single epoch and nothing to compare at all. `min_coverage`
# only drops slivers too small to say anything about the grid.
#
# bDOM is judged on both dates, not just one: rvt_data_lgln() gives each tile
# its own latest flight within the year it is asked for, so a single leaf-off
# tile in an otherwise summer year would contaminate the epoch.
lgln_epochs <- function(grid, veg_months, min_coverage = 0.05) {
  y <- rvt_data_lgln_years(grid, product = c("dsm", "bdom"))
  in_veg <- function(d) as.integer(substr(d, 6, 7)) %in% veg_months
  enough <- y$coverage >= min_coverage
  seasonal <- y$product == "dsm" | (in_veg(y$first_date) & in_veg(y$last_date))
  y$used <- enough & seasonal

  # One epoch per year: the two products of a year stand for the same point in
  # time, so differencing one against the other would only measure how far apart
  # lidar and photogrammetry put the canopy top. The one reaching furthest
  # across the grid wins, lidar on a tie since a measured surface needs no
  # photogrammetric stand-in. Coverage decides it rather than the product,
  # because a partial year is usable now and a third of a plot measured by lidar
  # says less than all of it matched from photographs.
  reach <- ifelse(y$used, y$coverage + (y$product == "dsm") * 1e-6, -Inf)
  superseded <- y$used & reach < ave(reach, y$year, FUN = max)
  y$used <- y$used & !superseded

  y$reason <- ifelse(y$used, "",
              ifelse(!enough, "coverage too small",
              ifelse(!seasonal, "outside vegetation period",
                     "other product reaches further in the same year")))
  y[order(y$first_date), ]
}
