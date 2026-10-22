# Lost trees: the single trees behind a loss, found only on loss pixels. The
# loss is taken to be whole crowns, so tree tops are looked for within it and
# its pixels are split into crowns. Each tree gets the species most of its crown
# lies on. docs/findings.md says how the window was chosen. terra and lidR are
# the caller's to have installed; lidR is called by namespace.

# The tree species map on the grid of `template`, reprojected per tile.
species_on <- function(template, file) {
  sp <- rast(file)
  around <- project(ext(template), crs(template), crs(sp)) + 50
  project(crop(sp, around), template, method = "near")
}

# The tree-top window (diameter, m) as a function of height for one species
# group: window_factor times the yield-table stand spacing, held constant below
# window_hmin. Unknown species take the mean of the spruce and broadleaf curves.
tree_window <- function(group, p) {
  g <- p$tree_groups
  S <- \(x, h) x$A * pmax(h, p$window_hmin)^x$B
  if (group == "unknown")
    return(\(h) p$window_factor * (S(g$spruce, h) + S(g$broadleaf, h)) / 2)
  \(h) p$window_factor * S(g[[group]], h)
}

# The lost trees of a tile, from what tile_loss() returns (`tl`) and the
# terrain model `dtm` on its grid. Per loss pixel, the canopy height is that of
# the last lidar survey up to loss_from; pixels without one get no tree. A top
# has to be a local maximum of that survey's full canopy height, not only of
# the loss, so a crown flank at the edge of a loss is not taken for a top. The
# crowns cover loss pixels only. NULL if there is nothing to find, otherwise
# three layers on the tile grid, NA off the trees:
#   species   the crown's species code on its pixels.
#   crown     the tree's ID (tree_id()) on its crown's pixels.
#   tree_top  the tree's height in dm, on its top pixel only.
lost_trees <- function(tl, dtm, tile_id, p) {
  tile <- tile_ext(tile_id)
  srf <- crop(tl$srf, tile)
  ep <- tl$ep[tl$ep$used, ]
  dtm <- resample(crop(dtm, tile), srf, method = "bilinear")

  # the lidar survey each loss pixel takes (raster first: terra's `n <= r` is wrong)
  idx <- rast(tl$from, vals = NA)
  for (i in order(ep$year)) if (ep$product[i] == "dsm")
    idx <- ifel(!is.na(tl$from) & tl$from >= ep$year[i] & !is.na(srf[[i]]), i, idx)
  used <- sort(unique(na.omit(values(idx)[, 1])))
  if (!length(used)) return(NULL)
  full <- rast(lapply(used, \(i) srf[[i]] - dtm))
  lyr <- classify(idx, cbind(used, seq_along(used)))
  chm <- toMemory(selectRange(full, lyr))

  # A top depends only on the pixels within half its window, so the full
  # heights are cut down to the loss and that radius around it (a square, which
  # two thin passes give cheaply): the same tops, for a fraction of the cells.
  gnames <- names(p$tree_groups)
  hmax <- unname(unlist(global(chm, "max", na.rm = TRUE)))
  r <- ceiling(max(vapply(gnames, \(g) tree_window(g, p)(hmax), 1)) / 2)
  near <- (!is.na(chm)) |>
    focal(matrix(1, 1, 2 * r + 1), "max", na.rm = TRUE) |>
    focal(matrix(1, 2 * r + 1, 1), "max", na.rm = TRUE)
  full <- mask(full, near, maskvalues = c(0, NA))

  sp <- species_on(chm, p$species)
  codes <- do.call(rbind, lapply(seq_along(gnames), \(i) cbind(p$tree_groups[[i]]$codes, i)))
  grp <- classify(subst(sp, NA, 0), codes)
  groups <- sort(unique(na.omit(values(mask(grp, chm))[, 1])))

  # tops per survey and species group, each with its own window; the heights
  # go to points once per survey
  tops <- do.call(rbind, lapply(seq_along(used), \(li) {
    pts <- as.data.frame(full[[li]], xy = TRUE, na.rm = TRUE)
    if (!nrow(pts)) return(NULL)
    las <- suppressMessages(lidR::LAS(data.frame(X = pts$x, Y = pts$y, Z = pts[[3]]),
                                      crs = sf::st_crs(crs(chm))))
    do.call(rbind, lapply(groups, \(gi) {
      t <- lidR::locate_trees(las, lidR::lmf(tree_window(gnames[gi], p), hmin = p$tree_hmin))
      if (!nrow(t)) return(NULL)
      xy <- sf::st_coordinates(t)[, 1:2, drop = FALSE]
      t[extract(lyr, xy)[, 1] %in% li & extract(grp, xy)[, 1] %in% gi, ]
    }))
  }))
  if (is.null(tops) || !nrow(tops)) return(NULL)
  if (nrow(tops) >= tree_id_per_tile)
    stop(nrow(tops), " lost trees in tile ", tile_id, ", more than a tree ID can number",
         call. = FALSE)
  tops$treeID <- seq_len(nrow(tops))
  crowns <- lidR::dalponte2016(chm, tops)()

  # species per crown: the most frequent map species on it, 0 if none
  ids <- sort(unique(tops$treeID))
  ct <- crosstab(c(crowns, subst(sp, 0, NA)), long = TRUE)
  ct <- ct[order(ct[[1]], -ct[[3]]), ]
  ct <- ct[!duplicated(ct[[1]]), ]
  crown_sp <- setNames(rep(0L, length(ids)), ids)
  crown_sp[as.character(ct[[1]])] <- as.integer(ct[[2]])
  species <- classify(crowns, cbind(ids, crown_sp))

  top <- vect(sf::st_coordinates(tops)[, 1:2, drop = FALSE], crs = crs(chm),
              atts = data.frame(h = round(tops$Z * 10))) |>
    rasterize(chm, field = "h")
  out <- c(species, classify(crowns, cbind(ids, tree_id(tile_id, ids))), top)
  names(out) <- c("species", "crown", "tree_top")
  out
}

# Tree IDs, unique across all tiles and fixed by the tile grid alone, so no
# run or order of tiles changes them: the tile's place in LGLN's tile grid
# (eastings 340-675 km, northings 5682-5980 km) times tree_id_per_tile, plus
# the tree's number within the tile. Up to 3.3e9, so the tile rasters are
# 32-bit. tree_tile() reads the tile back out of an ID.
tree_id_per_tile <- 32768
tree_id <- function(tile_id, n) {
  e <- as.numeric(substr(tile_id, 3, 5)) - 340
  s <- as.numeric(substr(tile_id, 6, 9)) - 5682
  (e * 299 + s) * tree_id_per_tile + n
}
tree_tile <- function(id) {
  cell <- id %/% tree_id_per_tile
  sprintf("32%03d%04d", cell %/% 299 + 340, cell %% 299 + 5682)
}

# All lost trees of the given tile rasters as one table: one row per tree,
# from its top pixel, with its ID, position (cell centre), height (m), species
# and loss period. For analysis, or to write points for an area. Read with
# gdalraster: terra reads 32-bit unsigned bands as R integers, which stop at
# 2.1e9, so it returns NA for the tree IDs.
trees_from_tiles <- function(files) {
  bands <- c(loss_year = 1, loss_from = 4, species = 5, crown = 6, tree_top = 7)
  do.call(rbind, lapply(files, \(f) {
    ds <- methods::new(gdalraster::GDALRaster, f)
    on.exit(ds$close())
    nx <- ds$getRasterXSize(); ny <- ds$getRasterYSize()
    v <- lapply(bands, \(b) ds$read(band = b, xoff = 0, yoff = 0, xsize = nx, ysize = ny,
                                    out_xsize = nx, out_ysize = ny))
    top <- which(!is.na(v$tree_top))
    if (!length(top)) return(NULL)
    gt <- ds$getGeoTransform()                  # x0, dx, 0, y0, 0, -dy
    col <- (top - 1) %% nx; row <- (top - 1) %/% nx
    data.frame(id = v$crown[top], x = gt[1] + (col + 0.5) * gt[2],
               y = gt[4] + (row + 0.5) * gt[6], height = v$tree_top[top] / 10,
               species = v$species[top], loss_from = v$loss_from[top],
               loss_year = v$loss_year[top])
  }))
}
