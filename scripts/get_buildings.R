# The ALKIS building footprints (Hausumringe) for all of Lower Saxony, as an
# indexed GeoPackage the tiles can read their part of. Buildings are masked out
# of the canopy and the losses (R/tile_loss.R), so no change figure can come
# from a building. LGLN publishes them only as one zipped shapefile, so this
# downloads it once (about 690 MB) and converts it (about 2.4 GB, a few
# minutes). Run it again to pick up a newer release.
library(sf)

source("R/params.R")
url      <- "https://hausumringe-nie.s3.eu-de.cloud-object-storage.appdomain.cloud/gebaeude-ni.zip"
out_file <- detection_params$buildings

zip <- tempfile(fileext = ".zip")
on.exit(unlink(zip))
message("downloading building footprints")
download.file(url, zip, mode = "wb", quiet = TRUE)

tmp <- sub("[.]gpkg$", "_part.gpkg", out_file)  # renamed when complete
unlink(tmp)
gdal_utils("vectortranslate", paste0("/vsizip/", zip, "/gebaeude-ni.shp"), tmp,
           c("-nln", "buildings", "-nlt", "MULTIPOLYGON", "-t_srs", "EPSG:25832"))
invisible(file.rename(tmp, out_file))
message(st_layers(out_file)$features, " buildings written to ", out_file)
