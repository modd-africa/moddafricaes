#' Generate and Export an Elevation Map for a Given Country
#'
#' Downloads GADM boundary and 30-second elevation data for a specified country,
#' crops and masks the DEM to the country boundary, plots an elevation map using
#' ggplot2, exports the result as a GeoTIFF, and returns metadata.
#'
#' @param country_code Character. ISO 3-letter country code (e.g., \code{"TZA"} for Tanzania).
#' @param output_file Character. Output filename for the GeoTIFF raster. Defaults to
#'   \code{"<country_code>_elevation.tif"}.
#' @param plot Logical. Whether to display the ggplot2 elevation map. Defaults to \code{TRUE}.
#' @param data_path Character. Directory path for downloading and caching geodata files.
#'   Defaults to \code{tempdir()}.
#' @param map_title Character. Title for the elevation map plot. Defaults to
#'   \code{"Elevation Map of <country_code>"}.
#'
#' @return A named list with the following elements:
#' \describe{
#'   \item{\code{raster}}{A \code{SpatRaster} object of the cropped and masked DEM.}
#'   \item{\code{crs}}{The coordinate reference system of the output raster.}
#'   \item{\code{extent}}{The spatial extent of the output raster.}
#'   \item{\code{output_file}}{The full path to the exported GeoTIFF file.}
#'   \item{\code{plot}}{The \code{ggplot} object (if \code{plot = TRUE}), otherwise \code{NULL}.}
#' }
#'
#' @importFrom terra crop mask writeRaster crs ext
#' @importFrom geodata gadm elevation_30s
#' @importFrom ggplot2 ggplot aes geom_raster scale_fill_viridis_c coord_fixed theme_void ggtitle
#'
#' @examples
#' \dontrun{
#' result <- elevation_map("TZA")
#' result <- elevation_map("KEN", output_file = "kenya_dem.tif", map_title = "Kenya Elevation")
#' }
#'
#' @export
get_elevation <- function(
    country_code,
    output_file  = NULL,
    plot         = TRUE,
    data_path    = tempdir(),
    map_title    = NULL
) {

  # --- Input validation -------------------------------------------------------
  if (!is.character(country_code) || nchar(country_code) != 3) {
    stop("`country_code` must be a 3-letter ISO country code (e.g., 'TZA').")
  }

  country_code <- toupper(country_code)

  if (is.null(output_file)) {
    output_file <- paste0(tolower(country_code), "_elevation.tif")
  }

  if (is.null(map_title)) {
    map_title <- paste("Elevation Map of", country_code)
  }

  # --- Download data ----------------------------------------------------------
  message("Downloading country boundary for: ", country_code)
  boundary <- geodata::gadm(country = country_code, level = 0, path = data_path)

  message("Downloading 30s elevation data for: ", country_code)
  dem_raw  <- geodata::elevation_30s(country = country_code, path = data_path)

  # --- Process DEM ------------------------------------------------------------
  dem_cropped <- terra::crop(dem_raw, boundary)
  dem_masked  <- terra::mask(dem_cropped, boundary)

  # --- Build ggplot2 map ------------------------------------------------------
  dem_df <- as.data.frame(dem_masked, xy = TRUE)
  colnames(dem_df)[3] <- "elevation"

  p <- ggplot2::ggplot(dem_df) +
    ggplot2::geom_raster(ggplot2::aes(x = x, y = y, fill = elevation)) +
    ggplot2::scale_fill_viridis_c(na.value = NA) +
    ggplot2::coord_fixed() +
    ggplot2::theme_void() +
    ggplot2::ggtitle(map_title)

  if (plot) print(p)

  # --- Export raster ----------------------------------------------------------
  message("Writing raster to: ", output_file)
  terra::writeRaster(
    dem_masked,
    filename  = output_file,
    filetype  = "GTiff",
    overwrite = TRUE
  )

  # --- Return metadata --------------------------------------------------------
  list(
    raster      = dem_masked,
    crs         = terra::crs(dem_masked),
    extent      = terra::ext(dem_masked),
    output_file = normalizePath(output_file, mustWork = FALSE),
    plot        = if (plot) p else NULL
  )
}
