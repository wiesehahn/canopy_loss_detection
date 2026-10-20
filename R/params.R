# The detection settings, in one place, so the statewide tiles and the single
# tile images cannot drift apart. docs/findings.md says how each was chosen.

detection_params <- list(
  res_m         = 1,      # m, DOM1's native grid; bDOM is resampled onto it
  veg_months    = 5:10,   # vegetation period, bDOM only
  min_cover     = 0.05,   # smallest share of the tile an epoch must reach
  loss_drop     = -5,     # m, lasting drop in canopy height counted as loss
  regrowth      = 0.5,    # m per year a gap may regrow and still count as lost
  open_radius   = 1.5,    # m, morphological opening (3 x 3 cells), drops speckle
  min_gap       = 20,     # m², smallest loss patch kept
  buffer        = 50,     # m, read past the tile edge, see R/tile_loss.R
  canopy_height = 5,      # m, canopy vs. open when the record starts
  buildings     = "data/buildings.gpkg",  # ALKIS footprints, scripts/get_buildings.R
  building_grow = 1)      # m, footprints grown by this before they are masked
