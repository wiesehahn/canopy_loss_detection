# scripts/

The steps of the workflow. Lower Saxony is split into 1 × 1 km map tiles, and each is processed on its own. Normally [`run.R`](../run.R) runs steps 1–3 in order; each script can also be sourced on its own from the project folder.

| Step | File | What it does |
|---|---|---|
| 1 | `get_lgln_coverage.R` | Lists the years with height data for each tile, so we know which tiles can be compared |
| 1 | `get_buildings.R` | Downloads the building outlines, so buildings can be left out |
| 1 | `get_species.R` | Downloads the tree species map, so lost trees get a species |
| 2 | `process_tiles.R` | Finds forest loss and the lost trees in every tile (the main run, which takes days) |
| 3 | `build_outputs.R` | Joins all the tiles into one map and one table |
| – | `image_tile.R` | Makes a picture of the forest loss in one tile |
