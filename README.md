# Canopy loss detection

Where the forest canopy disappeared in Lower Saxony, and when. It uses the
canopy surfaces LGLN publishes as open data: DOM1, measured by lidar, and
bDOM20, matched from aerial photographs. Both come as 1 × 1 km tiles, each
flown in several years. The code runs over every tile with at least two usable
years. The same functions are sourced by
[lidar-biodiversity-plots](../lidar-biodiversity-plots/) to measure loss over its
plot circles.

All geodata is EPSG:25832. Run everything from the project root with R ≥ 4.5,
`terra`, `sf` and [`rvtr`](https://github.com/wiesehahn/rvtr) (87afb2c or later,
for the `method` argument of `rvt_data_lgln()`).

## Method

LGLN surfaces are fetched with `rvtr::rvt_data_lgln()`. They are streamed, not
downloaded, and land on one 1 m grid. bDOM20 is taken as the highest of its
20 cm pixels in each 1 m cell, as the lidar DSM records the highest return.
Averaged, it sinks into the gaps between crowns and reads them as lost.

1. **Choosing the epochs** ([`R/epochs.R`](R/epochs.R)):
   - Every DOM1 year counts.
   - A bDOM20 year counts only if it was flown May–October. A bare broadleaf
     canopy gives the image matcher no texture, so it falls through to the
     forest floor and the whole stand would read as gone.
   - Each year gives one epoch. Where a year has both products, the one that
     reaches further across the grid is used, with lidar winning a tie.
   - A year that reaches only part of the grid is still used; it says nothing
     about the rest.
2. **Differencing** ([`R/detection.R`](R/detection.R)): consecutive epochs are
   differenced. Where an epoch has no data, the last known height is carried
   forward.
3. **What counts as a loss:**
   - The cell's surface drops by more than 5 m, as measured. The steps are not
     levelled against each other: levelling made no measurable difference
     against a later lidar survey, and it made a cell's result depend on the
     rest of the grid.
   - The drop is absolute, not a share of the stand's height, so a tree lost
     over a lower canopy layer still counts.
   - The drop has to last: the cell stays below its running floor in every
     later epoch. That separates a real cut from a bDOM that missed the canopy
     for one year.
4. **Cleaning.** An opening with a 1.5 m radius removes anything narrower than
   about 3 m, and patches under 20 m² are dropped. Each loss is dated to the
   epoch it first appears in.

**Statewide, per tile** ([`R/tile_loss.R`](R/tile_loss.R)):
- The epochs are chosen on the tile itself.
- The detection runs on the tile plus a 50 m buffer and is then cropped back.
  Without the buffer, the opening and the patch-size filter would cut patches
  at tile edges.
- The starting canopy is measured over LGLN DGM1, because there is no other
  terrain model statewide.

## Scripts

| script | does |
|---|---|
| [`scripts/get_lgln_coverage.R`](scripts/get_lgln_coverage.R) | Reads LGLN's tile indexes and writes `data/lgln_coverage.gpkg`: per tile, which years have DOM1 and bDOM20 data, and how many epochs that gives. It fetches no surfaces. |
| [`scripts/process_tiles.R`](scripts/process_tiles.R) | The statewide run over all tiles with `comparable = TRUE`. It runs in parallel and can be resumed, and `bbox` / `tile_ids` restrict it for pilots. |
| [`scripts/build_outputs.R`](scripts/build_outputs.R) | Builds the mosaic and the per-tile table from what `process_tiles.R` has written so far. |
| [`scripts/image_tile.R`](scripts/image_tile.R) | `Rscript scripts/image_tile.R 600445,5741390`: an image of one tile's losses, coloured by year, over a hillshade. |

## Outputs (`data/`, not in git)

| path | contents |
|---|---|
| `lgln_coverage.gpkg` | layer `tiles`: one polygon per tile with `dom1_years`, `bdom_years`, `bdom_veg_years`, `epoch_years`, `n_epochs`, `first_epoch`, `last_epoch`, `max_gap`, `comparable` (≥ 2 epochs), `lidar_only` (≥ 2 DOM1 years). Layer `flights`: one row per tile and flight, with its URL. |
| `tiles/<tile_id>.tif` | One per measured tile, 1 m. Three bands: `loss_year` (year the canopy went, NA where it never did), `observed` (1 where some epoch could be differenced), `canopy` (1 where the stand was above 5 m when the record starts). |
| `epochs/<tile_id>.csv` | The tile's epoch table: which LGLN years were used and why the others weren't. Its existence marks the tile as done. |
| `log/` | `runs.csv` with status and seconds per tile; `<tile_id>.txt` with the error of a failed tile. |
| `canopy_loss_year.vrt`, `canopy_loss_observed.vrt`, `canopy_loss_canopy.vrt` | All tiles as one mosaic: one single-band VRT per tile band, so the year opens on its own. |
| `canopy_loss_tiles.gpkg` | Layer `tiles`: the coverage columns, plus `observed_m2`, `forest_m2`, `loss_m2`, `loss_pct`, `loss_pct_forest`, `loss_<year>_m2` and `reason`. Layer `tile_epochs`: all epoch tables. |

`loss_year` is NA both where nothing was lost and where nothing was looked at.
Only `observed` tells those apart, and every share is taken against it.

## Worth knowing

- **Lidar-to-bDOM steps are less reliable than lidar-to-lidar ones.** The two
  put the canopy top up to a metre or two apart, and an early-May bDOM can fall
  through broadleaf crowns that are not yet in full leaf.
- **A bad last epoch can't be caught.** The "loss must last" rule works by
  contradiction from later epochs, and the last one has none.
- **Run time.** In the pilot each tile took about 30 s, about 4.3 s per tile
  with 8 workers, before bDOM was read at native resolution for the maximum.
  That made the detection about three times slower per tile in testing; the
  pilot is to be re-timed.
- LGLN open data: © GeoBasis-DE/LGLN, CC BY 4.0. Add ", Daten geändert" when
  publishing anything derived from it.
