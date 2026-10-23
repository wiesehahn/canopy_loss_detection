# Data description

Every file the workflow writes to `data/`, and what each value means. All geodata is in EPSG:25832 (ETRS89 / UTM zone 32N).

## Tiles and tile IDs

Lower Saxony is processed in the 1 × 1 km tiles of LGLN's elevation data. A tile ID such as `326005741` reads as:

- `32`: the UTM zone;
- `600`: the easting of the lower-left corner in km;
- `5741`: the northing of the lower-left corner in km.

So `326005741` covers 600000–601000 E, 5741000–5742000 N.

A **survey** (or epoch) is one year of LGLN surface data for a tile: lidar (DOM1) or photo-based (bDOM20). If a year has both, the one covering more of the tile is used.

## Loss rasters: `tiles/<tile_id>.tif`

One GeoTIFF per measured tile: 1000 × 1000 cells of 1 m, unsigned 32-bit integers (for the tree IDs), NoData value 4294967295 (shown as empty in GIS software). Band statistics are stored in the file.

| band | name | values | meaning |
|---|---|---|---|
| 1 | `loss_year` | year, e.g. `2022`; empty | The year of the first survey that shows the canopy gone: the latest year the loss can have happened. Empty where no loss was detected, and where nothing was observed (see `observed`). |
| 2 | `observed` | `1`, `0` | `1` where at least two surveys could be compared. `0` where they could not (no survey overlap), and under buildings. |
| 3 | `canopy` | `1`, `0` | `1` where something stood at least 5 m above the ground when the record starts: trees, inside or outside the forest. `0` elsewhere, including under buildings. |
| 4 | `loss_from` | year, e.g. `2018`; empty | The year of the last survey that still saw the canopy: the earliest year the loss can have happened. Empty exactly where `loss_year` is empty. |
| 5 | `species` | `0`–`12`; empty | On the crowns of lost trees, the tree's species (codes below). Empty elsewhere, including loss pixels that got no tree. |
| 6 | `crown` | tree ID; empty | On the crowns of lost trees, the tree's ID: one crown, one ID, unique across all tiles. |
| 7 | `tree_top` | height in dm; empty | On the top pixel of each lost tree only, its height above ground in decimetres (e.g. `257` = 25.7 m), from the lidar survey before the loss. |

**Species codes** (band 5), from the dominant tree species map of Germany 2018: `0` none (outside the map's forest, or disturbed before 2018), `1` alder, `2` ash, `3` beech, `4` birch, `5` Douglas fir, `6` fir, `7` larch, `8` maple, `9` oak, `10` other broadleaf, `11` pine, `12` spruce.

**Reading a cell:**

| `observed` | `loss_year` | `loss_from` | meaning |
|---|---|---|---|
| 1 | empty | empty | observed, no loss |
| 1 | 2022 | 2018 | canopy lost after the 2018 survey and by the 2022 survey |
| 0 | empty | empty | not observed (no comparison possible, or a building) |

**Notes:**

- **A loss is a period:** it happened between the flights in `loss_from` and `loss_year`. Both are survey years, so the interval can be several years long. Flight dates are in the epoch table.
- **What counts as loss:** a lasting drop of more than 5 m. A loss can also lie outside the starting `canopy`, at the very edge of a crown.
- **Buildings:** ALKIS building footprints, grown by 1 m, are removed from all bands.

## Mosaics: `canopy_loss_<band>.vrt`

`canopy_loss_year.vrt`, `canopy_loss_from.vrt`, `canopy_loss_observed.vrt`, `canopy_loss_canopy.vrt`, `canopy_loss_species.vrt`, `canopy_loss_crown.vrt` and `canopy_loss_tree_top.vrt` join one band of all tile rasters into a single statewide layer. The values are as above. They are small text files that point to the tiles, so they need `tiles/` next to them.

## Lost trees (bands 5–7)

The lost trees are stored in the tile rasters, not as a separate file. A tree is one `tree_top` pixel: its position, its height, and the same pixel's `crown` (ID), `species`, `loss_from` and `loss_year`. Its crown is every pixel with the same `crown` value. Trees are found only on loss pixels, in the last lidar survey before the loss; losses with no lidar survey before them get no trees.

**Tree ID:** `(tile number × 32768) + tree number`. The tile number is the tile's place in LGLN's tile grid, `(easting km − 340) × 299 + (northing km − 5682)`, and the tree number counts 1, 2, … within the tile. So:
- IDs are unique across all tiles and depend only on the grid, not on processing order;
- the tile can be read back from any ID: tile number = `ID %/% 32768` (`tree_tile()` in `R/trees.R`).

**As a table:** `trees_from_tiles(files)` in `R/trees.R` returns one row per tree (`id`, `x`, `y`, `height` in m, `species`, `loss_from`, `loss_year`) for any set of tiles. From there it can be written as points, for example with `sf::st_as_sf(..., coords = c("x", "y"), crs = 25832)`.

**Reading in R:** terra reads unsigned 32-bit bands as R integers, which stop at 2,147,483,647, so it shows the tree IDs as empty. The other bands are fine in terra. Read the IDs with gdalraster (as `trees_from_tiles()` does), stars or GDAL directly. QGIS and Python read them correctly.

## Tile table: `canopy_loss_tiles.gpkg`

### Layer `tiles`

One polygon per LGLN tile, for all of Lower Saxony.

| column | meaning |
|---|---|
| `tile_id` | Tile ID, see above |
| `dom1_years`, `dom1_n` | Lidar (DOM1) survey years in LGLN's index, e.g. `"2013,2018"`, and their number |
| `bdom_years`, `bdom_n` | Photo-based (bDOM20) survey years, and their number |
| `bdom_veg_years`, `bdom_veg_n` | The bDOM20 years flown in May–October, the only ones used |
| `epoch_years`, `n_epochs` | All usable survey years (DOM1 and summer bDOM20, one per year), and their number |
| `epoch_dates` | The flight dates behind `epoch_years`. A tile is processed again when these change. |
| `first_epoch`, `last_epoch` | First and last usable survey year |
| `span_years` | `last_epoch − first_epoch` |
| `max_gap` | Longest gap between two consecutive surveys, in years |
| `dgm1` | `TRUE` if LGLN has a terrain model (DGM1) for the tile |
| `comparable` | `TRUE` if the tile can be processed: at least two surveys and a DGM1 |
| `lidar_only` | `TRUE` if the tile has at least two lidar years |
| `status` | `measured`, `skipped` (processed, but nothing to compare, see `reason`), or empty if not processed |
| `params`, `processed` | The settings the tile was made with (see `params/` below) and when |
| `first_year`, `last_year`, `n_used` | First and last survey year actually used for this tile, and their number. Can differ from the columns above, because a survey covering less than 5 % of the tile is dropped. |
| `observed_m2` | Area where surveys could be compared (`observed` = 1) |
| `observed_pct` | `observed_m2` as % of the tile |
| `forest_m2` | Starting canopy within the observed area (`canopy` = 1). Named forest, but it includes trees outside the forest. |
| `loss_m2` | Lost area within the observed area |
| `loss_pct` | `loss_m2` as % of `observed_m2` |
| `loss_forest_m2` | Lost area within the starting canopy |
| `loss_pct_forest` | `loss_forest_m2` as % of `forest_m2`: the share of the canopy lost |
| `lost_trees` | Number of lost trees found in the tile (`tree_top` pixels) |
| `loss_<year>_m2` | Lost area per year of detection (`loss_year`), one column for every year with loss in some tile. They add up to `loss_m2`. |
| `reason` | Empty for measured tiles; otherwise why there are no values: `fewer than two epochs in the tile index`, `no DGM1 terrain model`, `not processed yet`, `only epoch, nothing to compare`, `no epoch overlaps another`, or `failed:` and the error |

All areas are in m², rounded to 0.1. They are empty (NA) for tiles that were not measured.

### Layer `tile_epochs`

A copy of `epochs.csv` (below).

## Epoch table: `epochs.csv`

One row per processed tile, survey year and product that LGLN holds. It shows which surveys were used for each tile, and why the others were not.

| column | meaning |
|---|---|
| `tile_id` | Tile ID |
| `product` | `dsm` (lidar, DOM1) or `bdom` (photo-based, bDOM20) |
| `year` | Survey year |
| `first_date`, `last_date` | Earliest and latest flight date of that year's data over the tile (`YYYY-MM-DD`) |
| `tiles` | How many LGLN data tiles that year contributes |
| `coverage` | Share of the tile that year covers, 0–1 |
| `covers` | `TRUE` if `coverage` is 1 |
| `used` | `TRUE` if the survey went into the detection |
| `reason` | Why not, if not used: `outside vegetation period`, `coverage too small`, `other product reaches further in the same year`, or a reason the whole tile was skipped |

## Result table: `tile_results.csv`

One row per processed tile, written by step 2 right after the tile, and the source of the tile table above. A tile with a row here is done. The next run skips it, unless its `epoch_dates` in the coverage or the settings have changed since; then its rows here and in `epochs.csv` are replaced.

The columns are those of the tile table from `status` to `lost_trees`, plus:

| column | meaning |
|---|---|
| `epoch_dates` | The coverage's `epoch_dates` when the tile was processed |
| `loss_by_year` | Lost area per year as text, e.g. `2018:135171;2022:331473` (year:m²); the tile table spreads it into the `loss_<year>_m2` columns |

## Coverage: `lgln_coverage.gpkg`

Written by step 1, before any tile is processed.

- **Layer `tiles`:** the same coverage columns as in the tile table, from `tile_id` to `lidar_only`.
- **Layer `flights`:** one row per tile and flight in LGLN's index, with:
  - `product` (`dom1` or `bdom`);
  - `file` (e.g. `bdom20`; since 2024 some flights are also listed as `bdom10`);
  - `date` and `year`;
  - `url` of the data file;
  - `latest_in_year`: `TRUE` for the flight that is used when a year has several.

## Other files

| path | contents |
|---|---|
| `buildings.gpkg` | ALKIS building footprints for Lower Saxony (layer `buildings`), used to mask buildings |
| `treespecies_2018.tif` | Dominant tree species map of Germany 2018 (10 m, EPSG:3035), used for the lost trees |
| `lgln_coverage_source.csv` | The ETags (content checksums) of LGLN's tile indexes the coverage was built from. When LGLN serves other ones, step 1 rebuilds the coverage. |
| `params/<params>.txt` | Each set of settings tiles were made with, under the fingerprint in the `params` column |
| `runs.csv` | One row per attempt at a tile: `tile_id`, `status` (`measured`, `skipped` or `failed`), `seconds`, `error` (the message of a failed tile, which is retried on the next run) and `finished` |
| `images/canopy_loss_<tile_id>.webp` | Images from `scripts/image_tile.R` |

The maps of data availability are in the repository, not in `data/`: `docs/images/coverage_epochs.png` (usable surveys per tile), `coverage_lidar.png` (lidar surveys per tile) and `coverage_latest.png` (year of the latest usable survey). They are redrawn with the coverage.
