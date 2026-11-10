# Optional: a local copy of LGLN's DGM1, one file per tile, for tile_loss() to
# read instead of streaming it (R/tiles.R, tile_dtm()). The results are the
# same either way. It saves about 3 s of reading per tile and takes load off
# LGLN's servers. About 190 GB for the 49,708 tiles, about 2 h to fetch at
# 24 MB/s. Not run by run.R.
#
# Writes data/dgm1/<tile_id>.tif and data/dgm1/index.csv, one row per tile:
# the flight rvt_data_lgln() fetches for it (the newest file year, then the
# newest date; LGLN's index holds every flight) and its URL. A tile listed
# there but missing as a file is streamed from that URL.
#
# Run it again to bring the copy up to date: only tiles that are missing, or
# whose flight LGLN has replaced since, are fetched. A copy left stale would
# give the old terrain where streaming gives the new one, so rerun it when
# LGLN publishes new DGM1 flights. Do not run it during a statewide run.
library(sf)
library(curl)
library(cli)

source("R/lgln_index.R")
out_dir <- "data/dgm1"
index   <- file.path(out_dir, "index.csv")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
unlink(list.files(out_dir, "[.]part$", full.names = TRUE))  # from a killed run

cli_progress_step("Reading the DGM1 tile index")
x <- st_drop_geometry(st_read(paste0("/vsicurl/", lgln_index_url[["dgm1"]]), quiet = TRUE))
x$file_year <- as.integer(sub(".*_([0-9]{4})[.]tif$", "\\1", x$dgm1))
x <- x[order(x$tile_id, x$file_year, x$Aktualitaet), ]
x <- x[!duplicated(x$tile_id, fromLast = TRUE), c("tile_id", "Aktualitaet", "file_year", "dgm1")]
x$Aktualitaet <- as.character(x$Aktualitaet)
cli_progress_done()

old  <- if (file.exists(index)) read.csv(index, colClasses = "character") else x[0, ]
file <- file.path(out_dir, paste0(x$tile_id, ".tif"))
old_url <- old$dgm1[match(x$tile_id, old$tile_id)]
todo <- which(!file.exists(file) | is.na(old_url) | old_url != x$dgm1)
gone <- setdiff(old$tile_id, x$tile_id)  # no longer in LGLN's index
unlink(file.path(out_dir, paste0(gone, ".tif")))
cli_alert_info("{nrow(x)} tiles; {length(todo)} to fetch, {length(gone)} removed")

# One batch through a pool of 16 connections. TRUE for each file that arrived
# whole: status 200 and as many bytes as the server announced.
fetch <- function(urls, parts) {
  pool <- new_pool(total_con = 16, host_con = 16, multiplex = FALSE)
  ok <- rep(FALSE, length(urls))
  for (i in seq_along(urls)) local({
    k <- i
    multi_add(new_handle(url = urls[k], connecttimeout = 60, timeout = 900),
              data = parts[k], pool = pool,
              done = function(res) {
                n <- parse_headers_list(res$headers)[["content-length"]]
                ok[k] <<- res$status_code == 200 && !is.null(n) &&
                  isTRUE(file.size(parts[k]) == as.numeric(n))
              },
              fail = function(e) NULL)
  })
  multi_run(pool = pool)
  ok
}

fetched <- integer()
left <- todo
for (pass in 1:3) {
  if (!length(left)) break
  if (pass > 1) Sys.sleep(30)
  failed <- integer()
  batches <- split(left, ceiling(seq_along(left) / 160))
  cli_progress_bar(paste("Fetching, pass", pass), total = length(left))
  for (b in batches) {
    part <- paste0(file[b], ".part")
    ok <- fetch(x$dgm1[b], part)
    ok[ok] <- file.rename(part[ok], file[b][ok])  # written whole, then renamed
    unlink(part[!ok])
    fetched <- c(fetched, b[ok])
    failed  <- c(failed, b[!ok])
    cli_progress_update(inc = length(b))
  }
  cli_progress_done()
  left <- failed
}

# The index says what is on disk: the new flight where it arrived, the old one
# where a replacement failed and the old file is still there, and the URL of a
# tile with no file at all, so it is streamed.
keep_old <- left[file.exists(file[left]) & !is.na(old_url[left])]
new <- x
new[keep_old, ] <- old[match(x$tile_id[keep_old], old$tile_id), names(x)]
tmp <- paste0(index, ".part")
write.csv(new, tmp, row.names = FALSE)
invisible(file.rename(tmp, index))

if (length(left))
  cli_alert_warning("{length(left)} tile{?s} could not be fetched ({.val {head(x$tile_id[left], 5)}}...): run again")
cli_alert_success("{length(fetched)} fetched; {sum(file.exists(file))} of {nrow(x)} tiles in {.file {out_dir}}")
