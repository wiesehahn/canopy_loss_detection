# Installs the packages this project needs, if they are missing.
# Run from the project root: source("install.R"). run.R does this itself.

local({
  cran <- c("terra", "sf", "lidR", "gdalraster", "viridisLite", "cli", "curl", "remotes")
  rvtr <- "wiesehahn/rvtr@55a3b00"   # older commits put the autumn 2025 bDOM 40 m too high

  missing <- cran[!vapply(cran, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) {
    message("Installing ", paste(missing, collapse = ", "))
    install.packages(missing)
  }

  if (!requireNamespace("rvtr", quietly = TRUE)) {
    message("Installing ", rvtr)
    remotes::install_github(rvtr)
  } else {
    sha <- packageDescription("rvtr")$RemoteSha
    pinned <- sub(".*@", "", rvtr)
    if (is.null(sha) || !startsWith(sha, pinned))
      warning("rvtr is installed from commit ", if (is.null(sha)) "unknown" else substr(sha, 1, 7),
              ", tested with ", pinned, ". If it is older: remotes::install_github(\"", rvtr, "\")",
              call. = FALSE)
  }
})
