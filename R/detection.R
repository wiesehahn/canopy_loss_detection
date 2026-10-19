# The change detection itself: what each epoch changed, and which of those
# changes count as the canopy going. Shared by everything that draws or
# measures a loss - the statewide tiles here, and the plot maps and tables in
# lidar-biodiversity-plots - so the only thing keeping a map and its row in a
# table talking about the same losses is that both call this.
#
# epochs.R supplies the grid and the epochs these work on. terra and rvtr are
# the caller's to load.

# Every epoch's canopy surface, stacked in the order the epoch table gives.
# bDOM is taken as the highest of its 20 cm pixels in each cell, as a lidar
# DSM records the highest return. Averaged instead, it sinks into the gaps
# between crowns and reads them as lost; checked against a later lidar survey,
# this halved the false losses at the cost of some real ones at their edges.
# Read into memory once: every operation on a remote VRT streams it again, and
# the native bDOM pixels are most of a tile's run time.
surfaces <- function(grid, ep) {
  srf <- rast(lapply(seq_len(nrow(ep)), function(i) {
    method <- if (ep$product[i] == "bdom") "max" else "cubic"
    rast(rvt_data_lgln(grid, product = ep$product[i], year = ep$year[i],
                       method = method))
  }))
  toMemory(srf)
}

# What each epoch changed against the last surface that had a value there.
# cover() carries that value forward, so a NoData patch in one epoch breaks the
# chain for that epoch only rather than for everything after it. That is what
# makes an epoch reaching only partway across the grid usable: outside its tiles
# the step is NA, the cell keeps the height it last had, and any loss there is
# left for the next epoch whose tiles do reach it.
#
# The steps are taken as measured. Lidar and photogrammetry do not place the
# canopy top identically, so a lidar-to-bDOM step can carry an offset of a
# metre or two before anything has changed - well under the loss threshold.
# Levelling each step on its median was tried: checked against a later lidar
# survey it made no measurable difference, and it made a cell's result depend
# on whatever else lay in the grid.
canopy_steps <- function(srf) {
  previous <- Reduce(\(prev, r) cover(r, prev), as.list(srf), accumulate = TRUE)
  rast(Map(`-`, as.list(srf)[-1], head(previous, -1)))
}

# The cells any step could be read over at all - the grid's measurable part, and
# the denominator every share of it has to be taken against.
observed <- function(d) max(!is.na(d))

# The year each cell first lost its canopy, NA where it never did. `years` is
# the epoch years, first included; the steps in `d` are dated to the later
# epoch of each pair.
#
# The test is an absolute drop only. A relative one - the drop must take away a
# share of the stand's height - would miss trees lost over a lower canopy
# layer, where the surface falls only as far as the layer beneath.
loss_year <- function(d, years, loss_drop, open_radius, min_gap, regrowth) {
  # Each epoch's canopy height relative to the first, accumulated from the steps
  # so the last known value carries over a missing epoch.
  lev <- Reduce(\(prev, r) cover(prev + r, prev), as.list(d),
                init = subst(d[[1]] * 0, NA, 0), accumulate = TRUE)

  # A loss is a drop that lasts: the canopy has to end up below the lowest it
  # had been, and stay there for every epoch after. A bDOM that missed the
  # canopy fails that test from either side - one that reads the canopy too low
  # is contradicted by the epochs after it, and one that reads it too high only
  # lifts a single epoch, so the step back down never clears the running floor
  # it is measured from. What it cannot see through is a bad last epoch, which
  # has nothing after it to be contradicted by.
  #
  # A gap regrows, so each later epoch may stand up to `regrowth` m per year
  # since the loss above where the loss left it and still count as lost.
  lowest <- Reduce(\(prev, r) min(prev, r), head(lev, -1), accumulate = TRUE)
  n <- nlyr(d)
  after <- lapply(seq_len(n), \(k)
    Reduce(\(a, b) max(a, b),
           lapply(k:n, \(j) lev[[j + 1]] - regrowth * (years[j + 1] - years[k + 1]))))
  drop <- rast(after) - rast(lowest)
  loss <- mask(drop < loss_drop, d)

  # opening: erode then dilate, so a patch has to be wider than the kernel to
  # survive, then drop anything smaller than min_gap
  w <- ifelse(focalMat(loss, open_radius, "circle") > 0, 1, NA)
  clean <- \(r) r |>
    focal(w, "min", na.rm = TRUE) |>
    focal(w, "max", na.rm = TRUE) |>
    sieve(round(min_gap / prod(res(loss))))
  loss <- rast(lapply(as.list(loss), clean))

  min(classify(loss * years[-1], cbind(0, NA)), na.rm = TRUE)
}

# Where the stand stood above `canopy_height` when the record starts - the area
# that had something to lose, and so the denominator for any share of it. Not
# srf[[1]] but the earliest surface that reaches each cell: the first epoch does
# not have to cover the whole grid, and a cell it misses is still measurable
# from whichever epoch got there first. `dtm` is whatever terrain the caller
# has: a plot's own ALS DTM, or LGLN's DGM1 where there is none.
starting_canopy <- function(srf, dtm, canopy_height) {
  first <- Reduce(cover, as.list(srf))
  first - resample(dtm, first, method = "bilinear") >= canopy_height
}
