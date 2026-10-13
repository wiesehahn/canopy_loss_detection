# Temporal coverage of the LGLN canopy surfaces over all of Lower Saxony, one
# polygon per 1 x 1 km tile: which years each tile has a DOM1 (lidar) and a
# bDOM20 (photogrammetric) surface for, and so how many epochs the change
# detection could difference there - without fetching a single surface, so it
# says beforehand which tiles process_tiles.R has anything to compare in.
#
# The source is LGLN's own tile index, one GeoJSON per product with a feature
# per tile and flight, so a tile flown in five years appears five times. It
# holds the full history, not only the latest flight.
#
# Two layers in `out_file`:
#
#   tiles    one polygon per tile, EPSG:25832, with the summary columns below.
#   flights  no geometry, one row per tile and flight - the index itself, cut
#            down, for anything the summary does not answer. Joins on tile_id.
#
# The epoch rules follow R/epochs.R as far as a tile index can: DOM1 counts
# in any season, bDOM20 only when flown in `veg_months`, and a year is one epoch
# however many products or flights it holds. rvt_data_lgln() fetches each
# tile's latest flight within a year, so that is the flight whose month decides
# whether a bDOM20 year counts. What the index cannot say is how much of a
# given plot a tile reaches, so this is an upper bound on what lgln_epochs()
# will accept for a plot, not the same answer.
library(sf)

veg_months <- 5:10  # vegetation period, bDOM only, as in process_tiles.R
out_file   <- "data/lgln_coverage.gpkg"

index_url <- c(
  dom1 = "https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/dom1/lgln-opengeodata-dom1.geojson",
  bdom = "https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/bdom20/lgln-opengeodata-bdom20.geojson")
url_field <- c(dom1 = "dom1", bdom = "bdom")

read_index <- function(product) {
  message("reading ", product, " index")
  x <- st_read(paste0("/vsicurl/", index_url[[product]]), quiet = TRUE)
  date <- as.Date(substr(x$Aktualitaet, 1, 10))
  x$product <- product
  x$date    <- date
  x$year    <- as.integer(format(date, "%Y"))
  x$url     <- x[[url_field[[product]]]]
  # Since 2024 some bDOM flights come as a 10 cm bdom10 beside the bdom20, so a
  # flight can appear twice; this says which file a row is.
  x$file    <- sub("_32_.*", "", basename(x$url))
  x[c("tile_id", "product", "file", "date", "year", "url")]
}

idx <- rbind(read_index("dom1"), read_index("bdom"))

# The tile outlines, once per tile. They repeat identically for every flight
# and in both indexes, since both sit on the same 1 km grid.
tiles <- idx[!duplicated(idx$tile_id), "tile_id"]

flights <- st_drop_geometry(idx)
flights <- flights[order(flights$tile_id, flights$product, flights$date,
                         flights$file), ]

# The flight rvt_data_lgln() would fetch for a tile and year: its latest.
latest <- flights[!duplicated(flights[c("tile_id", "product", "year")],
                              fromLast = TRUE), ]
latest$usable <- latest$product == "dom1" |
  as.integer(format(latest$date, "%m")) %in% veg_months

flights$latest_in_year <- paste(flights$tile_id, flights$product, flights$date) %in%
  paste(latest$tile_id, latest$product, latest$date)

# Per tile, the years a selection of `latest` holds, as "2015,2021,2024".
years_of <- function(sel) {
  y <- tapply(latest$year[sel], latest$tile_id[sel],
              \(v) paste(sort(unique(v)), collapse = ","))
  out <- as.vector(y[tiles$tile_id])
  out[is.na(out)] <- ""
  out
}
count_of <- function(s) ifelse(s == "", 0L, lengths(strsplit(s, ",")))

dom1 <- latest$product == "dom1"
bdom <- latest$product == "bdom"

tiles$dom1_years     <- years_of(dom1)
tiles$dom1_n         <- count_of(tiles$dom1_years)
tiles$bdom_years     <- years_of(bdom)
tiles$bdom_n         <- count_of(tiles$bdom_years)
tiles$bdom_veg_years <- years_of(bdom & latest$usable)
tiles$bdom_veg_n     <- count_of(tiles$bdom_veg_years)

# The epochs the change detection could use: one per year with a usable surface.
tiles$epoch_years <- years_of(latest$usable)
tiles$n_epochs    <- count_of(tiles$epoch_years)

ep <- lapply(strsplit(tiles$epoch_years, ","), as.integer)
tiles$first_epoch <- vapply(ep, \(v) if (length(v)) min(v) else NA_integer_, 1L)
tiles$last_epoch  <- vapply(ep, \(v) if (length(v)) max(v) else NA_integer_, 1L)
tiles$span_years  <- tiles$last_epoch - tiles$first_epoch
# Longest stretch between two epochs - how long a loss can go undated within.
tiles$max_gap     <- vapply(ep, \(v) if (length(v) > 1) max(diff(v)) else NA_integer_, 1L)

# Whether the change detection can run here at all, and if so whether it can
# rest on lidar alone, which differences more reliably than lidar to bDOM.
tiles$comparable <- tiles$n_epochs >= 2
tiles$lidar_only <- tiles$dom1_n >= 2

st_geometry(tiles) <- "geom"
tiles <- tiles[order(tiles$tile_id), ]

if (file.exists(out_file)) file.remove(out_file)
st_write(tiles, out_file, layer = "tiles", quiet = TRUE)
st_write(flights, out_file, layer = "flights", append = TRUE, quiet = TRUE)

message(nrow(tiles), " tiles, ", sum(tiles$comparable), " with two or more epochs, ",
        sum(tiles$lidar_only), " with two or more lidar years")
print(table(n_epochs = tiles$n_epochs))
