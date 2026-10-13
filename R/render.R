# Drawing a loss map. Shared by the tile images here and the plot images in
# lidar-biodiversity-plots, so the same colour means the same thing in both
# whenever they are given the same year_span. terra and rvtr are the caller's
# to load.

# The loss years over a hillshade of `dsm`, written to `out_path`. The colour of
# a year is fixed by `year_span` rather than by the years this place happens to
# hold, so the same colour means the same year in every image. Codes rather
# than years, because a raster colour table is indexed 0-255. Cells with no
# loss go white, the identity of a multiply blend, so the shading below them
# comes through untouched.
render_loss <- function(year, dsm, out_path, year_span) {
  n <- diff(year_span) + 1L
  code <- year - year_span[1] + 1L
  coltab(code) <- data.frame(
    value = seq_len(n),
    col = viridisLite::plasma(n, begin = 0, end = 0.9))

  # the change is read at its own grid, but shown at the shading's resolution
  year_rgb <- code |>
    colorize(to = "rgb") |>
    subst(NA, 255) |>
    resample(dsm, method = "near") |>
    mask(dsm)

  shade <- dsm |>
    rvt_smooth(radius = 1) |>
    rvt_asvf()

  year_rgb |>
    rvt_stack(range = c(0, 255)) |>
    rvt_blend(shade, "multiply", opacity = 0.6,
              range = rvt_range(shade, pct = c(1, 99))) |>
    rvt_render(out_path, overwrite = TRUE)
}
