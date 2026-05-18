# Download ERA5-Land hourly NetCDFs from the Copernicus CDS for a bounding box.

#' Extract ERA5-Land hourly data for a bounding box
#'
#' Downloads hourly ERA5-Land reanalysis NetCDFs from the Copernicus Climate
#' Data Store (CDS), one file per (year, month), into
#' `<output_dir>/<year>/<label>_<year><MM>.nc`. A `CDS_API_KEY` environment
#' variable must be set, or `cds_key` passed explicitly.
#'
#' The function is resume-safe: existing readable NetCDFs are skipped, and
#' truncated files are re-downloaded. Failures for a single month are logged
#' and the loop continues.
#'
#' @param bbox       Numeric vector of length 4 in CDS order `c(N, W, S, E)`
#'   (e.g. the return value of [get_bounding_box()]).
#' @param years      Integer vector of years to download.
#' @param output_dir Directory to stage NetCDFs under. Created if needed.
#' @param variables  Character vector of ERA5-Land variable short names.
#' @param months     Integer months in `1:12` to download.
#' @param label      File-name prefix used for each NetCDF.
#' @param dataset    CDS `dataset_short_name`.
#' @param cds_key    Optional CDS API key; defaults to `Sys.getenv("CDS_API_KEY")`.
#' @param time_out   Per-request timeout in seconds passed to [ecmwfr::wf_request()].
#'
#' @return Character vector of NetCDF paths attempted (invisibly).
#' @export
#'
#' @examples
#' \dontrun{
#' bbox <- get_bounding_box("/vsizip/path/to/area.zip/area.shp")
#' extract_era5land(
#'   bbox       = bbox,
#'   years      = 2020:2021,
#'   output_dir = "data/climate/era5land/input/nc"
#' )
#' }
extract_era5land <- function(bbox,
                             years,
                             output_dir,
                             variables = c(
                               "surface_solar_radiation_downwards",
                               "2m_dewpoint_temperature",
                               "2m_temperature",
                               "total_precipitation",
                               "10m_u_component_of_wind",
                               "10m_v_component_of_wind"
                             ),
                             months   = 1:12,
                             label    = "era5land",
                             dataset  = "reanalysis-era5-land",
                             cds_key  = Sys.getenv("CDS_API_KEY"),
                             time_out = 7200) {
  stopifnot(
    is.numeric(bbox), length(bbox) == 4L,
    is.numeric(years), length(years) >= 1L,
    is.character(output_dir), length(output_dir) == 1L,
    is.character(variables), length(variables) >= 1L,
    is.numeric(months), all(months %in% 1:12),
    nzchar(cds_key)
  )

  ecmwfr::wf_set_key(key = cds_key)

  area <- unname(as.numeric(bbox))
  paths <- character()

  for (year in years) {
    year_dir <- file.path(output_dir, year)
    dir.create(year_dir, recursive = TRUE, showWarnings = FALSE)

    for (month in months) {
      month_str <- sprintf("%02d", month)
      n_days <- lubridate::days_in_month(
        lubridate::ymd(sprintf("%d-%02d-01", year, month))
      )

      target_name <- sprintf("%s_%d%s.nc", label, year, month_str)
      nc_file <- file.path(year_dir, target_name)
      paths <- c(paths, nc_file)

      if (file.exists(nc_file)) {
        is_readable <- tryCatch(
          {
            terra::rast(nc_file)
            TRUE
          },
          error = function(e) FALSE
        )
        if (is_readable) {
          message(sprintf("Skipping download: %s already exists",
                          basename(nc_file)))
          next
        }
        message(sprintf("Re-downloading: %s exists but is unreadable",
                        basename(nc_file)))
        unlink(nc_file)
      }

      request <- list(
        dataset_short_name = dataset,
        variable           = variables,
        data_format        = "netcdf",
        download_format    = "unarchived",
        year               = as.character(year),
        month              = month_str,
        day                = sprintf("%02d", seq_len(n_days)),
        time               = sprintf("%02d:00", 0:23),
        area               = area,
        target             = target_name
      )

      tryCatch(
        ecmwfr::wf_request(
          request  = request,
          path     = year_dir,
          time_out = time_out,
          verbose  = TRUE
        ),
        error = function(e) {
          message(sprintf("Request failed for %d-%s: %s",
                          year, month_str, conditionMessage(e)))
        }
      )
    }
  }

  invisible(paths)
}
