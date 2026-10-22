# LGLN's tile indexes: one GeoJSON per product, a feature per tile and flight.
# scripts/get_lgln_coverage.R builds data/lgln_coverage.gpkg from them, and
# run.R rebuilds it when they change.

lgln_index_url <- c(
  dom1 = "https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/dom1/lgln-opengeodata-dom1.geojson",
  bdom = "https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/bdom20/lgln-opengeodata-bdom20.geojson",
  dgm1 = "https://arcgis-geojson.s3.eu-de.cloud-object-storage.appdomain.cloud/dgm1/lgln-opengeodata-dgm1.geojson")

# The indexes' ETags, a checksum of their content, from a header request only:
# when one differs from the ETags the coverage was built from, LGLN has
# published new or changed tiles. NULL if the server cannot be reached.
lgln_index_state <- function() {
  tryCatch({
    etag <- vapply(lgln_index_url, \(u) {
      h <- curlGetHeaders(u)
      e <- grep("^etag:", h, ignore.case = TRUE, value = TRUE)
      trimws(sub("^etag:", "", e[length(e)], ignore.case = TRUE))
    }, "")
    data.frame(index = names(lgln_index_url), etag = unname(etag))
  }, error = \(e) NULL)
}

# TRUE if the coverage file is missing, or was built from other index content
# than LGLN serves now. `state_file` holds the ETags of the last build; offline,
# the coverage counts as current.
lgln_coverage_outdated <- function(coverage_file, state_file) {
  if (!file.exists(coverage_file) || !file.exists(state_file)) return(TRUE)
  now <- lgln_index_state()
  if (is.null(now)) {
    message("LGLN tile indexes not reachable; keeping the coverage as it is")
    return(FALSE)
  }
  !identical(read.csv(state_file)$etag, now$etag)
}
