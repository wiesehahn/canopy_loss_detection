# What each tile needs, judged from what it was made from and what it would be
# made from today. Shared by process_tiles.R, which acts on it, and
# write_reports.R, which reports it, so the two cannot disagree.
#
#   cov      tile_id and epoch_dates, as in data/lgln_coverage.gpkg
#   results  tile_id, epoch_dates and params, as in data/tile_results.csv
#   pid      params_id() of the settings now (R/params.R)
#
# One value per row of `cov`:
#   "new"         not done yet
#   "new_data"    done, but LGLN has published a new or repeated flight since
#   "new_params"  done with other settings
#   "done"        nothing to do
tile_state <- function(cov, results, pid) {
  prev  <- results[match(cov$tile_id, results$tile_id), , drop = FALSE]
  state <- rep("done", nrow(cov))
  state[which(prev$params != pid)] <- "new_params"
  state[which(prev$epoch_dates != cov$epoch_dates)] <- "new_data"
  state[is.na(prev$tile_id)] <- "new"
  state
}
