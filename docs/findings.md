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
  - **Data situation:** the share lost is about the same on lidar-only tiles (9.5 %) and on tiles with photo surveys (8.9 %).
  - **Lost trees by species:** spruce 27.5 %, pine 23.0 %, oak 9.5 %, beech 5.5 %, birch 4.1 %, other broadleaf 4.0 %, alder 3.0 %, larch 1.9 %, others under 1 %. 19.4 % have no species: trees outside the map's forest, or in areas disturbed before 2018.
  - **Where:** high shares in the Harz, the Solling and the Weserbergland (up to 68 % of the canopy on a tile); low shares in the north and on farmland. A few tiles with little canopy show high shares from small losses.
  - **Loss includes harvesting:** any lasting gap of 20 m² or more counts, not only damage.

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

- **Statewide run:** start it on the Threadripper with 16 workers, about 2.3 days (see 2026-10-23). 561 tiles are done.
- **Regrowth:** wait for the next lidar cycle; meanwhile test bDOM for young regrowth (see 2026-10-22).
- **Plots repo:** re-run its outputs (`data/*/canopy_loss/`), which still hold levelled, cubic results.
- **Lost trees:**
  - crown post-processing: drop crowns of 5 pixels or less, and elongated ones (axis ratio below about 0.4);
  - a window for trees outside the forest;
  - a check against more point-cloud tiles.
- **Grew up, then cut:** a tree that grew up after the first epoch and was then cut is missed, because the running floor stays at the old gap. This is a different case from the regrowth allowance, which tolerates regrowth after a loss.
