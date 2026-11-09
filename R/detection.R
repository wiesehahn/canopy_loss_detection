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
#
# `p` holds the detection parameters, as detection_params (R/params.R) sets
# them. `lidar` says for each epoch, the first included, whether it is lidar
# (DOM1). `above_ground` is the height of the first surface above DGM1, and
# `lake` TRUE on standing water.
loss_year <- function(d, years, p, lidar, above_ground, lake) {
  n <- nlyr(d)
  stopifnot(is.logical(lidar), length(lidar) == n + 1)
  # Each epoch's canopy height relative to the first, accumulated from the steps
  # so the last known value carries over a missing epoch.
  lev <- Reduce(\(prev, r) cover(prev + r, prev), as.list(d),
                init = subst(d[[1]] * 0, NA, 0), accumulate = TRUE)

  # The height each drop is measured from. A lidar epoch resets it to what it
  # measured, so canopy that grew up and was then cut counts as lost. A bDOM
  # epoch can only lower it, never raise it: bDOM tends to read the canopy a
  # metre or more too high, and a reference raised by that pushes drops of
  # 3-4 m over the threshold (checked against later lidar, about half of such
  # losses were not confirmed, against 3 % where the reference was lidar;
  # docs/findings.md, 2026-11-05). A bDOM that reads too high once therefore
  # changes nothing, and one that reads too low is contradicted by the epochs
  # after it.
  #
  # A loss is a drop below that reference that lasts: the canopy has to stay
  # down for every epoch after. What this cannot see through is a bad last
  # epoch, which has nothing after it to be contradicted by. A gap regrows, so
  # each later epoch may stand up to `regrowth` m per year since the loss above
  # where the loss left it and still count as lost.
  ref <- list(lev[[1]])
  for (k in seq_len(n)[-1])
    ref[[k]] <- if (lidar[k]) cover(mask(lev[[k]], d[[k - 1]]), ref[[k - 1]])
                else min(ref[[k - 1]], lev[[k]])
  after <- lapply(seq_len(n), \(k)
    Reduce(\(a, b) max(a, b),
           lapply(k:n, \(j) lev[[j + 1]] - p$regrowth * (years[j + 1] - years[k + 1]))))
  drop <- rast(after) - rast(ref)
  loss <- mask(drop < p$loss_drop, d)

  # Drops that are no lost trees (docs/findings.md, 2026-11-09): a reference too
  # tall for a tree is a wind turbine or a pylon, and a surface below the ground
  # a quarry or a hole in a bDOM. Old lidar surveys run a surface over open
  # water from the tree tops on the shore, so on a lake a later lidar survey
  # lying flat on DGM1 shows no loss. Rivers and canals are left out: the
  # polygons reach under the trees on their banks.
  height <- rast(lev) + above_ground
  loss <- rast(lapply(seq_len(n), \(k) {
    no_tree <- ref[[k]] + above_ground > p$max_height |
      height[[k + 1]] < -p$below_ground
    if (lidar[k + 1])
      no_tree <- no_tree | (lake & abs(height[[k + 1]]) <= p$lake_flat)
    ifel(cover(no_tree, init(no_tree, FALSE)), 0, loss[[k]])
  }))

  # opening: erode then dilate, so a patch has to be wider than the kernel to
  # survive, then drop anything smaller than min_gap
  w <- ifelse(focalMat(loss, p$open_radius, "circle") > 0, 1, NA)
  min_cells <- round(p$min_gap / prod(res(loss)))
  clean <- \(r) r |>
    focal(w, "min", na.rm = TRUE) |>
    focal(w, "max", na.rm = TRUE) |>
    drop_small(min_cells)
  loss <- rast(lapply(as.list(loss), clean))

  min(classify(loss * years[-1], cbind(0, NA)), na.rm = TRUE)
}

# 1 on the patches of `r` with at least `min_cells` cells, 0 elsewhere. Not
# sieve(), which would also fill the small holes in a loss and count the single
# trees still standing in them as lost.
drop_small <- function(r, min_cells) {
  id <- values(patches(r, directions = 8, zeroAsNA = TRUE), mat = FALSE)
  setValues(r, as.numeric(!is.na(id) & tabulate(id)[id] >= min_cells))
}

# The earliest year a loss can have happened: the year of the last survey that
# saw the cell before the loss. `year` is what loss_year() gives, the year of
# the first survey that shows it, so the loss lies between the two flights. A
# survey that did not reach the cell is skipped. The same year as that last
# survey, not the next, since many flights are in early spring.
loss_from <- function(srf, years, year) {
  seen <- rast(lapply(seq_along(years), \(i) ifel(is.na(srf[[i]]), NA, years[i])))
  before <- ifel(seen < year, seen, NA)
  mask(max(before, na.rm = TRUE), year)
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
