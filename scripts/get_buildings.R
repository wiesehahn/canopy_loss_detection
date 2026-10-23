# The ALKIS building footprints (Hausumringe) for all of Lower Saxony, as an
# indexed GeoPackage the tiles can read their part of. Buildings are masked out
# of the canopy and the losses (R/tile_loss.R), so no change figure can come
# from a building. LGLN publishes them only as one zipped shapefile, so this
# downloads it once (about 690 MB) and converts it (about 2.4 GB, a few
# minutes). run.R runs it when the file is missing; delete the file, or run
# this again, to pick up a newer release. Tiles already processed keep the
# footprints they were made with.
library(sf)
library(cli)

source("R/params.R")
url      <- "https://hausumringe-nie.s3.eu-de.cloud-object-storage.appdomain.cloud/gebaeude-ni.zip"
out_file <- detection_params$buildings

zip <- tempfile(fileext = ".zip")
cli_progress_step("Downloading the building footprints (about 690 MB)")
old <- options(timeout = max(3600, getOption("timeout")))  # R's default is 60 s
download.file(url, zip, mode = "wb", quiet = TRUE)
options(old)

cli_progress_step("Converting them to {.file {out_file}}")
tmp <- sub("[.]gpkg$", "_part.gpkg", out_file)  # renamed when complete
unlink(tmp)
gdal_utils("vectortranslate", paste0("/vsizip/", zip, "/gebaeude-ni.shp"), tmp,
           c("-nln", "buildings", "-nlt", "MULTIPOLYGON", "-t_srs", "EPSG:25832"))
invisible(file.rename(tmp, out_file))
unlink(zip)
cli_progress_done()
cli_alert_success("{st_layers(out_file)$features} buildings written to {.file {out_file}}")
