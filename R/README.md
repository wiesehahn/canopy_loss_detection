# R/

The building blocks for finding where forest disappeared in Lower Saxony. We compare tree-height maps from different years. Where the trees were tall and later are much lower, the canopy was lost. The scripts in `scripts/` use these functions, and so does the lidar-biodiversity-plots project.

| File | What it does |
|---|---|
| `epochs.R` | Picks the survey years to compare (from aerial laser scans or aerial photos) and lines their height maps up on one grid |
| `detection.R` | Compares each year with the one before it and finds the year the trees were lost |
| `tile_loss.R` | Runs that comparison for one 1 × 1 km map tile |
| `metrics.R` | Turns the result into areas: how much was surveyed, how much was forest, how much was lost |
| `render.R` | Draws the result as a map, coloured by the year of loss |
| `tiles.R` | Converts between a tile's ID number and its location |
