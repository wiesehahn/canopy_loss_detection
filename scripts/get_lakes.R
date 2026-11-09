# The standing water of Lower Saxony (AX_StehendesGewaesser, Basis-DLM), as an
# indexed GeoPackage the tiles can read their part of. Old lidar surveys run a
# surface over open water, which later reads as lost canopy (R/detection.R).
# The Basis-DLM comes as one zip, so this downloads it once (about 550 MB) and
# keeps these polygons (a few MB). run.R runs it when the file is missing;
# delete the file, or run this again, to pick up a newer release. Tiles already
# processed keep the lakes they were made with.
library(sf)
library(cli)

source("R/params.R")
url      <- "https://single-datasets.s3.eu-de.cloud-object-storage.appdomain.cloud/bdlm/nba_bkg_bdlm_ni.zip"
out_file <- detection_params$lakes

zip <- tempfile(fileext = ".zip")
cli_progress_step("Downloading the Basis-DLM (about 550 MB)")
old <- options(timeout = max(3600, getOption("timeout")))  # R's default is 60 s
download.file(url, zip, mode = "wb", quiet = TRUE)
options(old)

cli_progress_step("Writing the lakes to {.file {out_file}}")
shp <- grep("/gew01_f[.]shp$", unzip(zip, list = TRUE)$Name, value = TRUE)  # the folder has the version
tmp <- sub("[.]gpkg$", "_part.gpkg", out_file)  # renamed when complete
unlink(tmp)
gdal_utils("vectortranslate", paste0("/vsizip/", zip, "/", shp), tmp,
           c("-nln", "lakes", "-nlt", "MULTIPOLYGON", "-t_srs", "EPSG:25832",
             "-where", "OBJART_TXT = 'AX_StehendesGewaesser'", "-select", "OBJART_TXT"))
invisible(file.rename(tmp, out_file))
unlink(zip)
cli_progress_done()
cli_alert_success("{st_layers(out_file)$features} lakes written to {.file {out_file}}")
