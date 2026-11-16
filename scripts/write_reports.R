# Two short pages from the tables the other steps keep in data/, no raster
# read, so this takes seconds:
#
#   docs/status.md   how far processing is: tiles done, to redo and to do, the
#                    survey years tiles can show a loss in, and how the runs go.
#                    With a map of it, docs/images/status_tiles.png.
#   docs/results.md  what has been detected so far, over the tiles done with
#                    the current settings only, so every figure comes from one
#                    method: areas, loss and lost trees per year, lost trees
#                    per species. With a map of the canopy lost per tile,
#                    docs/images/results_loss.png.
#   docs/map/data/   the tables of the web map, docs/map/index.html (see
#                    write_map_data() below).
#
# run.R writes both at the end of every run. Source this by hand to look at a
# run that is still going: it only reads the tables. A page or map is
# rewritten only when its content changes, so all can be kept in git.
library(sf)
library(terra)
library(cli)

source("R/params.R")
source("R/status.R")  # tile_state()
source("R/trees.R")   # species_classes

coverage_file <- "data/lgln_coverage.gpkg"
result_file   <- "data/tile_results.csv"
epoch_file    <- "data/epochs.csv"
run_log       <- "data/runs.csv"
params_dir    <- "data/params"
status_file   <- "docs/status.md"
results_file  <- "docs/results.md"
map_dir       <- "docs/map/data"

# A table as process_tiles.R writes it, `text` columns read as text (one empty
# in every row would otherwise read as NA). Missing, it is empty, with `cols`.
read_table <- function(file, text, cols) {
  x <- if (file.exists(file)) {
    have <- intersect(text, names(read.csv(file, nrows = 0)))
    read.csv(file, colClasses = setNames(rep("character", length(have)), have))
  } else {
    data.frame(matrix(character(), 0, length(cols), dimnames = list(NULL, cols)))
  }
  for (col in setdiff(cols, names(x))) x[[col]] <- rep(NA_character_, nrow(x))
  x
}

# Years as the coverage lists them, "2013,2018", one sorted vector per tile.
parse_years <- function(x)
  lapply(strsplit(ifelse(is.na(x), "", x), ","),
         \(v) sort(unique(as.integer(trimws(v[nzchar(trimws(v))])))))

# Counts as process_tiles.R writes them, "2018:12;2022:340", summed over all
# rows into one named vector.
parse_counts <- function(x) {
  x <- x[!is.na(x) & x != ""]
  if (!length(x)) return(setNames(numeric(), character()))
  kv <- strsplit(unlist(strsplit(x, ";")), ":")
  tapply(as.numeric(vapply(kv, `[`, "", 2)), vapply(kv, `[`, "", 1), sum)
}

fmt <- function(x, digits = 0) formatC(x, format = "f", digits = digits, big.mark = ",")
pct <- function(a, b) if (b > 0) paste0(fmt(100 * a / b, 1), " %") else "–"
ha  <- function(m2) paste(fmt(m2 / 1e4), "ha")

# A Markdown table, the first column left-aligned, the others right.
md_table <- function(df) {
  df[] <- lapply(df, \(x) gsub("|", "/", as.character(x), fixed = TRUE))
  rows <- do.call(paste, c(unname(as.list(df)), sep = " | "))
  c(paste0("| ", paste(names(df), collapse = " | "), " |"),
    paste0("|", paste(c(":--", rep("--:", ncol(df) - 1)), collapse = "|"), "|"),
    paste0("| ", rows, " |"))
}

# Write `lines` to `file` unless it already holds exactly them.
write_page <- function(lines, file, note) {
  lines <- enc2utf8(lines)
  old <- if (file.exists(file)) readLines(file, encoding = "UTF-8", warn = FALSE)
  if (identical(old, lines)) {
    cli_alert_success("{.file {file}} is up to date")
  } else {
    con <- file(file, open = "w", encoding = "UTF-8")
    writeLines(lines, con)
    close(con)
    cli_alert_success(paste0("{.file {file}} written: ", note))
  }
}

# Maps of one value per tile on the 1 km grid, drawn like the coverage maps
# (scripts/map_coverage.R). `tile_id` gives the lower-left corner in km
# (R/tiles.R), `value` one value per tile, NA where the tile is not drawn.
tile_raster <- function(tile_id, value) {
  x <- as.numeric(substr(tile_id, 3, 5)) * 1000
  y <- as.numeric(substr(tile_id, 6, 9)) * 1000
  r <- rast(xmin = min(x), xmax = max(x) + 1000, ymin = min(y), ymax = max(y) + 1000,
            resolution = 1000, crs = "EPSG:25832", vals = NA)
  r[cellFromXY(r, cbind(x + 500, y + 500))] <- value
  r
}
map_args <- list(axes = FALSE, box = FALSE, mar = c(0.5, 0.5, 2.5, 0.5))

# `classes` the value, label and colour of every class, all of them in the
# legend, which goes bottom left: empty there, outside the state.
class_map <- function(tile_id, class, classes, title, file) {
  r <- tile_raster(tile_id, class)
  levels(r) <- data.frame(value = classes$value, label = classes$label)
  coltab(r) <- data.frame(value = classes$value, col = classes$col)
  write_png(file, {
    do.call(plot, c(list(r, all_levels = TRUE,
                         plg = list(title = "", cex = 0.9, x = "bottomleft")), map_args))
    title(title, cex.main = 1.1)
  })
}

# A value on a linear scale from 0 to `max`, higher values in the colour of
# `max`; tiles of `tile_id` without a value in grey, labelled `na_label`.
value_map <- function(tile_id, value, max, unit, cols, na_label, title, file) {
  r <- tile_raster(tile_id, pmin(value, max))
  write_png(file, {
    do.call(plot, c(list(tile_raster(tile_id, 0), col = "#CCCCCC", legend = FALSE), map_args))
    plot(r, col = cols, range = c(0, max), add = TRUE, legend = FALSE)
    title(title, cex.main = 1.1)
    # The legend by hand, bottom left like the classes': a colour bar, and
    # above it the grey of the tiles without a value.
    u <- par("usr"); w <- diff(u[1:2]); h <- diff(u[3:4])
    clip(u[1], u[2], u[3], u[4])  # terra clips to the raster
    x0 <- u[1] + 0.03 * w; x1 <- x0 + 0.025 * w
    y0 <- u[3] + 0.04 * h; y1 <- y0 + 0.2 * h
    rasterImage(as.raster(matrix(rev(cols), ncol = 1)), x0, y0, x1, y1, interpolate = FALSE)
    rect(x0, y0, x1, y1, border = "grey40")
    at <- pretty(c(0, max))
    segments(x1, y0 + at / max * (y1 - y0), x1 + 0.006 * w, col = "grey40")
    text(x1 + 0.01 * w, y0 + at / max * (y1 - y0), adj = 0, cex = 0.8,
         paste(c(head(at, -1), paste("≥", max)), unit))
    rect(x0, y1 + 0.03 * h, x1, y1 + 0.055 * h, col = "#CCCCCC", border = "grey40")
    text(x1 + 0.01 * w, y1 + 0.0425 * h, na_label, adj = 0, cex = 0.8)
  })
}

# Draws `plot` into a PNG and writes it to `file`, like the pages only when
# the image has changed.
write_png <- function(file, plot) {
  tmp <- tempfile(fileext = ".png")
  png(tmp, width = 1100, height = 1000, res = 130)
  plot
  dev.off()
  new <- readBin(tmp, "raw", file.size(tmp))
  if (file.exists(file) && identical(new, readBin(file, "raw", file.size(file)))) {
    cli_alert_success("{.file {file}} is up to date")
  } else {
    writeBin(new, file)
    cli_alert_success("{.file {file}} written")
  }
  unlink(tmp)
}

# The tables the web map (docs/map/index.html) reads, for the tiles measured
# with the current method. No geometry: the map draws each tile from its ID.
#
#   loss.csv     tile_id, loss_m2. What the map is coloured by, so it loads first.
#   details.csv  what a click on a tile shows: the surveys used ("2013 2018
#                2022"), the areas in m², the share observed, the lost trees,
#                the area lost per year and the lost trees per species in the
#                form of tile_results.csv ("2018:23775;2022:104763").
#   other.csv    the tiles of LGLN's grid not measured: why ("s" fewer than
#                two usable surveys, "t" no terrain model, "p" not processed
#                yet) and the usable survey years they have.
#   species.csv  name and colour of every species (species_classes), so the
#                map colours them as the species mosaic does.
#
# Sorted by tile and written only when their content changes, so a run that
# changes a few tiles changes only those lines in git.
write_map_data <- function(cur, epochs, cov, dir) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  cur  <- cur[order(cur$tile_id), ]
  int  <- \(x) { x <- round(as.numeric(x)); ifelse(is.na(x), "", format(x, scientific = FALSE, trim = TRUE)) }
  txt  <- \(x) ifelse(is.na(x), "", x)
  used <- epochs[as.logical(epochs$used) %in% TRUE, c("tile_id", "year")]
  used <- used[!duplicated(used), ]
  years <- tapply(as.integer(used$year), used$tile_id, \(y) paste(sort(y), collapse = " "))
  csv <- \(df) c(paste(names(df), collapse = ","), do.call(paste, c(unname(as.list(df)), sep = ",")))
  other <- cov[!cov$tile_id %in% cur$tile_id, ]
  other <- other[order(other$tile_id), ]
  n_srv <- lengths(strsplit(txt(other$epoch_years), ","))
  tables <- list(
    species.csv = species_classes[c("name", "colour")],
    other.csv = data.frame(
      tile_id = other$tile_id,
      why     = ifelse(n_srv < 2, "s", ifelse(!other$dgm1, "t", "p")),
      years   = gsub(",", " ", txt(other$epoch_years))),
    loss.csv = data.frame(tile_id = cur$tile_id, loss_m2 = int(cur$loss_m2)),
    details.csv = data.frame(
      tile_id        = cur$tile_id,
      years          = txt(as.vector(years[cur$tile_id])),
      forest_m2      = int(cur$forest_m2),
      loss_forest_m2 = int(cur$loss_forest_m2),
      observed_pct   = txt(cur$observed_pct),
      lost_trees     = int(cur$lost_trees),
      loss_by_year   = txt(cur$loss_by_year),
      trees_by_species = txt(cur$trees_by_species)))
  for (f in names(tables)) {
    file  <- file.path(dir, f)
    lines <- csv(tables[[f]])
    new   <- charToRaw(paste0(paste(lines, collapse = "\n"), "\n"))  # LF on every OS
    if (file.exists(file) && identical(new, readBin(file, "raw", file.size(file)))) {
      cli_alert_success("{.file {file}} is up to date")
    } else {
      writeBin(new, file)
      cli_alert_success("{.file {file}} written: {fmt(nrow(tables[[f]]))} rows")
    }
  }
}

if (!file.exists(coverage_file)) {
  cli_alert_warning("No coverage yet ({.file {coverage_file}} is missing): no reports written")
} else {
  pid <- params_id(detection_params)

  cov <- st_read(coverage_file, quiet = TRUE, query = paste(
    "SELECT tile_id, epoch_years, epoch_dates, dgm1, comparable FROM tiles"))
  cov$dgm1       <- as.logical(cov$dgm1)
  cov$comparable <- as.logical(cov$comparable)
  results <- read_table(result_file,
    text = c("tile_id", "status", "epoch_dates", "params", "processed",
             "loss_by_year", "trees_by_year", "trees_by_species"),
    cols = c("tile_id", "status", "epoch_dates", "params", "processed",
             "observed_m2", "forest_m2", "loss_m2", "loss_forest_m2", "lost_trees",
             "loss_by_year", "trees_by_year", "trees_by_species"))
  runs   <- read_table(run_log, text = c("tile_id", "status", "error", "finished"),
                       cols = c("tile_id", "status", "seconds", "error", "finished"))
  epochs <- read_table(epoch_file, text = "tile_id", cols = c("tile_id", "year", "used"))

  # What every processable tile needs (R/status.R), and the tiles done now.
  comp   <- cov[cov$comparable, ]
  state  <- tile_state(comp, results, pid)
  prev   <- results[match(comp$tile_id, results$tile_id), ]
  done   <- comp$tile_id[state == "done"]
  last_run <- runs[!duplicated(runs$tile_id, fromLast = TRUE), ]
  failed <- state == "new" & comp$tile_id %in% last_run$tile_id[last_run$status == "failed"]
  n_comp <- nrow(comp)
  n_done <- length(done)
  latest <- \(x) { x <- x[!is.na(x) & x != ""]; if (length(x)) max(x) else NA }
  updated <- latest(c(results$processed, runs$finished))
  updated <- if (is.na(updated)) "no tile processed yet" else paste("updated", substr(updated, 1, 16))

  # --- status -------------------------------------------------------------------
  method_of <- function(id) {
    f <- file.path(params_dir, paste0(id, ".txt"))
    m <- if (file.exists(f)) tryCatch(eval(parse(f))$method, error = \(e) NULL)
    if (is.null(m)) "?" else as.character(m)
  }
  older <- sort(unique(vapply(unique(prev$params[state == "new_params"]), method_of, "")))
  counts <- c(
    "done" = n_done,
    "to redo: older method" = sum(state == "new_params"),
    "to redo: new LGLN flights" = sum(state == "new_data"),
    "not processed yet" = sum(state == "new" & !failed),
    "failed (tried again next run)" = sum(failed))
  if (length(older)) names(counts)[2] <- paste0("to redo: older method (", paste(older, collapse = ", "), ")")
  counts <- counts[counts > 0 | names(counts) %in% c("done", "not processed yet")]
  tiles <- data.frame(tiles = names(counts), count = fmt(counts),
                      share = vapply(counts, pct, "", n_comp))

  # Per survey year: tiles where that year has an earlier survey to compare
  # with, and of them how many are done (the year used, and not the tile's
  # first survey).
  ep_years <- parse_years(comp$epoch_years)
  y     <- unlist(ep_years)
  tile  <- rep(seq_along(ep_years), lengths(ep_years))
  shows <- duplicated(tile)  # every survey but a tile's first
  used  <- epochs[as.logical(epochs$used) %in% TRUE & epochs$tile_id %in% done, ]
  used  <- used[!duplicated(used[c("tile_id", "year")]), ]
  used  <- used[order(used$tile_id, used$year), ]
  used  <- used[duplicated(used$tile_id), ]
  years <- sort(unique(y[shows]))
  per_year <- data.frame(
    year = years,
    `tiles that can show loss` = fmt(as.vector(table(factor(y[shows], levels = years)))),
    done = fmt(as.vector(table(factor(as.integer(used$year), levels = years)))),
    check.names = FALSE)

  secs <- as.numeric(last_run$seconds[last_run$tile_id %in% done])
  secs <- secs[!is.na(secs)]
  errors <- last_run$error[last_run$tile_id %in% comp$tile_id[failed]]
  errors <- head(sort(table(substr(errors, 1, 160)), decreasing = TRUE), 5)
  flights <- unlist(strsplit(cov$epoch_dates[!is.na(cov$epoch_dates)], ","))

  # The same states on the map, every LGLN tile.
  status_class <- rep(6, nrow(cov))
  status_class[match(comp$tile_id, cov$tile_id)] <-
    ifelse(failed, 5, match(state, c("done", "new_params", "new_data", "new")))
  class_map(cov$tile_id, status_class, data.frame(
    value = 1:6,
    label = c("done", "to redo: older method", "to redo: new flights",
              "not processed yet", "failed", "cannot be processed"),
    col = c("#1B7837", "#F1A340", "#998EC3", "#BDBDBD", "#D7191C", "#EEEEEE")),
    "Processing state per 1 × 1 km tile", "docs/images/status_tiles.png")

  status <- c(
    "# Processing status",
    "",
    paste0(toupper(substr(updated, 1, 1)), substring(updated, 2), " · method ", detection_params$method,
           " · LGLN data up to ", latest(flights)),
    "",
    paste0("**", fmt(n_done), " of ", fmt(n_comp), " tiles done (", pct(n_done, n_comp), ")**"),
    "",
    md_table(tiles),
    "",
    paste0(fmt(n_comp), " of LGLN's ", fmt(nrow(cov)), " tiles (1 km² each) can be processed. ",
           "The others have fewer than two usable surveys (",
           fmt(sum(!cov$comparable & cov$dgm1)), ") or no terrain model (",
           fmt(sum(!cov$dgm1)), ")."),
    "",
    "![Processing state per tile](images/status_tiles.png)",
    "",
    "## Survey years",
    "",
    md_table(per_year),
    "",
    "## Runs",
    "",
    paste0(if (length(secs)) paste0(fmt(median(secs)), " s per tile and worker (median) · ") else "",
           fmt(sum(failed)), " failed"),
    if (length(errors)) c("", md_table(data.frame(error = names(errors),
                                                  tiles = fmt(as.vector(errors))))),
    "")
  write_page(status, status_file, paste(fmt(n_done), "of", fmt(n_comp), "tiles done"))

  # --- results ------------------------------------------------------------------
  cur <- results[results$tile_id %in% done & results$status == "measured", ]
  num <- \(x) sum(as.numeric(x), na.rm = TRUE)

  # The area lost per tile measured with the current method, linear up to 10 ha
  # (in the west, 99 % of tiles are below; the Harz will have more), so little
  # loss shows only faintly.
  value_map(cov$tile_id, as.numeric(cur$loss_m2)[match(cov$tile_id, cur$tile_id)] / 1e4,
            max = 10, unit = "ha", na_label = "not measured",
            cols = colorRampPalette(c("#FFF9F2", viridisLite::magma(5, begin = 0.25,
                                                                    end = 0.9, direction = -1)))(100),
            title = "Canopy lost per 1 × 1 km tile", file = "docs/images/results_loss.png")
  results_page <- c(
    "# Canopy loss: results",
    "",
    paste0(fmt(n_done), " tiles processed (", pct(n_done, n_comp), " of the state) · ", updated),
    "")
  if (!nrow(cur)) {
    results_page <- c(results_page, "No tile processed with the current method yet.", "")
  } else {
    forest <- num(cur$forest_m2)
    totals <- data.frame(
      ` ` = c("area observed", "canopy at the start", "lost area", "canopy lost",
              "lost trees"),
      value = c(ha(num(cur$observed_m2)), ha(forest), ha(num(cur$loss_m2)),
                pct(num(cur$loss_forest_m2), forest), fmt(num(cur$lost_trees))),
      check.names = FALSE)

    loss_year  <- parse_counts(cur$loss_by_year)
    trees_year <- parse_counts(cur$trees_by_year)
    ly <- sort(union(names(loss_year), names(trees_year)))
    get0 <- \(v, k) ifelse(is.na(v[k]), 0, v[k])
    by_year <- data.frame(year = ly, `lost area (ha)` = fmt(get0(loss_year, ly) / 1e4),
                          `lost trees` = fmt(get0(trees_year, ly)), check.names = FALSE)

    # Every species of the map, those with no lost tree yet included.
    sp <- parse_counts(cur$trees_by_species)
    names_all <- union(species_classes$name, names(sp))
    sp <- sort(setNames(ifelse(is.na(sp[names_all]), 0, sp[names_all]), names_all),
               decreasing = TRUE)
    names(sp)[names(sp) == "none"] <- "NA"  # outside the species map
    by_species <- data.frame(species = names(sp), trees = fmt(sp),
                             share = vapply(sp, pct, "", sum(sp)))

    results_page <- c(results_page,
      if (n_done < n_comp)
        c("> Partial result: only the tiles processed so far, not a statewide figure.", ""),
      md_table(totals),
      "",
      "![Canopy lost per tile](images/results_loss.png)",
      "",
      "Every tile's figures: [interactive map](https://wiesehahn.github.io/canopy_loss_detection/map/).",
      "",
      "## By year",
      "",
      "Year of the first survey that shows the loss.",
      "",
      md_table(by_year),
      if (length(sp)) c("", "## Lost trees by species", "", md_table(by_species)),
      "")
  }
  write_page(results_page, results_file, paste(fmt(nrow(cur)), "measured tiles"))

  # --- web map data -------------------------------------------------------------
  write_map_data(cur, epochs, cov, map_dir)
}
