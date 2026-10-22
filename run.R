# The whole workflow, from the project root:
#
#   source("run.R")
#
#   1. which LGLN surveys exist per tile  scripts/get_lgln_coverage.R
#      and maps of it                     scripts/map_coverage.R
#      the building footprints            scripts/get_buildings.R
#      and the tree species map           scripts/get_species.R
#   2. canopy loss per tile               scripts/process_tiles.R
#   3. mosaic and per-tile table          scripts/build_outputs.R
#
# Step 1 rebuilds the coverage and its maps when LGLN's tile indexes have
# changed since the last build (compared by ETag, a header request only), and
# fetches the buildings and the species map when they are missing; delete
# either to pick up a newer release. Step 2 resumes where it stopped and skips
# finished tiles; tiles already done are not redone for new flights. Step 3
# builds from whatever step 2 has written so far.
#
# Options, set before sourcing (see scripts/process_tiles.R):
#   options(cld.bbox = c(xmin, ymin, xmax, ymax))  only tiles in this box (EPSG:25832)
#   options(cld.tile_ids = c("326005741"))         only these tiles
#   options(cld.workers = 4)                       parallel workers, default half the cores

source("R/lgln_index.R")
if (lgln_coverage_outdated("data/lgln_coverage.gpkg", "data/lgln_coverage_source.csv")) {
  source("scripts/get_lgln_coverage.R")
  source("scripts/map_coverage.R")            # docs/images/coverage_*.png
}
if (!file.exists("data/buildings.gpkg"))     source("scripts/get_buildings.R")
if (!file.exists("data/treespecies_2018.tif")) source("scripts/get_species.R")
source("scripts/process_tiles.R")
source("scripts/build_outputs.R")
