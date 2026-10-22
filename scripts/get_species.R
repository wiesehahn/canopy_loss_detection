# The dominant tree species map of Germany for 2018 (categorical, 10 m,
# EPSG:3035; Göttingen Research Online, doi:10.25625/XOZAGY/XF5TU2). Each lost
# tree takes the species most of its crown lies on (R/trees.R), and the species
# decides the tree-top window. 2018 is the earliest year: later maps leave out
# areas disturbed since. Downloaded once (about 610 MB); tiles read their part
# and reproject it on the fly.
#
# Classes: 0 none, 1 alder, 2 ash, 3 beech, 4 birch, 5 Douglas fir, 6 fir,
# 7 larch, 8 maple, 9 oak, 10 other broadleaf, 11 pine, 12 spruce.
source("R/params.R")
url      <- "https://data.goettingen-research-online.de/api/access/datafile/:persistentId?persistentId=doi:10.25625/XOZAGY/XF5TU2"
out_file <- detection_params$species

tmp <- paste0(out_file, ".part")
message("downloading tree species map")
download.file(url, tmp, mode = "wb", quiet = TRUE)
invisible(file.rename(tmp, out_file))
message("written to ", out_file)
