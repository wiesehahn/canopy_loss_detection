# Findings

Method decisions and the tests behind them, newest first. The test code is not part of the repo. Each entry says how the test was set up, so it can be repeated.

## How the method is validated

The canopy surface from a later lidar survey serves as a reference. Lidar measures the canopy top the same way every time, so the difference between the first and the latest DOM1 of a tile is the most trustworthy change on record. It is a reference, not ground truth.

- **Setup:** the detection runs only on the epochs before the latest DOM1, so the reference survey takes no part in it.
- **Classes:** every cell detected as lost is looked up in the lidar difference:
  - **confirmed:** lidar more than 5 m lower;
  - **uncertain:** 2–5 m lower;
  - **contradicted:** less than 2 m lower, or higher.
- **Recall:** the other way round, *clear removals* in the lidar are checked for whether the detection found them. A clear removal stood above 10 m and is now more than 10 m lower.
- **Limits:**
  - Changes between the last bDOM and the reference survey cannot have been detected, so "found" is a lower bound.
  - The reference lidar flights are mostly in March (leaf-off). In broadleaf stands they can read the canopy lower, which would count some false detections as confirmed.

## 2026-11-10 – The no-tree rules for the starting canopy

**Question:** the rules of 2026-11-09 (reference over 65 m above DGM1; lidar flat on a lake) remove such cells from the loss, but the starting canopy is still the first surface 5 m or more above DGM1. Does it still count turbines and lakes under old lidar surfaces as canopy, how much, and does applying the same rules there change anything else?

**Setup:**
- `tile_loss()` returns `no_canopy`, and `process_tiles.R` sets `canopy` to 0 there:
  - the first surface stands more than `max_height` above DGM1; or
  - the cell is a lake (`data/lakes.gpkg`) and a lidar survey lies within `lake_flat` of DGM1 there.
- Heights are read from the surfaces directly. Where a lidar survey has a value, this is the height `loss_year()` tests.
- 13 tiles, through the real `process_tiles.R`, method 4:
  - the 6 water tiles of the 2026-11-09 comparison;
  - 5 tiles with H1 patches;
  - 2 controls: pilot tile 326005741, no lake; 324405817, which has a lake but no lidar over it at canopy height.

**Results:**

| tiles | starting canopy before | removed: over 65 m | removed: lake | share removed |
|---|---|---|---|---|
| 6 water tiles | 195.1 ha | 0 | 4.39 ha | 0–4.8 % per tile, 2.3 % over all |
| 5 H1 tiles | 165.0 ha | 819 m² | 33 m² | 0.03–0.11 % (0.8 % on a tile with 0.8 ha of canopy) |
| 2 controls | 110.2 ha | 0 | 0 | 0 |

- None of the removed cells carries a loss: the loss rules had already taken them out of the loss. Canopy and loss now agree, so `loss_pct_forest` is no longer understated on such tiles.
- On the H1 tiles the written `canopy` band equals the old starting canopy minus exactly the removed cells.
- Lake cells under a flat lidar survey without false canopy (324405817: 0.25 ha) change nothing.

**Decision:** applied as part of method 4. No tile had been made with method 4 yet, so no extra rerun.

## 2026-11-10 – DGM1 from a local copy

**Question:** with DGM1 downloaded once for the terrain test (`data/dgm1`), can `tile_loss()` read it from disk instead of streaming it, with identical results?

**Setup:** `tile_dtm()` (R/tiles.R) builds the same VRT as rvtr at 1 m, over the local files, and streams any tile missing from the copy from the URL in its index. Compared with streaming:
- the DGM1 on the 50 m buffered grid of 30 tiles: 12 random, 10 at the edge of DGM1 coverage, and 8 where the newest file year is not the newest date (101 such tiles; rvtr takes the file year);
- one grid with the centre tile missing from the copy;
- all 7 bands of the 25 pilot tiles, through the whole `tile_loss()`, starting canopy and lost trees.

6 workers, this PC.

**Results:**
- **DGM1:** identical on all 30 grids, including the NA cells outside coverage (up to 828,329 of 1.21 M).
- **Missing tile:** 1 source streamed, 8 local, identical.
- **Pilot:** 0 cells differ in any band, in any of the 25 tiles.
- **Time for the DGM1 read:** 1.0 s local against 2.6 s streamed (mean of 30). The whole-tile times (33.4 against 30.0 s) are no measure: each tile ran local first, so the streamed run read the same DOM/bDOM from GDAL's cache.
- `scripts/get_dgm1.R` run on the existing copy: nothing to fetch, index unchanged. Its download function got 3 tiles byte-identical to the copy and rejected a missing URL.

**Decision:** read the local copy when `data/dgm1/index.csv` is there (`cld.dgm_dir`, `""` to stream). It saves about 1.6 s per tile here and takes the DGM1 load off LGLN's servers. On the Threadripper the copy is on a network share, so its read speed there shows in the pilot. The copy must be kept current with `get_dgm1.R`; `run.R` does not check it.

## 2026-11-09 – Read speed and behaviour on interruptions

**Question:** before the statewide run: which parts cost the most, can they be sped up, and does the run survive interruptions?

**Setup:** 20 sample tiles one at a time, each step timed. Read settings on whole `tile_loss()` runs, 24 tiles, 6 workers, 2 rounds. Interruptions on 12 tiles with the real `process_tiles.R` and `build_outputs.R` in a scratch copy, compared with an uninterrupted run.

**Results:**
- **Time per tile (35 s):** reading bDOM 44 % (12 s per survey), finding and opening remote files 17 %, DGM1 9 %, lost trees 8 %, `loss_year()` 4 %. Local computation is not worth optimising.
- **Read settings** (identical results, no failures): no folder listing and 2 decode threads, −20 % at 6 workers. 4 threads do no better. A 15 m buffer saves 5 % of a read and was not pursued.
- **Interruptions:**

  | test | result |
  |---|---|
  | normal run, then run again | correct, no temp files left; nothing redone |
  | session killed, resumed | identical to an uninterrupted run |
  | worker killed | restarts by itself, identical |
  | results file locked 45 s | correct, but one tile's rows twice in `epochs.csv` |
  | half a result row and half a raster | not handled before: tile counted as done, mosaic on a broken raster |

**Decision:** read settings and a 300 s request limit set in `process_tiles.R`. Rasters are written under another name and renamed when complete; half a last line is cut from the tables at startup; a table that cannot be replaced stops the run; duplicate epoch rows are dropped in the outputs. The settings still need a short pilot on the statewide machine, at 8 and 16 workers: there LGLN's servers set the limit.

## 2026-11-09 – Terrain metrics and canopy loss

**Question:** does canopy loss depend on terrain (slope, exposure, solar radiation in the growing season, landform)? Which metrics are worth computing statewide, at which resolution, and what do they cost?

**Setup:**
- **DGM1 kept locally:** `data/dgm1/<tile_id>.tif`, 49,708 tiles, 186.7 GB, about 2 h at 24 MB/s; `index.csv` holds each tile's file and date. 21 tiles compared with `rvt_data_lgln()` are identical cell by cell.
  - The DGM1 index has 71,177 rows. **rvtr follows the newest file year, not the newest `Aktualitaet`.** They differ for 101 tiles: a `_2022` file can carry an older date than a `_2020` one. Taking the newest date gave differences of up to 3.5 m.
  - 370 tiles have two `_2022` files, a tidal-area release beside the normal one. Identical on 6 of 6 tiles tested.
- **Blocks, about 10 × 10 km:** Harz around the pilot (97 tiles, 91 % spruce), Solling at E 530 / N 5730 (97, half spruce), Süntel at E 530 / N 5780 (100, mostly broadleaf), and the most forested lowland square at E 348 / N 5814 (100). The hill blocks were run through `tile_loss()` with `method` = 4 into a scratch folder; the lowland tiles are the older ones in `data/tiles`. The Hils (E 550 / N 5750) was dropped: it has no comparable tiles. The blocks show what matters and were not sampled at random, so they are no statewide figures.
- **Metrics:** 10 m DGM averaged from 1 m, 25 layers from 21 runs. Each tile uses its own 3 × 3 km mosaic, reach 1 km, centre kept. Radiation is clear-sky insolation for May–October, also as a ratio to a horizontal surface (`insol_rel`). It describes the site, not the weather of a year.
- **Loss:** on 10 m cells, m² of loss within m² of observed starting canopy (2.75 million cells, 20,400 ha of canopy, 3,880 ha of loss). It includes harvest; the data do not separate it from storm or bark beetle.
- **Statistics:** loss share per class with 95 % intervals by bootstrap over tiles. Added value of a metric: extra deviance explained by a smooth of it in a `mgcv::bam` on top of species, elevation and a tile effect, on 300,000 cells. Comparing within tiles takes out survey dates and region.

**Checks passed:** the 10 m sums equal `loss_forest_m2` and `forest_m2` of the tile table exactly. `insol_rel` is 1.06 on south slopes and 0.81 on north slopes above 10°, and 1.00 on flat ground.

**Results:**

| block | canopy (ha) | lost | median slope |
|---|---|---|---|
| Harz | 6,194 | 30.1 % | 9.2° |
| Solling | 6,659 | 18.6 % | 4.2° |
| Süntel | 4,641 | 13.5 % | 7.0° |
| lowland | 2,901 | 5.3 % | 1.6° |

- **Terrain adds little.** Species, elevation and tile explain 15–36 % of the deviance. On top of that, elevation adds 1.8 points in the Harz (without it in the base) and any other metric at most 1.4 points in a block (0.03–0.47 pooled). The ranking differs by block:

  | metric | pooled | Harz | Solling | Süntel | lowland |
  |---|---|---|---|---|---|
  | elevation | 0.55 | 1.78 | 0.38 | 0.26 | 0.29 |
  | sky view factor | 0.47 | 0.43 | 0.04 | 1.44 | 0.15 |
  | slope | 0.37 | 0.30 | 0.05 | 1.39 | 0.13 |
  | deviation, 500 m | 0.25 | 0.59 | 0.07 | 0.74 | 0.16 |
  | beam insolation | 0.20 | 0.24 | 0.17 | 0.80 | 0.07 |
  | geomorphons, 300 m | 0.16 | 0.40 | 0.17 | 0.25 | 0.06 |
  | `insol_rel` | 0.16 | 0.21 | 0.16 | 0.77 | 0.06 |
  | aspect (north + east) | 0.16 | 0.80 | 0.05 | 0.13 | 0.05 |
  | mean curvature | 0.04 | 0.03 | 0.64 | 0.26 | 0.04 |
  | wetness index | 0.05 | 0.02 | 0.42 | 0.19 | 0.06 |

- **Steep slopes:** no more loss, rather less. Süntel, all species: 16.0 % (13.8–18.2) at 5–10°, 5.3 % (3.8–7.1) at 20–30°. Harz spruce: 33.9 % (26.0–41.3) at 2–5°, 23.7 % (17.8–30.4) at 20–30°, intervals overlapping. Solling spruce shows no trend (28–35 %), so the Solling fall from 24 % to 12 % over all species is species mix. Harvest access could explain the decline; untested.
- **Southern slopes:** no consistent effect, and not more loss in the south. Harz spruce above 5°: north 35.0 % (28.7–42.1), south 19.6 % (12.9–27.2). Solling spruce: flat, 27–31 %. Süntel spruce (560 ha): erratic, highest in the west and south-west. Broadleaf: flat, 8–11 %.
- **Radiation:** no monotonic relation. Loss is highest around `insol_rel` 0.9–1.03 and lower at both ends (Harz 25 % below 0.8, 37 % at 0.9–0.97, 21 % at 1.03–1.1). Both ends are steep ground, so this mostly repeats the slope result.
- **Landform:** more loss on upper positions in the Harz and Süntel. Spruce over the hill blocks: peak 38.8 %, ridge 33.4 %, hollow 24.6 %, valley 23.8 %. Broadleaf: ridge 12.4 %, hollow 9.0 %. Not in the Solling. Wind exposure would fit, but was not tested.
- **Redundancy (slopes above 10°, Spearman):** global, beam and relative insolation 0.99–1.00; sky view, positive openness, sky illumination and diffuse insolation 0.91–0.98; TPI and deviation 0.98 at both radii; slope × aspect index with insolation 0.90–0.92.
- **Lidar against bDOM:** only the Harz has both (472 and 1,392 ha), so the check is weak. Both show the same north-over-south pattern (north 1.23 and 1.23, south 0.77 and 0.69 of the mean) and less loss above 20° (0.83 and 0.78); SE and W differ (1.00 and 0.62, 0.70 and 1.06). No sign that the patterns come from bDOM, but lidar and bDOM cover different years. Solling is lidar only, Süntel and the lowland bDOM only, so differences between blocks are confounded with the source.

**Rolling window:** against one contiguous run of the Harz block (869,301 cells), slope, TPI, sky view and geomorphons are identical. Insolation differs by at most 5.6 kWh/m² (mean 0.3), presumably because each tile uses its own latitude.

**Resolution (Harz):** slope at 25 m and 1 m averaged to 10 m rank close to 10 m slope (Spearman 0.96 and 0.94), but only 80.5 % of geomorphon cells keep their class at 25 m. Added deviance for slope: 10 m 0.31, 25 m 0.24. On 30 tiles, 1 m slope averaged gives 0.35 against 0.18 at 10 m; it costs 4.3 s per tile and may reflect micro-relief.

**Cheaper insolation** (30 hill tiles against every 5th day, 30 min, 36 directions):

| days / minutes / directions | s per tile | RMSE | mean bias |
|---|---|---|---|
| 5 / 30 / 36 (reference) | 7.3 | | |
| 5 / 60 / 16 | 3.5 | 0.40 % | −0.03 % |
| 10 / 60 / 16 | 2.2 | 0.93 % | −0.82 % |
| 15 / 60 / 16 | 1.8 | 1.68 % | −1.59 % |

**Cost, measured** (1 thread per tile, 8 workers, development machine; statewide figures assume 41,473 tiles and 16 workers, untested at that scale):

| set | s per tile | statewide |
|---|---|---|
| all 21 metric runs | 22.5 | about 16 h |
| shortlist below | 6.6 | about 4.7 h |
| shortlist without insolation | 2.9 | about 2.1 h |
| 10 m DGM, all 49,708 tiles, once | 0.4 | about 20 min |

Slope, aspect, TPI, deviation and curvature take 0.15 s each; geomorphons 0.4 / 1.0 / 3.1 s at 100 / 300 / 1000 m; sky view 0.8 s; turning a tile's loss into cells 0.7 s.

**Recommendation (not decided):** compute at 10 m from the local DGM, rolling window: elevation, slope, aspect (with a slope × aspect index), geomorphons at 300 m, TPI at 500 m, sky view factor, and `insol_rel` with 5 / 60 / 16. Leave out the other insolation components, daylight, openness, sky illumination, deviation, dominance, geomorphons at 1000 m. Curvature and the wetness index only helped in the Solling; the wetness index would need a real catchment, not a window. No code was added; the test scripts are not part of the repo.

## 2026-11-09 – What further filters would remove

**Question:** the loss is cleaned by width, a 20 m² minimum and a building mask. Which other errors occur, how much of the loss are they, would a filter remove real tree loss, and what would it cost?

**Setup:**
- The 500 sample tiles of 2026-10-23, through the real `tile_loss()` with `method` = 3 and rvtr 55a3b00: 1,691 ha of loss in 136,838 patches (connected cells of one loss year). All 500 tiles measured; a rebuilt reference reproduced `loss_year()` on every tile. Two of the 5 tiles using bDOM 2025 have no loss; their surfaces are at normal heights.
- A patch counts as hit when at least half of its cells are affected. Statewide shares are weighted by stratum, 95 % intervals by bootstrap over tiles.
- Land use from ALKIS Landnutzung 2026, the current state only.
- Visual check on 152 patches, per filter the 10 largest and 20 random, shown as surface before, surface after, change and current orthophoto. Rated tree loss, not tree loss, or unclear. Rated by Claude; the sheets are for checking.
- Test only, no filter was added.

**Results:**

| filter | hit when | share of statewide loss (95 %) | rated: not tree / tree / unclear | what it is |
|---|---|---|---|---|
| H1 too tall | reference over 65 m above DGM1 | under 0.01 % (0.05 ha in the sample) | 11 / 0 / 0 | wind turbine rotors and pylons, all of them |
| H2 below ground | surface after the loss more than 2 m below DGM1 | 0.35 % (0.07–0.76) | 23 / 3 / 4; by area 95 % not tree | quarries and sand piles; holes in a bDOM over a field |
| W water | on ALKIS water areas | 0.36 % (0.26–0.50) | 0 / 28 / 2 | trees along ditches, streams and ponds |
| L other land use | on `ln_abbau`, `ln_lagerung`, `ln_versorgungundentsorgung`, `ln_flugverkehr` | 0.63 % (0.37–0.98) | 6 / 17 / 2; by area 69 % not tree | quarries, but also trees around plants and depots |

| rated, L by class | not tree | tree | unclear |
|---|---|---|---|
| `ln_abbau` (quarries; 0.43 % of sample loss) | 6 patches, 2.66 ha | 5, 0.55 ha | 0 |
| `ln_versorgungundentsorgung` | 0 | 11, 0.66 ha | 1 |
| `ln_lagerung` | 0 | 1 | 1 |

- **Water:** the ALKIS layers tested are not the water bodies. They are mostly ditches and small ponds, where the patches are real trees. Lakes and large rivers lie in `ln_ohnenutzung`, which has no class attribute: the Steinhuder Meer is one 27.8 km² polygon there. A mask from these layers would remove real tree loss. The real error is lidar interpolating a surface over open water (2 patches rated unclear, 44 % of the rated water area, mixed with real trees).
- **Basis-DLM, tested afterwards** (same patches, at least half their cells on the polygon; 30 patches rated per class, 10 largest and 20 random; area shares weight the random ones for the rest of the class):

  | class | share of statewide loss (95 %) | rated: not tree / tree / unclear | not tree, by area |
  |---|---|---|---|
  | standing water (`gew01_f`, `AX_StehendesGewaesser`) | 0.47 % (0.16–0.88) | 13 / 14 / 3 | 70 % |
  | flowing water (`AX_Fliessgewaesser`) | 0.07 % (0.03–0.12) | 11 / 14 / 5 | 34 % |
  | quarries (`sie02_f`, `AX_TagebauGrubeSteinbruch`) | 0.35 % (0.11–0.66) | 16 / 13 / 1 | 79 % |
  | spoil heaps (`AX_Halde`) | none | – | – |

  - Only 37 of the 395 water patches are among the 474 ALKIS W patches.
  - **Water errors have a clear signature:** an old lidar surface runs smoothly over open water from the tree tops on the shore, and a later lidar survey lies flat on the DGM1. The rated patches split almost cleanly on it: where the loss survey is lidar and the median surface after the loss is within 0.3 m of DGM1, 23 not tree, 2 tree, 5 unclear. In all other rated water patches, 1 not tree, 26 tree, 3 unclear.
  - That rule hits 120 patches, 5.83 ha, 0.37 % of statewide loss, all but one between an old lidar survey (2013, 2015, 2017) and a later one. Two tiles hold 75 % of the area, so the share is uncertain. Without the rule, a water mask also removes the real shore trees: most water patches up to 200 m² are trees.
  - **The rule tested per cell, before the clean-up** (detection rerun on the 120 sample tiles with loss on water, the only ones it can change; without the rule the result is identical):
    - Removes 5.64 ha, 0.36 % of statewide loss (95 %: 0.08–0.75), in 38 tiles. 98 % of the removed cells are on water; the 0.10 ha elsewhere are fragments dropped by the clean-up. Two tiles hold 73 % of it.
    - Rated not-tree patches: 97 % of their area removed; 24 of 24 lose at least half. Rated tree patches: 26 of 28 untouched, 3.6 % of their area removed.
    - Mixed patches keep their land part: DS 2 loses 56 %, DS 4 62 %.
    - The tolerance hardly matters: 0.2, 0.3 and 0.5 m remove 5.62, 5.64 and 5.66 ha.
    - Cost: 0.17 s per tile (0.5 % of `tile_loss()`), with DGM1 shared.
  - **Quarries:** 9 of the 16 not-tree patches are also caught by H2, and only 1 of the 13 tree patches. The tree patches are forest cleared at quarry edges, which is real loss, and no simple rule separates them. The quarry errors H2 misses are about 4 ha, 0.2 % of the loss.
  - **Cost:** the classes fit a 26 MB GeoPackage; reading and rasterizing take about 0.015 s per tile. The Basis-DLM is one 546 MB download.
- **Below ground:** reference under 5 m above DGM1 applies to 75 of its 85 patches. One field tile (324415853, bDOM 2023) holds 21 of them with 0.8 ha, a surface that falls up to 18 m below ground. Such holes are a bDOM error of a last survey, which later surveys could not contradict.
- **Height profile:** only 0.4 ha of loss has a reference above 40 m, and 0.1 ha above 45 m. A lower limit could remove little more; patches between 40 and 65 m were not rated.
- **Lidar check:** 99.1 % of 625 ha checkable is confirmed. W (99.6 %) and L (98.5 %) are like the rest, and H1 and H2 have almost nothing checkable. It proves a height drop, not a tree: quarries confirm too.
- **Last survey (flag, no filter):** 71 % of the loss is dated to a tile's last survey, as most loss is recent. Lidar confirms 99.3 % where it can check.
- **Other errors:** in the 30 largest patches with contradicted cells all are real clearings, as that selection favours large patches, so it could not find rare errors. Of the 26 largest patches in tiles with little forest, 25 are trees and one is a demolished building that has left the 2026 footprints.

**Cost**, on top of `tile_loss()` at 29.9 s per tile (mean; median 26.9), 6 workers on the test machine:

| | seconds per tile | statewide on 2.3 days |
|---|---|---|
| height check (H1 and H2) | 0.21 | +0.4 h |
| reading DGM1, if not shared with the read for canopy and trees | 3.14 | +5.8 h |
| water mask | 0.06 | +0.1 h |
| land-use mask | 0.08 | +0.1 h |

- **Code for H1 and H2:** `tile_loss()` needs DGM1, and `loss_year()` must expose the reference; two settings; `lidar-biodiversity-plots` would have to follow.
- **Code for a quarry mask:** a script to cut `ln_abbau` out of ALKIS, about 3,500 polygons, and a second call in the form of `built_up()`.
- Reading ALKIS needs the 3.2 GB file only once, for that cut.

**Decision:** implemented as `method` = 4, per cell and before the clean-up:
- A drop does not count where the reference is more than 65 m above DGM1, where the surface after it is more than 2 m below DGM1, or on Basis-DLM standing water (`data/lakes.gpkg`) where the survey showing it is lidar and its surface lies within 0.3 m of DGM1.
- `sieve()` replaced by `drop_small()`, which removes small losses and leaves holes alone.
- **Not implemented:** rivers and canals (the map comparison left doubt in towns, 0.07 % of the loss), a quarry mask (it would also remove forest cleared at quarry edges), the ALKIS masks.

**Check of the implementation:** the 500 sample tiles through the new `tile_loss()`, against the results before; each change also alone. No errors, and no loss added anywhere.

| change | sample | share of statewide loss (95 %) |
|---|---|---|
| holes no longer filled | 14.10 ha | 0.76 % (0.65–0.86) |
| below ground | 5.25 ha | 0.38 % (0.10–0.79) |
| lakes | 5.38 ha | 0.33 % (0.06–0.73) |
| over 65 m | 0.06 ha | 0.005 % (0.001–0.010) |
| **all** | 24.78 ha, from 1,690.9 to 1,666.1 ha | **1.47 %** (1.06–2.00) |

- **Rated patches:** all 11 H1 patches are removed entirely. Standing water behaves as tested (12 of 14 tree patches untouched, all 13 not-tree patches lose at least half). The patches in `contra` and `lowforest` keep everything but holes; flowing water changes almost nothing.
- **Cost:** `loss_year()` takes 2.2 s instead of 1.1 s per tile, the lakes 0.05 s, against about 35 s for `tile_loss()` (8 tiles, one at a time): about +3 %, or 2 h on the statewide run. DGM1 is read once, where it was read later anyway.

## 2026-11-05 – Lidar resets the loss reference

**Question:** a loss was measured against the lowest height a cell ever had. Canopy that grew up and was then cut was missed: grown from 2 m to 14 m and cut back to 2 m is no drop below 2 m. How should the reference follow growth without letting bDOM errors in?

**Setup:** 243 sample tiles with 3+ epochs (sample of 2026-10-23), bDOM 2025 left out (2026-10-29). Each rule against the current one, on the same surfaces. Loss cells checked against lidar where lidar exists before and after the loss: confirmed if the lowest lidar from the loss on is more than 5 m below the highest lidar before.

| reference | loss added | of it, checkable by lidar: confirmed | 2–5 m | contradicted |
|---|---|---|---|---|
| lowest so far (current) | – | 99.0 % (of the current loss) | 0.6 % | 0.4 % |
| last height, bDOM checked for implausible growth (tolerance 1–5 m) | +19 to +20 % | reference from lidar: 97 %; from bDOM: 54 % | 31 % | 15 % (bDOM) |
| **lidar resets it, bDOM can only lower it** | **+8.5 %** (+4.3 % statewide) | 99.4 % (only 0.1 ha checkable) | 0.6 % | 0 % |

- **Last height with a growth check:** the check barely matters at any tolerance; it rejects only 3–8 % of bDOM cells. bDOM is not wrong by impossible jumps but reads the canopy 1–3 m too high, which passes any realistic growth check. Used as a reference, that pushes drops of 3–4 m over the 5 m threshold.
- **Lidar reset:** adds loss only where a lidar survey lies between the start and the loss (e.g. lidar 2013, lidar 2018/2020, bDOM 2022), and never removes any. The additions mostly have no lidar after them yet, so they can rarely be checked. They are the same kind of loss as the current rule's (a bDOM drop below a lidar height), which lidar confirms at 99 %, and bDOM reading high makes their drops if anything larger.
- **Not covered:** growth seen only by bDOM (bDOM 10 → bDOM 20 → bDOM 12) is still missed. The test above shows such bDOM-based references are unreliable.
- **Plots repo:** 8 local plots with 3+ epochs: unchanged without a lidar survey in between, +100 to +2,300 m² with one.

**Decision:** adopted. `loss_year()` takes `lidar` (which epochs are DOM1). A lidar epoch resets the reference to what it measured, a bDOM epoch can only lower it. `method` = 2 in `R/params.R`, so all finished tiles are redone. Both calls in lidar-biodiversity-plots pass `lidar`.

## 2026-11-05 – The bDOM 2025 offset comes from rvtr, not from LGLN

**Question:** what to report to LGLN about the 40 m offset of the 2025 bDOM (2026-10-29)?

**Setup:**
- 168 raw bDOM files, 3 per flight date from 2024 to 2026 (56 dates), read directly from LGLN, without rvtr.
- On each, the 5 % quantile of bDOM − DGM1. Every tile has some open ground, where a correct bDOM lies on the DGM1.
- The CRS stored in one file per flight month, and the same tiles once more through rvtr.

**Results:**
- **Raw files:** correct on every flight date, 2025 included. Over open ground they lie within ±0.5 m of the DGM1.
- **Through rvtr:** the same 2025 files come out +39.6 to +41.1 m.
- **Cause:**
  - The autumn 2025 flights (24/25 Sept, 19 and 31 Oct 2025) are the only ones whose GeoTIFF carries a vertical CRS ("DHHN2016 height"); all others are plain EPSG:25832.
  - rvtr's `.lgln_vrt()` warps to `t_srs = "EPSG:25832"`. GDAL promotes that to 3D with ellipsoidal heights and converts the DHHN2016 heights to it, adding the geoid height (about 40 m).
  - With GDAL's `-novshift` the offset is gone (median 0.00 m against the raw file, GDAL 3.12.1).

**Decision:**
- Not a data error.
- **Fixed in rvtr 55a3b00:** warps get `-novshift`, and mosaics are stamped plain EPSG:25832. The second change matters too: `buildVRT` used to drop the autumn 2025 files from mosaics that mixed them with other flights.
- **Check after the fix:** on two tiles, bDOM 2025 lies at ground level over open ground like the other surveys, within 1 m.
- **Here:** rvtr 55a3b00 pinned in the README; `method` = 3, so all tiles are redone.
- **LGLN:** at most a note that the files are now described differently from earlier flights.

## 2026-10-29 – bDOM 2025 about 40 m too high (cause found on 2026-11-05: rvtr, not LGLN)

**Found:** while testing the loss rule, a tile showed the 2025 bDOM about 40 m above all earlier surveys.

**Check:** median height difference of a bDOM against the survey before it, on 4 tiles per year:

| bDOM year | difference |
|---|---|
| 2021–2024 | −0.1 to +0.5 m (up to 2.3 m where the stand changed) |
| **2025** | **+38 to +41 m**, on every tile and every usable flight date (24/25 Sept, 19 and 31 Oct 2025) |
| 2026 | −0.2 to 0 m |

- **Likely cause (wrong, see 2026-11-05):** 40 m is the height of the geoid above the ellipsoid in northern Germany, so the 2025 bDOM seemed to be delivered in ellipsoidal heights. The leaf-off flights of spring 2025 are not used, so they were not checked.
- **Effect:** a loss has to stay down in all later surveys, so a later survey 40 m too high cancels every earlier loss. Tiles with a usable 2025 bDOM show no loss at all, even where lidar shows a clear drop.
  - About 6,500 tiles statewide have a usable 2025 bDOM flight.
  - 392 of the 2,494 tiles finished so far use one, so their results are wrong.
  - Only 5 of the 500 sample tiles use one, so the sample estimates (2026-10-23) are barely affected, if slightly low.

**Decision:** treated as a data error, not handled in the code, to be clarified with LGLN. Superseded on 2026-11-05: the error is in rvtr, and the fix goes there.

## 2026-10-23 – Statewide sample: run time, reproducibility, first figures

**Question:** before the full run: how long will it take, does it run everywhere in the state, does a second machine reproduce the results, and what does a sample say about Lower Saxony?

**Setup:**
- **Sample:** 500 of the 41,473 comparable tiles, stratified by forest share. The share is the fraction of 10 m cells with a species in the 2018 tree species map, per tile. Random within each stratum, `set.seed(20261023)` on the sorted tile IDs.

  | forest share | tiles in the state | sampled | weight |
  |---|---|---|---|
  | under 10 % | 15,765 | 100 | 157.7 |
  | 10–50 % | 17,829 | 200 | 89.1 |
  | 50 % or more | 7,879 | 200 | 39.4 |

- **Machine:** AMD Threadripper PRO 5975WX (32 cores, 64 threads, 256 GB), set up from the README alone. Package versions differ from the development machine: terra 1.9-50, sf 1.1-3, lidR 4.3.3, gdalraster 2.7.0, GDAL 3.12.1.
- **Run:** through `run.R` with `cld.tile_ids`, in two random halves with different worker counts. The project folder was on a network share; every tile was streamed from LGLN over a fast connection.
- **Reproducibility:** 2 pilot tiles (326005741, 325985739) were redone on that machine and compared cell by cell with the originals.

**Results:**
- **Reproducibility:** identical, in all 7 bands and the table rows, despite the different package and GDAL versions.
- **Robustness:** all 500 tiles measured, none skipped. Two problems came up, both at 64 workers:
  - one tile failed reading from LGLN (`[toMemory] cannot read values`);
  - one worker process died, which aborted the whole run.
  
  Both led to changes in `process_tiles.R` (see Decision). The failed tile was measured on the next run.
- **Run time:** the network and LGLN's servers set the pace, not the CPU. More workers make each tile slower.

  | workers | tiles | s per tile per worker | s per tile overall |
  |---|---|---|---|
  | 6 (development machine, 6 cores) | 25 | about 45 | about 9 |
  | 16 | 210 | 73 (median 68) | **4.7** |
  | 32 | 252 | 177 (median 152) | 5.9 |
  | 64 | 40 | 333 | about 7, then failures |

  - At 16 workers the full run takes about **2.3 days** (41,473 × 4.7 s). On a slower connection it takes longer.
  - Time per tile depends mostly on the number of epochs used: on average 50 s with 2 epochs, 80 s with 3 and 120 s with 4 (16 workers). Forest share and the amount of loss hardly matter.
- **Observed share:** 25 tiles observed less than 90 % of their area (77–90 %). These are towns, where buildings are left out, and survey edges.
- **Preliminary figures for the 41,473 comparable tiles** (stratum-weighted, 95 % intervals):

  | | estimate |
  |---|---|
  | starting canopy (above 5 m, inside and outside forest) | 920,000 ha (892,000–949,000) |
  | lost canopy | 85,000 ha (77,000–94,000) |
  | share of canopy lost | **9.2 %** (8.3–10.0) |
  | lost trees | 18.7 million (17.1–20.3), 219 per ha of loss |

  - **Loss by year of detection** (the first survey showing it; when it happened lies between that survey and the one before):

    | 2016–17 | 2018 | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025–26 |
    |---|---|---|---|---|---|---|---|---|
    | 86 ha | 2,800 ha | 560 ha | 6,700 ha | 9,500 ha | 17,100 ha | 21,300 ha | 21,700 ha | 5,700 ha |

    Survey years differ by region, so these are not annual loss rates. Most losses since 2018 are detected only by the photo surveys of 2021–2024.
  - **Rate per year:** the surveys of a tile span 7.6 years on average (canopy-weighted), typically from 2013–2017 to 2021–2024. Divided by that span, the loss is **1.2 % of the canopy per year**.
  - **By region, stratum and data situation** (stratum-weighted):

    | | tiles | canopy | lost | share lost | per year |
    |---|---|---|---|---|---|
    | all | 500 | 920,000 ha | 84,500 ha | 9.2 % | 1.2 % |
    | south (below 5,800 km N: Harz, Solling, Weserbergland) | 90 | 186,000 ha | 25,600 ha | 13.8 % | **2.3 %** |
    | north (lowlands) | 410 | 734,000 ha | 58,900 ha | 8.0 % | 1.0 % |
    | forest under 10 % | 100 | 84,000 ha | 7,800 ha | 9.3 % | 1.2 % |
    | forest 10–50 % | 200 | 341,000 ha | 27,900 ha | 8.2 % | 1.1 % |
    | forest 50 % or more | 200 | 496,000 ha | 48,800 ha | 9.8 % | 1.3 % |
    | lidar only | 239 | 409,000 ha | 38,800 ha | 9.5 % | 1.1 % |
    | with photo surveys | 261 | 512,000 ha | 45,700 ha | 8.9 % | 1.3 % |

    - The south holds 20 % of the canopy and 30 % of the loss.
    - Tiles with little forest lose their canopy (trees outside the forest) at the same rate as forest tiles.
    - Lidar-only tiles and tiles with photo surveys differ little, so at this level the photo surveys do not inflate the loss.
  - **Concentration:** the 5 % of tiles with the most loss hold 30 % of it, the top 10 % hold 45 %. Elsewhere the loss is low and spread out.
  - **Lost trees by species,** against each species' share of the forest area in the 2018 map on the same tiles (trees with a species only):

    | species | forest area | lost trees | ratio |
    |---|---|---|---|
    | pine | 36.1 % | 28.6 % | 0.8 |
    | oak | 18.3 % | 11.8 % | 0.6 |
    | spruce | 12.6 % | 34.2 % | **2.7** |
    | beech | 10.5 % | 6.8 % | 0.65 |
    | birch | 5.6 % | 5.1 % | 0.9 |
    | other broadleaf | 5.3 % | 5.0 % | 0.9 |
    | alder | 5.0 % | 3.8 % | 0.8 |
    | larch | 3.5 % | 2.3 % | 0.7 |
    | Douglas fir | 1.7 % | 1.0 % | 0.6 |

    - Ash, maple and fir are too rare to compare.
    - This compares tree counts with area. Conifers have smaller crowns, so more trees per ha, which overstates conifers somewhat.
    - 19.4 % of the lost trees have no species: trees outside the map's forest, or in areas disturbed before 2018.
  - **Lost tree heights:** 7 % up to 10 m, 42 % 10–20 m, 44 % 20–30 m, 8 % above 30 m. The loss is mostly in mature stands.
  - **Where:** high shares in the Harz, the Solling and the Weserbergland (up to 68 % of the canopy on a tile); low shares in the north and on farmland. A few tiles with little canopy show high shares from small losses.

**Interpretation** (with forest-management knowledge, not separated by the method):
- **Cause:** the detection does not tell natural disturbance from harvesting; any lasting gap of 20 m² or more counts. Most of the loss is still likely natural disturbance (drought, bark beetle, storm) and the salvage logging that follows, above all in spruce.
- **Clustered loss is disturbance:** clear cuts are not allowed in German forests, so large contiguous losses point to disturbance and salvage logging. That fits the concentration of loss in few tiles, the uplands and spruce.
- **Pine:** pine lost less than its share of the forest, and its loss is more likely regular thinning, given its management and crown structure. The same probably holds for the low, spread-out background loss in the lowlands.
- **Standing deadwood is not counted:** dead trees that still stand keep their height in the surfaces, so they are not loss. Disturbance is therefore larger than the canopy loss measured here. This matters mainly in the Harz National Park, where dead spruce is left standing, and even there most of the dead canopy has fallen by now.
- **The totals understate Lower Saxony:** most of the south has only one survey so far and is not comparable yet, including upland forest with heavy losses. The figures cover the 41,473 comparable tiles only.
- **Not validated statewide:** the thresholds were checked against later lidar mainly in the Harz.

**Decision:**
- `process_tiles.R`:
  - a failed tile is retried once after 15 s;
  - a worker that dies is replaced and the run continues. A tile that was in a worker during two such deaths is logged as failed;
  - the default number of workers is capped at 16.
- `build_outputs.R` writes the mosaics as text from the tile IDs. This takes 0.3 s for all tiles; gdalbuildvrt took 30 s for 350 tiles over the network share. The paths are relative, so the folder can be reached under any path.
- **Full run:** on the Threadripper, where the default is now 16 workers, about 2.3 days. The 500 sample tiles and earlier test tiles are already done and are skipped.

## 2026-10-22 – How many tiles allow regrowth analysis

**Question:** regrowth needs a survey before the loss, one that shows it, and a later one, ideally lidar. On how many tiles does that exist?

**Setup:** counted from the survey years in `lgln_coverage.gpkg`, without processing:
- epochs as in the detection: DOM1 in any season, bDOM May–October, one per year;
- the earliest year a loss can be seen is a tile's second epoch;
- regrowth is anything after that.

| of 41,473 comparable tiles | tiles | share |
|---|---|---|
| any survey after the earliest possible loss | 20,369 | 49 % |
| … and it is lidar | 7,684 | 18.5 % |
| lidar before, at and after the loss (3+ lidar years) | 267 | 0.6 % |

Observable regrowth period, from the second epoch to the last (shorter still for later losses):

| years | any survey | lidar |
|---|---|---|
| up to 2 | 10,484 | 5,681 |
| 2–4 | 5,951 | 1,979 |
| 4–6 | 3,858 | – |
| 6–8 | 76 | 24 |

**What it means:**
- **The survey history leaves a gap.** Lidar was flown mostly 2013–2017 and again from 2025; photo surveys run from 2021.
- **Common sequences:**
  - L2017 → b2023 (7,909 tiles): no survey after the loss at all.
  - L2015 → b2024 → L2025 (4,278 tiles): the lidar comes only 1 year after the loss was seen.
  - L2013 → L2018 → b2022/b2024, or L2013 → L2020 → b2022: losses seen in 2018/2020 with 4–6 years of follow-up, but only by photo surfaces. These are rare.
- **Lidar after the loss:** where it exists (7,700 tiles), it comes mostly 1–2 years after the loss was seen. That is too short for regrowth.
- **Longer periods (4–6 years):** only bDOM covers them, on about 3,900 tiles. Image matching smooths small crowns and fills gaps, so young trees are uncertain there.
- **Lidar-based regrowth analysis** needs the next lidar cycle, which has started with the 2025 flights. The losses of 2018–2024 become observable as lidar flights follow in the coming years.

**Possible next step:** test whether bDOM shows young regrowth reliably on the Harz dieback tiles (loss seen 2018/2020, bDOM 2022/2024), against the few places with later lidar.

## 2026-10-22 – Lost trees and their species

**Question:** can the single trees behind a loss be found, with their height, crown and species, at statewide cost?

**Method, as settled by the tests below** (`R/trees.R`):
- **Pixels:** loss pixels only. A loss is taken to be whole crowns, which the loss patches confirm visually. Their height is the last lidar survey (DOM1) up to `loss_from`, minus DGM1. Loss pixels with no lidar survey before them get no trees.
- **Tops:** lidR `lmf` on the *full* canopy height of that survey, keeping only tops on loss pixels. A top must therefore be a real local maximum, not the edge of the mask.
  - Against tops found on the loss pixels alone, this gives 5–20 % fewer tops, almost all of them on patch edges.
  - It costs about 1 s per tile.
- **Crowns:** `dalponte2016` on the loss pixels.
- **Species:** the majority species of the tree species map (2018, 10 m) within the crown.

**Window:** `lmf` keeps a pixel as top if nothing within half the window is higher.
- A generic window, `ws = 0.1·h + 1.2` (ForestTools example), split broadleaf crowns into 3–8 tops. Spruce needed a narrow window, broadleaf a wide one.
- **Crown widths from our data:** compact isolated loss patches as single crowns, 113 tiles, 15,494 patches. Broadleaf crowns are wider and grow faster with height than conifers, but the 20 m² minimum patch biases these widths upwards.
- **Literature:** no European crown-width models by height alone (they use stem diameter). Yield tables give stems per ha by height (Schober's collection: spruce Wiedemann 1936/42, pine Wiedemann 1943, beech Schober 1967, oak Jüttner 1955), which gives a stand spacing `S = sqrt(10000 / N)`, fitted as `A · h^B`.
- **Chosen:** `ws = 2.0 · S(h)` per species group, with S held constant below 16 m, the lowest table height:
  - spruce/fir `0.160 · h^1.168`;
  - pine/larch `0.114 · h^1.371`;
  - broadleaf `0.061 · h^1.510`;
  - unknown species: the mean of spruce and broadleaf.
- **The factor 2.0** is the one number fitted on our data: the one giving most single-crown patches exactly one top. It stands for the step from all stems in the yield table to the trees visible as tops in the canopy.
  - All groups: 66.6 % exactly one top, 15.8 % none, 17.6 % several.
  - Spruce 73 %, pine 69 %, broadleaf 70 %, oak 56 %.
  - A window fitted fully on our data was only 2–3 points better.
- **Oak** uses the broadleaf (beech) curve. The oak table thins so strongly with age that its own curve gave windows of almost 20 m at 35 m height, and fewer correct crowns (51 %).

**Checks:**
- **Against 0.5 m canopy heights from local lidar point clouds,** from the same flights as the DOM1 surveys used (heights agree to 0.1 m), on a spruce, a mixed and a broadleaf tile.
  - With species windows, 1 m counts stay within 0–11 % of the 0.5 m counts.
  - 84–89 % of 1 m tops have a 0.5 m top within 2 m.
  - With the generic window they were 21–34 % higher.
- **Pilot (25 tiles, Harz):** 159,319 lost trees on 766 ha of loss (208 per ha), 93 % spruce. Lost-tree detection takes about 4–8 s per tile, and the loss totals are unchanged.

**Storage:** the trees are kept in the tile rasters, as bands `species`, `crown` (tree ID) and `tree_top` (height in dm), not as a point file.
- **Size:** a point GeoPackage took 20.9 MB for the pilot's 159,319 trees, about 125 bytes each, and would grow to several GB statewide.
- **IDs:** unique across tiles, so the rasters are 32-bit. On the heaviest pilot tile (1.08 MB):
  - 32-bit instead of 16-bit adds about 12 % to bands 1–5;
  - the `crown` band takes 0.43 MB and `tree_top` 0.08 MB;
  - ZSTD compresses no better than DEFLATE.
- **Pilot total:** the 25 tiles take 19.2 MB, against 8.7 MB before plus the 20.9 MB GeoPackage. The extra size grows with the lost area, not with the number of tiles.
- **Reading:** terra cannot read the 32-bit IDs (it returns NA above 2^31). `trees_from_tiles()` reads them with gdalraster, 159,319 trees in 3 s.

**Limits:**
- Counts are estimates: neighbouring crowns can merge and large crowns can split at 1 m.
- Trees outside the forest are mostly "unknown" in the species map, and yield tables don't describe them: they have wider crowns, so they tend to be split.
- Pine above 30 m is extrapolated.
- Crowns are not post-processed: tiny or elongated crowns are kept.

## 2026-10-19 – Buildings masked; no forest mask

**Question:** canopy is everything ≥ 5 m, so houses count as canopy, and demolitions could count as loss. Which LGLN open data keeps that out best?

**Setup:**
- 72 tiles: the 25 Harz pilot tiles, 46 random statewide tiles, and the town tile 325935740 (Clausthal-Zellerfeld).
- Each mask was applied to the existing canopy and loss rasters.

| method | canopy kept | loss kept | Harz: loss kept | settlement tiles¹: canopy / loss kept | per tile | one-off preparation |
|---|---|---|---|---|---|---|
| M1 ALKIS land use, forestry | 76 % | 82 % | 88 % | 14 % / 14 % | 0.3 s, streamed | none |
| M2 as M1, grown by 5 m | 78 % | 84 % | 88 % | 16 % / 17 % | 0.3 s | none |
| M3 Basis-DLM, AX_Wald + AX_Gehoelz | 83 % | 92 % | 98 % | 19 % / 18 % | 0.03 s | 15 s download, 7 s conversion, 207 MB |
| M4 without ALKIS buildings (+1 m) | 97 % | 100 % | 100 % | 61 % / 97 % | 0.05–0.15 s | 23 s download, about 90 s conversion, 2.3 GB |

¹ 6 tiles with at least 5 % of their area under buildings.

- **ALKIS land use:** records land use, not land cover. Unmanaged forest is "ohne Nutzung", so the Harz National Park falls out. On tile 326025739 it kept only 12 of 35 ha of loss.
- **Basis-DLM:** records forest as land cover, so the national park stays in. It is more generalised (about ±3 m, minimum area 0.1 ha).
- **Forest masks (M1–M3):** in towns and villages they drop the garden trees, street trees, hedges and tree rows. These make up most of the non-forest loss.
- **Buildings:** they were not misread as loss in this sample, since they stand in every survey. But they made up 39 % of the "canopy" on settlement tiles.

**Decision:**
- Mask buildings (M4), and keep all other vegetation. The focus is forest, but changes to trees outside the forest are wanted too, and no change figure should come from a building.
- `scripts/get_buildings.R` downloads the footprints once into `data/buildings.gpkg`.
- `tile_loss()` masks them, grown by `building_grow` = 1 m, out of `loss_year`, `loss_from` and `observed`. `process_tiles.R` masks them out of `canopy`.
- On the town and village tiles, the loss equals M4 to the hectare.
- A forest mask from Basis-DLM (M3) is the better choice if forest-only figures are ever needed, for example as an extra band.

## 2026-10-19 – Loss dated to a period

A loss is only known to lie between two surveys, so a single year overstates what the data says. The tile rasters now carry a fourth band:

- `loss_year`: the year of the first survey that shows the loss (latest possible year, unchanged).
- `loss_from`: the year of the last survey that saw the cell before the loss (earliest possible year). It is the same year as that survey, not the next, because many flights are in early spring and the loss can still fall in that year. A survey that did not reach the cell is skipped.

**Check:**
- On a tile with 5 epochs (2015, 2021, 2024, 2025, 2026), the pairs are only consecutive epochs (2015–2021, 2021–2024, 2024–2025), and `loss_from` is NA exactly where `loss_year` is.
- On plot NI-ND-13, where the 2022 and 2025 lidar cover only part, the pairs 2021–2025 and 2022–2026 appear where an epoch is missing.
- The existing bands are unchanged everywhere. Pilot loss total: still 766.3 ha.

## 2026-10-19 – Parallel framework, workers, tiles without DGM1

**Setup:** 48 random comparable tiles outside the pilot, run with `process_tiles.R` on a 12-thread, 6-core machine. Base R `parallel` (`parLapplyLB` in chunks) against mirai (`mirai_map`, no chunks), in alternating order.

| workers | `parallel` | mirai |
|---|---|---|
| 8 | 272 s, 5.7 s per tile | 247 s, 5.2 s per tile |
| 12 | 238 s, 5.0 s per tile | 236 s, 4.9 s per tile |
| 16 | 251 s, 5.2 s per tile | 246 s, 5.1 s per tile |

- **Framework:** mirai is about 10 % faster at 8 workers, where the chunk barrier shows, and the same beyond. Each configuration ran once.
- **Workers:** more than 12 do not help. The time per tile per worker rises (mean 37 s at 8, 52 s at 12, 65 s at 16).
- **Results:** the rasters are identical cell for cell across all configurations.

**Decision:**
- Keep `parallel`, with `n_workers` = half the logical cores (`detectCores() %/% 2`).
- 2 of the 48 tiles failed: LGLN has no DGM1 there, so the starting canopy cannot be measured. 1,880 of 43,353 tiles with two epochs or more are in that position, mostly on the coast and the border.
  - `get_lgln_coverage.R` now reads the DGM1 index and only counts a tile as `comparable` with a DGM1, which leaves 41,473 comparable tiles.
  - `build_outputs.R` gives the others the reason "no DGM1 terrain model".

## 2026-10-19 – Regrowth allowance adopted; surfaces read once

- **Regrowth allowance:** adopted at **0.5 m/yr** (`regrowth` in `R/params.R`).
  - This is above the measured 0.3 m/yr (see the next entry). The choice favours keeping real losses that have partly regrown; in the test that cost almost no extra false loss.
  - Watch for long gaps between epochs, where the allowance grows large.
- **Check:** with `regrowth = 0`, `loss_year()` gives the same cells as before on a 3-epoch and a 5-epoch tile.
  - Pilot: loss 766.3 ha (was 765.6).
  - Plots (local scale): +0.01 to +0.04 ha against bDOM max alone.
- **Surfaces read once:** `surfaces()` now reads its rasters into memory. Before, terra streamed each remote VRT again for every operation that touched it.
  - Outputs are identical.
  - A 5-epoch tile went from 114–125 s to 36–45 s.
  - Pilot: 40 s per tile per worker (was 124 s), 5.9 s per tile with 8 workers, so about **3 days** for all 43,353 comparable tiles (was about 10).
- **Settings:** the detection settings moved to `R/params.R` (`detection_params`), shared by `process_tiles.R`, `image_tile.R` and `get_lgln_coverage.R`.

## 2026-10-19 – Larger opening, regrowth allowance

**Questions:**
- Should the opening be larger, so that narrow linear features are dropped?
- Should a loss still count if the gap has regrown a little by a later epoch?

**Growth in undisturbed canopy:**
- **Setup:** 160 random tiles with two DOM1 years, measured lidar to lidar. Losses were masked: any drop over 5 m, plus 3 m around it.

| first lidar height | median per year | 25–75 % |
|---|---|---|
| ≥ 10 m (mature) | 0.26 m | 0.17–0.28 m |
| 3–10 m (young) | 0.18 m | 0.05–0.48 m |

- Over spans of more than 6 years: young stands 0.33–0.37 m/yr, mature stands 0.22–0.26 m/yr. Spans of 3 years or less come out near zero or negative, where flight season offsets outweigh growth.

**Validation setup:**
- 40 random tiles with at least 3 epochs before the reference lidar (38 of them: lidar 2015, bDOM 2021, bDOM 2024, checked against lidar 2025).
- With an epoch after the loss, "loss must last" applies. This is why precision is much higher here than in the 2-epoch tests.

| variant | detected | confirmed | contradicted | clear removals found |
|---|---|---|---|---|
| current (opening radius 1.5 m) | 46.9 ha | 42.3 ha (90 %) | 3.5 ha (7.4 %) | 60.9 % |
| opening radius 2 m | 40.9 ha | 37.5 ha (92 %) | 2.5 ha (6.1 %) | 55.3 % |
| opening radius 2.5 m | 37.2 ha | 34.5 ha (93 %) | 2.0 ha (5.3 %) | 51.7 % |
| regrowth 0.3 m/yr | 48.6 ha | 43.6 ha (90 %) | 3.6 ha (7.3 %) | 61.5 % |
| regrowth 0.5 m/yr | 49.4 ha | 44.1 ha (89 %) | 3.6 ha (7.3 %) | 61.9 % |

- **Opening:**
  - Radius 1.5 m at 1 m resolution is already a full 3 × 3 kernel, so anything narrower than 3 m is dropped today.
  - Radius 2 removes 6.0 ha: 4.8 ha confirmed, 1.0 ha contradicted. Radius 2.5 removes 9.7 ha: 7.8 ha confirmed, 1.5 ha contradicted.
  - So a larger opening removes about five times more real loss than false loss.
- **Regrowth allowance:**
  - 0.3 m/yr adds 1.8 ha: 1.3 confirmed, 0.4 uncertain, 0.1 contradicted.
  - 0.5 m/yr adds 2.5 ha: 1.8 confirmed, 0.6 uncertain, 0.1 contradicted.
  - Nearly all of it is real. The "uncertain" class (lidar 2–5 m lower) fits a real cut that has partly regrown.
  - Only 3-year gaps were tested. Over long gaps the allowance grows: 0.5 m/yr over 12 years is 6 m. Undisturbed canopy grows about 0.26 m/yr, so with 0.5 m/yr a false drop's margin to the 5 m threshold shrinks by about 0.24 m/yr. A lidar season offset of 1–2 m could then bring it near the threshold.
  - At about the measured rate (0.3 m/yr), undisturbed canopy stays close to 5 m from the threshold whatever the gap.

**Recommendation:**
- Keep the 1.5 m opening radius.
- Add a regrowth allowance of 0.3 m/yr to `loss_year()`: a loss dated to year k still counts in a later epoch j if the cell stands no more than 0.3 × (year_j − year_k) higher.

## 2026-10-16 – Pilot re-run with the current method

25 tiles, 598000–603000 × 5739000–5744000 (Harz near Clausthal), run with `process_tiles.R` (`bbox` set) and `build_outputs.R`.

- **Epochs:** every tile has the same three: lidar 2013, lidar 2018 and bDOM 2022-05-09. The bDOM of 2025-04-03 is dropped as leaf-off.
- **Loss:** observed 2,500 ha; forest at the start 1,580 ha. Loss 766 ha, which is **48.5 % of the forest**: 117 ha in 2018 and 648 ha in 2022.
- **Per tile:** 18–72 % of the forest lost (median 47 %), as expected for the spruce dieback after 2018.
- **Last epoch:** the 2022 bDOM is the last epoch here, so "loss must last" cannot check it. In spruce the flight season matters little (see below).
- **Run time:** 124 s per tile per worker (was about 30 s with cubic bDOM). That is 19.4 s per tile with 8 workers, about **10 days** for the 43,353 comparable tiles (was about 2).
  - Nearly all of it is reading native 20 cm bDOM for the maximum.
  - rvtr already fetches only the `bdom20` asset. The `bdom10` links in the catalogue return 404.

## 2026-10-16 – bDOM season: no calendar cutoff

**Question:** do early-season bDOM flights cause false losses, and should the season start later than 1 May?

**Setup:**
- 72 tiles, 6 for each bDOM flight date, drawn from tiles that have a bDOM between two DOM1 years.
- The detection ran on the first DOM1 and that one bDOM only, so the bDOM is the last epoch (the worst case).
- bDOM read as max (see below).

| bDOM flight | contradicted | false loss per 100 ha forest | clear removals found |
|---|---|---|---|
| 2021-04-28 | 68 % | 9.3 ha | 51 % |
| 2024-04-30 | 20 % | 1.7 ha | 55 % |
| 2024-05-01 | 19 % | 2.7 ha | 73 % |
| 2024-05-02 | 13 % | 1.0 ha | 69 % |
| 2024-05-08 | 6 % | 0.6 ha | 71 % |
| 2024-05-15 | 15 % | 1.5 ha | 81 % |
| 2021-05-31 | 16 % | 1.0 ha | 43 % |
| 2024-06-26 | 2 % | 0.2 ha | 78 % |
| 2024-07-20 | 4 % | 0.3 ha | 76 % |
| 2024-09-06 / 07 / 21 | 10 / 24 / 9 % | 0.4 / 1.8 / 1.1 ha | 52–78 % |

- **Within May 2024** there is no trend with date. 30 April 2024 is as good as early May, while late April 2021 is bad. Leaf-out depends on the year (2021 had a cold spring, 2024 a warm one).
- **Best months:** June and July (2–4 %). September is mostly fine, with single bad tiles at about 50 %.
- **Confounding:** each date is one flight block, so date, region and stand type are mixed together.
  - bDOM matching works well in conifers in any season, so a date effect is really a broadleaf effect.
  - bDOM quality may also differ by year and flight block (source imagery, matching).
- **Cost of a later start:** moving it to 20 May would leave 4,764 tiles with fewer than two epochs, and take a third epoch from another 8,769.

**Decision:** keep May–October. A fixed calendar date is the wrong tool. If revisited, split the validation into conifer and broadleaf (e.g. Copernicus dominant leaf type), or use a year-specific season start.

## 2026-10-16 – bDOM read as the per-cell maximum

**Question:** cubic resampling of the 20 cm bDOM onto the 1 m grid averages the surface into the gaps between crowns. Does taking the maximum instead reduce false losses?

**Setup:** 10 forest tiles under the DiVerSa plots. Detection on lidar 2015 + bDOM 2021/2024, checked against lidar 2022/2025.

| bDOM resampling | detected | confirmed | contradicted | clear removals found | s per tile |
|---|---|---|---|---|---|
| cubic | 106 ha | 59.5 ha (56 %) | 40.6 ha (38 %) | 78 % | 15 |
| **max** | 72 ha | 51.5 ha (72 %) | 17.6 ha (24 %) | 69 % | 45 |
| q3 (75th percentile) | 83 ha | 55.2 ha (66 %) | 24.0 ha (29 %) | 73 % | 45 |
| max, opening 2.5 m, min. patch 100 m² | 42 ha | 31.2 ha (75 %) | 9.2 ha (22 %) | 44 % | 43 |
| q3, opening 2.5 m, min. patch 100 m² | 49 ha | 34.3 ha (71 %) | 12.3 ha (25 %) | 48 % | 43 |

- **Max:** removes about 3 ha of false loss for every 1 ha of real loss, and improves every tile. What it loses are cells at loss edges, where the highest pixel belongs to a neighbouring crown that is still standing.
- **q3:** lies between cubic and max on every tile.
- **Stronger cleaning:** removes more real loss than false loss, so the 1.5 m opening and 20 m² minimum patch stay.
- **"Only where the lidar had trees":** a mask like that is not needed. Loss is measured from a cell's lowest earlier height, so a gap in the first lidar cannot be "lost" later. Only 0.3 ha per variant was detected where the first lidar stood under 5 m.

**Decision:** read bDOM as max (`surfaces()` in `R/detection.R`, rvtr ≥ 87afb2c).
- Lidar records the highest return per cell, so both surfaces now mean the same thing.
- On 5 plots in lidar-biodiversity-plots, loss fell by 0.01–0.13 ha per plot.

## 2026-10-15 – No levelling, no relative drop test

**Question:** each step between epochs was levelled on its median, to take out the offset between lidar and photogrammetry. Separately, a drop could also be required to remove more than 50 % of the stand height. Do either of these help?

**Setup:** the same 10 tiles, with cubic bDOM.

| variant | detected | confirmed | contradicted | clear removals found |
|---|---|---|---|---|
| levelled, drop > 5 m | 107 ha | 56 % | 39 % | 78 % |
| not levelled, drop > 5 m | 106 ha | 56 % | 38 % | 78 % |
| not levelled, drop > 5 m and > 50 % | 78 ha | 63 % | 33 % | 69 % |

- **Levelling:** no measurable difference overall. Per tile it helped some and hurt others. It also made a cell's result depend on the rest of the grid: in the first pilot, the 2013→2018 step was levelled by +2.12 m in one tile and +0.04 m in the tile next to it.
- **The 50 % rule:** trades recall for precision. It would also miss trees lost over a lower canopy layer, where the surface falls only to the layer beneath.

**Decision:** drop both. Steps are taken as measured, and a loss is an absolute drop of more than 5 m that lasts through every later epoch. The plots repo followed. On 5 plots, only the loss layer changed (−0.05 to +0.04 ha).

## 2026-10-13 – First pilot: tile edges

Same 25 tiles, with the original method (levelled, cubic bDOM).

- **Seams:** none at tile edges with the 50 m buffer. Neighbouring tiles fetch identical surfaces over their overlap. The loss share jumps less across a tile edge (4 %) than between bands 40 m apart away from edges (9 %).
- **Run time:** about 30 s per tile per worker, 4.3 s per tile with 8 workers.

## Open

- **Statewide run:** continue it on the Threadripper with 16 workers, about 2.3 days (see 2026-10-23). It stopped on 2026-10-23 with 2,494 tiles done. With `method` = 4 (lidar reset, rvtr 55a3b00, loss filters, the same filters for the starting canopy; 2026-11-05, 2026-11-09 and 2026-11-10) all of them are redone, so it starts over: about 2.4 days for all 41,473. Install rvtr 55a3b00 on that machine first, and pilot 8 against 16 workers (the read settings of 2026-11-09 double the connections per worker). Steps in `CLAUDE.md`.
- **Terrain:** decide on the metrics, the storage and the statewide step (2026-11-09). `tile_loss()` now reads the local `data/dgm1` (2026-11-10). Only three hill blocks tested so far; harvest is not separated from disturbance.
- **Regrowth:** wait for the next lidar cycle; meanwhile test bDOM for young regrowth (see 2026-10-22).
- **Plots repo:** re-run its outputs (`data/*/canopy_loss/`), which still hold levelled, cubic results.
- **Lost trees:**
  - crown post-processing: drop crowns of 5 pixels or less, and elongated ones (axis ratio below about 0.4);
  - a window for trees outside the forest;
  - a check against more point-cloud tiles.
- **Grew up, then cut:** solved where lidar saw the growth (2026-11-05). Still missed where only bDOM saw it.
- **Plots repo:** its outputs also need the lidar reset. Its two `loss_year()` calls no longer run since 2026-11-09: the function now takes `p`, `above_ground` and `lake`.
