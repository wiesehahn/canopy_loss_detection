# The detection settings, in one place, so the statewide tiles and the single
# tile images cannot drift apart. docs/findings.md says how each was chosen.
#
# process_tiles.R redoes every tile made with other settings than these, so
# changing one here redoes the state (2-3 days). `method` is there for
# changes to the code in R/, or to the rvtr version, that alter the results:
# raise it and they are redone too. Changes that leave the results alone (comments, speed) need no
# new number.

detection_params <- list(
  method        = 4,      # raise after a change in R/ or rvtr that alters the results
                          # 2: lidar resets the loss reference (2026-11-05)
                          # 3: rvtr 55a3b00, bDOM 2025 no longer 40 m high (2026-11-05)
                          # 4: drops that are no lost trees left out, holes no longer filled (2026-11-09);
                          #    the same rules for the starting canopy (2026-11-10)
  res_m         = 1,      # m, DOM1's native grid; bDOM is resampled onto it
  veg_months    = 5:10,   # vegetation period, bDOM only
  min_cover     = 0.05,   # smallest share of the tile an epoch must reach
  loss_drop     = -5,     # m, lasting drop in canopy height counted as loss
  regrowth      = 0.5,    # m per year a gap may regrow and still count as lost
  open_radius   = 1.5,    # m, morphological opening (3 x 3 cells), drops speckle
  min_gap       = 20,     # m², smallest loss patch kept
  max_height    = 65,     # m above DGM1, a taller reference is no tree
  below_ground  = 2,      # m below DGM1, a surface lower than this is no lost tree
  lake_flat     = 0.3,    # m around DGM1, a lidar surface on a lake this close lies flat
  lakes         = "data/lakes.gpkg",      # Basis-DLM standing water, scripts/get_lakes.R
  buffer        = 50,     # m, read past the tile edge, see R/tile_loss.R
  canopy_height = 5,      # m, canopy vs. open when the record starts
  buildings     = "data/buildings.gpkg",  # ALKIS footprints, scripts/get_buildings.R
  building_grow = 1,      # m, footprints grown by this before they are masked
  # lost trees, R/trees.R
  species       = "data/treespecies_2018.tif",  # tree species map, scripts/get_species.R
  tree_hmin     = 5,      # m, lowest tree top
  # Tree-top window: window_factor * S(h), S the stand spacing sqrt(10000 / N)
  # from yield tables (Schober collection, yield class I, moderate thinning),
  # fitted as S = A * h^B and held constant below window_hmin m. One window per
  # group of map species (codes, 0 = no species); unknown takes the mean of
  # spruce and broadleaf.
  window_factor = 2.0,
  window_hmin   = 16,     # m
  tree_groups   = list(
    spruce    = list(codes = c(5, 6, 12), A = 0.0798, B = 1.168),  # Wiedemann 1936/42
    pine      = list(codes = c(7, 11),    A = 0.0568, B = 1.371),  # Wiedemann 1943
    broadleaf = list(codes = c(1:4, 8:10), A = 0.0306, B = 1.510), # Schober 1967 (beech)
    unknown   = list(codes = 0)))

# A short fingerprint of a settings list, stored with each tile's result so
# process_tiles.R can tell which tiles were made with other settings.
params_id <- function(p) {
  substr(tools::sha256sum(bytes = charToRaw(paste(deparse(p), collapse = ""))), 1, 12)
}
