# Canopy loss detection

**Where has the forest canopy in Lower Saxony disappeared, and when?**

This project maps canopy loss across the whole state of Lower Saxony at 1 m resolution, from about 2010 to today. It uses free elevation data from the state survey office (LGLN), which has flown the state several times.

- **DOM1:** surface models measured by airborne laser scanning (lidar).
- **bDOM20:** surface models matched from aerial photographs.

Each one records the height of whatever is on top, tree crowns in a forest. Comparing the surfaces of different years shows where trees stood and later were gone, for example after harvest, storm or bark beetle damage.

![Canopy loss in a 1 × 1 km tile in the Harz](docs/images/canopy_loss_326005741.webp)

*Canopy loss in one 1 × 1 km tile in the Harz near Clausthal (tile 326005741), over a hillshade of the forest in 2013. Magenta: lost between 2013 and 2018. Orange: lost between 2018 and 2022, mostly spruce dieback after the drought years.*

## How it works

1. **Collect the surveys.** For each 1 × 1 km tile, all available survey years are gathered. Photo-based surfaces are only used if they were flown in summer (May–October). Bare broadleaf crowns in winter cannot be matched and would look like lost forest.
2. **Compare the years.** Each survey is compared with the previous one, cell by cell.
3. **Decide what counts as loss.** A cell counts as lost when:
   - its height drops by more than 5 m, and
   - it stays down in all later surveys, allowing for some regrowth.

   A single survey that misreads the canopy is then contradicted by the next one and not counted.
4. **Clean up.** Specks narrower than 3 m and patches smaller than 20 m² are removed. Each loss is dated to the first survey that shows it.
5. **Leave out buildings.** Building footprints from the official cadastre (ALKIS) are removed, so every change counted is vegetation. Trees outside the forest, in gardens, along roads and in hedges, are kept.

The thresholds were chosen and checked against later lidar surveys that the detection never saw. [`docs/findings.md`](docs/findings.md) logs those tests and the reasons behind each setting.

## Results

| output | what it shows |
|---|---|
| Loss map | For every 1 m cell, the year of the first survey that shows the loss; empty where there was none |
| Earliest loss map | The year of the last survey before the loss, so each loss is dated to a period, not a single year |
| Coverage map | Where the data allowed a comparison at all (buildings excluded), so "no loss" can be told apart from "not observed" |
| Starting forest | Where there was canopy (above 5 m) when the record starts |
| Tile table | Per tile: forest area, lost area, loss per year, and which surveys were used |

A loss can only be dated to the time between two surveys: after the last flight that still saw the canopy, and by the first flight that shows it gone. A cell with an earliest year of 2018 and a loss year of 2022 lost its canopy at some point between those two flights.

The maps are mosaics over all tiles (`data/canopy_loss_year.vrt`, `data/canopy_loss_from.vrt`, `data/canopy_loss_observed.vrt`, `data/canopy_loss_canopy.vrt`). The table is `data/canopy_loss_tiles.gpkg`. [`docs/data.md`](docs/data.md) describes every file, band, column and value.

## Limitations

- **Mixed data sources:** lidar and photo-based surfaces do not measure the canopy identically. Comparisons that involve a photo-based survey are less reliable than lidar against lidar.
- **The latest survey is the least certain:** a loss can only be confirmed by a later survey, and the most recent one has none.
- **Coverage:** tiles with fewer than two usable surveys, or without an LGLN terrain model (mostly coast and border), are not processed.

## Project structure

| path | contents |
|---|---|
| [`run.R`](run.R) | Runs the whole workflow |
| [`R/`](R/) | The method as functions. The settings are in [`R/params.R`](R/params.R). |
| [`scripts/`](scripts/) | The individual steps that `run.R` calls, plus a single-tile image |
| [`docs/`](docs/) | What the outputs contain ([`data.md`](docs/data.md)), and how the method was tested ([`findings.md`](docs/findings.md)) |
| `data/` | All outputs (not in git) |

The functions in `R/` are also used by [lidar-biodiversity-plots](../lidar-biodiversity-plots/) to measure loss around its field plots.

## Running it

**Requirements:** R ≥ 4.5 with `terra`, `sf`, `viridisLite` and [`rvtr`](https://github.com/wiesehahn/rvtr) (87afb2c or later). Nothing needs to be downloaded in advance: the surveys are streamed from LGLN while processing.

**Run everything**, from the project root:

```r
source("run.R")
```

This runs three steps:

1. List which surveys exist for each tile, and download the building footprints (once, about 700 MB).
2. Detect loss in every tile, in parallel. This step takes days for the whole state. It can be stopped and restarted at any time, and finished tiles are skipped.
3. Build the maps and the tile table from the tiles finished so far.

**Try a small area first:**

```r
options(cld.bbox = c(598000, 5739000, 603000, 5744000))  # xmin, ymin, xmax, ymax
source("run.R")
```

`cld.tile_ids` selects single tiles instead, and `cld.workers` sets the number of parallel workers (default: half the CPU cores).

**Look at a single tile:**

```r
options(cld.coord = c(600445, 5741390))  # any point in the tile
source("scripts/image_tile.R")
```

This writes `data/images/canopy_loss_<tile_id>.webp`, like the image above.

All coordinates and outputs are in EPSG:25832 (ETRS89 / UTM 32N).

## Data licence

LGLN open data: © GeoBasis-DE/LGLN, CC BY 4.0. When publishing anything derived from it, add ", Daten geändert".
