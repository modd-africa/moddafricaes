#' Get the bounding box of a spatial file
#'
#' Reads a spatial file from `path`, reprojects it to `crs`, and returns
#' its bounding box in Copernicus CDS order (N, W, S, E).
#'
#' Supports:
#' - Shapefiles and any other source `sf::st_read()` accepts, including
#'   GDAL virtual paths like `"/vsizip/<archive.zip>/<file.shp>"`.
#' - `.rds` files containing an `sf` or `sfc` object (read with `readRDS()`).
#'
#' @param path Path to the spatial file (`.shp`, `.rds`, `/vsizip/...`, etc.).
#' @param crs  Target CRS as an EPSG code.
#'
#' @return Named numeric vector of length 4 in CDS order: `c(N, W, S, E)`.
#' @export
#'
#' @examples
#' \dontrun{
#' get_bounding_box("/vsizip/data-acquisition/utilities/province26.zip/provinces26/Province26.shp")
#' get_bounding_box("data-acquisition/utilities/province26.rds")
#' }
get_bounding_box <- function(path, crs = 4326) {
  stopifnot(is.character(path), length(path) == 1L)

  ext <- tolower(tools::file_ext(path))

  shp <- if (ext == "rds") {
    obj <- readRDS(path)
    if (!inherits(obj, c("sf", "sfc"))) {
      stop("RDS file does not contain an 'sf' or 'sfc' object: ", path)
    }
    obj
  } else {
    sf::st_read(path, quiet = TRUE)
  }

  shp <- sf::st_transform(shp, crs)
  bb  <- sf::st_bbox(shp)
  c(N = unname(bb[["ymax"]]),
    W = unname(bb[["xmin"]]),
    S = unname(bb[["ymin"]]),
    E = unname(bb[["xmax"]]))
}

# Run with a sample file when invoked as a script.
if (sys.nframe() == 0L) {
  shp  <- "/vsizip/data-acquisition/utilities/province26.zip/provinces26/Province26.shp"
  bbox <- get_bounding_box(shp)
  cat("Bounding box (N, W, S, E for CDS):\n")
  cat(sprintf("c(%.5f, %.5f, %.5f, %.5f)\n",
              bbox[["N"]], bbox[["W"]], bbox[["S"]], bbox[["E"]]))
}
