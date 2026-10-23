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
# Every step does only what is new, so running this again is cheap and picks
# up what has changed:
#
#   1. The coverage and its maps are rebuilt when LGLN's tile indexes have
#      changed since the last build (compared by ETag, a header request only).
#      The buildings and the species map are fetched when they are missing;
#      delete either to pick up a newer release.
#   2. Tiles are processed that are not done yet, that have new LGLN flights
#      since they were done, or that were done with other settings
#      (R/params.R). The rest is skipped. A stopped run picks up where it was.
#   3. The mosaics and the table are rebuilt when step 2 has finished tiles
#      since the last build.
#
# Options, set before sourcing (see scripts/process_tiles.R):
#   options(cld.bbox = c(xmin, ymin, xmax, ymax))  only tiles in this box (EPSG:25832)
#   options(cld.tile_ids = c("326005741"))         only these tiles
#   options(cld.workers = 4)                       parallel workers, default half the cores
library(cli)

source("R/params.R")
source("R/lgln_index.R")

cli_h1("1 / 3  Inputs")
if (lgln_coverage_outdated("data/lgln_coverage.gpkg", "data/lgln_coverage_source.csv")) {
  source("scripts/get_lgln_coverage.R")
  source("scripts/map_coverage.R")            # docs/images/coverage_*.png
}
for (input in list(
       list(file = detection_params$buildings, script = "scripts/get_buildings.R",
            what = "Building footprints"),
       list(file = detection_params$species, script = "scripts/get_species.R",
            what = "Tree species map"))) {
  if (file.exists(input$file)) {
    cli_alert_success("{input$what} present: skipped (delete {.file {input$file}} to fetch a newer release)")
  } else {
    source(input$script)
  }
}

cli_h1("2 / 3  Canopy loss per tile")
source("scripts/process_tiles.R")

cli_h1("3 / 3  Mosaics and tile table")
source("scripts/build_outputs.R")
