# The change detection itself: what each epoch changed, and which of those
# changes count as the canopy going. Shared by everything that draws or
# measures a loss - the statewide tiles here, and the plot maps and tables in
# lidar-biodiversity-plots - so the only thing keeping a map and its row in a
# table talking about the same losses is that both call this.
#
# epochs.R supplies the grid and the epochs these work on. terra and rvtr are
# the caller's to load.

# Every epoch's canopy surface, stacked in the order the epoch table gives.
surfaces <- function(grid, ep) {
  rast(lapply(seq_len(nrow(ep)), function(i)
    rast(rvt_data_lgln(grid, product = ep$product[i], year = ep$year[i]))))
}

# What each epoch changed against the last surface that had a value there.
# cover() carries that value forward, so a NoData patch in one epoch breaks the
# chain for that epoch only rather than for everything after it. That is what
# makes an epoch reaching only partway across the grid usable: outside its tiles
# the step is NA, the cell keeps the height it last had, and any loss there is
# left for the next epoch whose tiles do reach it.
#
# Lidar and photogrammetry do not place the canopy top identically, and the
# lidar years themselves mix summer and winter flights, so every step carries a
# constant offset before anything has actually changed. `deshift` subtracts the
# median of each step, which takes that offset out along with the stand's
# average growth over the interval - so the threshold in loss_year() reads as
# "this much below what the rest of the stand did", not as an absolute drop.
# Offsets run from a few centimetres to about two metres here, so leaving it off
# is not the safer choice. What it cannot take out is the part of the offset
# that varies across the grid, so read a lidar-to-bDOM step with more care than
# a lidar-to-lidar one.
canopy_steps <- function(srf, deshift = TRUE) {
  previous <- Reduce(\(prev, r) cover(r, prev), as.list(srf), accumulate = TRUE)
  d <- rast(Map(`-`, as.list(srf)[-1], head(previous, -1)))
  if (deshift) {
    # Over the cells the step actually has, so a partial epoch is levelled on
    # the part of the stand it saw. The share it was read from is printed with
    # it, because that is what says how much to trust it: min_cover holds each
    # epoch above a sliver, but two epochs can still overlap in very little.
    # Two whose tiles do not meet at all share no cell, the median comes back
    # NA, and subtracting it would turn a whole step into NoData - there is
    # nothing to level in a step that is already empty, so leave it alone.
    shift <- unlist(global(d, median, na.rm = TRUE))
    share <- unlist(global(!is.na(d), "mean", na.rm = TRUE))
    message("  median offset per step: ",
            paste(sprintf("%+.2f m over %.0f%%", shift, 100 * share),
                  collapse = ", "))
    shift[is.na(shift)] <- 0
    d <- d - shift
  }
  d
}

# The cells any step could be read over at all - the grid's measurable part, and
# the denominator every share of it has to be taken against.
observed <- function(d) max(!is.na(d))

# The year each cell first lost its canopy, NA where it never did. `years` is
# the epoch years, first included; the steps in `d` are dated to the later
# epoch of each pair.
loss_year <- function(d, years, loss_drop, open_radius, min_gap) {
  # Each epoch's canopy height relative to the first, accumulated from the steps
  # so the last known value carries over a missing epoch.
  lev <- Reduce(\(prev, r) cover(prev + r, prev), as.list(d),
                init = subst(d[[1]] * 0, NA, 0), accumulate = TRUE)

  # A loss is a drop that lasts: the canopy has to end up below the lowest it
  # had been, and stay there for every epoch after. A bDOM that missed the
  # canopy fails that test from either side - one that reads the canopy too low
  # is contradicted by the epochs after it, and one that reads it too high only
  # lifts a single epoch, so the step back down never clears the running floor
  # it is measured from. Real regrowth after a cut is slow enough to stay below
  # the floor, so this costs nothing; what it cannot see through is a bad last
  # epoch, which has nothing after it to be contradicted by.
  lowest <- Reduce(\(prev, r) min(prev, r), head(lev, -1), accumulate = TRUE)
  after  <- rev(Reduce(\(nxt, r) max(nxt, r), rev(lev[-1]), accumulate = TRUE))
  loss <- mask(rast(after) - rast(lowest) < loss_drop, d)

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
