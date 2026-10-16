# scripts/

The steps to run, roughly in this order. Lower Saxony is split into 1 × 1 km map tiles, and each is processed on its own. Run the scripts from the project folder.

| File | What it does |
|---|---|
| `get_lgln_coverage.R` | Lists the years with height data for each tile, so we know which tiles can be compared |
| `process_tiles.R` | Finds forest loss in every tile (the main run, which takes days) |
| `build_outputs.R` | Joins all the tiles into one map and one table |
| `image_tile.R` | Makes a picture of the forest loss in one tile |
