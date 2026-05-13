# Transform hourly ERA5-Land NetCDFs into per-year Parquet files,
# joining a DEM-derived elevation column onto each ERA5 grid cell.

# ---- column / schema contract --------------------------------------------

.expected_cols <- c(
  "timestamp", "year", "month", "day", "hour",
  "lat", "lon", "elevation_m",
  "t2m_celsius", "tp_mm",
  "wind_speed_mps", "relative_humidity_pct", "vpd_hpa",
  "ssrd_wm2"
)

.expected_schema <- function() {
  arrow::schema(
    timestamp             = arrow::timestamp("us", "UTC"),
    year                  = arrow::int32(),
    month                 = arrow::int32(),
    day                   = arrow::int32(),
    hour                  = arrow::int32(),
    lat                   = arrow::float32(),
    lon                   = arrow::float32(),
    elevation_m           = arrow::float32(),
    t2m_celsius           = arrow::float32(),
    tp_mm                 = arrow::float32(),
    wind_speed_mps        = arrow::float32(),
    relative_humidity_pct = arrow::float32(),
    vpd_hpa               = arrow::float32(),
    ssrd_wm2              = arrow::float32()
  )
}

.default_metadata <- function(version) {
  c(
    timestamp_convention   = "end_of_period_utc",
    timestamp_meaning      = "value at hour T describes the hourly interval ending at T (UTC). Per-day chunking forces hour-0 to 0 for de-accumulated vars (tp, ssrd) at the day boundary.",
    t2m_celsius_meaning    = "2 m air temperature in degC; raw t2m (K) - 273.15.",
    tp_mm_meaning          = "per-hour precipitation in mm; de-cumulated from raw tp (m, cumulative since 00 UTC); hour 0 forced to 0.",
    ssrd_wm2_meaning       = "per-hour mean downward shortwave flux at the surface in W/m^2; de-cumulated from raw ssrd (J/m^2, cumulative since 00 UTC); hour 0 forced to 0.",
    elevation_m_meaning    = "Surface elevation (m); DEM averaged onto the ERA5-Land 0.1 deg grid; ERA5 cells with no DEM coverage are filled by nearest-neighbour from the closest valued cell.",
    wind_speed_mps_meaning = "sqrt(u10^2 + v10^2) at 10 m, in m/s.",
    relative_humidity_pct_meaning = "Magnus form: 100 * es(d2m) / es(t2m), es(T) = 6.112 * exp(17.67*T / (T + 243.5)). May very slightly exceed 100 due to f32 noise when t2m ~ d2m.",
    vpd_hpa_meaning        = "Vapour pressure deficit: es(t2m) - es(d2m) (hPa). Same Magnus form; may be slightly negative due to f32 noise when t2m ~ d2m.",
    source_product         = "CDS reanalysis-era5-land hourly",
    grid_resolution_deg    = "0.1",
    land_only              = "true (cells with NA in any raw var at the first hour of each day are dropped via valid mask)",
    pipeline_version       = version
  )
}

# ---- per-variable helpers ------------------------------------------------

.layers_for_var <- function(r, v) {
  var_of_layer <- sub("_valid_time=.*", "", names(r))
  ts_num       <- as.numeric(sub(".*_valid_time=", "", names(r)))
  keep <- which(var_of_layer == v)
  list(idx = keep[order(ts_num[keep])],
       ts  = ts_num[keep][order(ts_num[keep])])
}

# ssrd (J/m^2, cumulative since 00 UTC) -> per-hour mean flux (W/m^2).
# Hour=1 override exactly recovers the first delta of a fresh accumulation
# window; hour=0 is the day-chunk boundary (no prior cumulative loaded) and
# is forced to 0. Forcing hour-0 to 0 is exact only where 00 UTC is night
# (e.g. central Africa); revisit for AOIs where 00 UTC is daylight.
.ssrd_to_wm2 <- function(m_ssrd, timestamps) {
  hrs  <- lubridate::hour(timestamps)
  n    <- ncol(m_ssrd)
  flux <- matrix(NA_real_, nrow = nrow(m_ssrd), ncol = n)
  if (n >= 2) {
    flux[, 2:n] <- (m_ssrd[, 2:n, drop = FALSE] -
                      m_ssrd[, 1:(n - 1), drop = FALSE]) / 3600
  }
  is_hr1 <- hrs == 1
  if (any(is_hr1)) flux[, is_hr1] <- m_ssrd[, is_hr1, drop = FALSE] / 3600
  flux[!is.na(flux) & flux < 0 & flux > -1e-2] <- 0
  if (any(flux < -1e-2, na.rm = TRUE)) {
    warning(sprintf("ssrd_to_wm2: %d cells below -1e-2 W/m^2 (min %.3g)",
                    sum(flux < -1e-2, na.rm = TRUE),
                    min(flux, na.rm = TRUE)))
  }
  if (hrs[1] == 0) flux[is.na(flux[, 1]), 1] <- 0
  flux
}

# tp (m, cumulative since 00 UTC) -> per-hour precipitation (mm).
.tp_to_hourly_mm <- function(m_tp, timestamps) {
  hrs <- lubridate::hour(timestamps)
  n   <- ncol(m_tp)
  prec <- matrix(NA_real_, nrow = nrow(m_tp), ncol = n)
  if (n >= 2) {
    prec[, 2:n] <- (m_tp[, 2:n, drop = FALSE] -
                      m_tp[, 1:(n - 1), drop = FALSE]) * 1000
  }
  is_hr1 <- hrs == 1
  if (any(is_hr1)) prec[, is_hr1] <- m_tp[, is_hr1, drop = FALSE] * 1000
  prec[!is.na(prec) & prec < 0 & prec > -1e-4] <- 0
  if (any(prec < -1e-4, na.rm = TRUE)) {
    warning(sprintf("tp_to_hourly_mm: %d cells below -1e-4 mm (min %.3g)",
                    sum(prec < -1e-4, na.rm = TRUE),
                    min(prec, na.rm = TRUE)))
  }
  if (hrs[1] == 0) prec[is.na(prec[, 1]), 1] <- 0
  prec
}

# Resample a DEM onto the ERA5-Land grid (mean) and nearest-neighbour-fill
# any ERA5 cells with no DEM coverage so downstream joins never lose rows.
.build_elevation_vector <- function(dem_path, era5_template_rast) {
  dem <- terra::rast(dem_path)
  ref <- era5_template_rast
  dem_cropped <- terra::crop(dem, terra::ext(ref) + 0.05)
  dem_on_era5 <- terra::resample(dem_cropped, ref, method = "average")

  vals     <- terra::values(dem_on_era5)[, 1]
  na_idx   <- which(is.na(vals))
  good_idx <- which(!is.na(vals))
  if (length(na_idx) > 0 && length(good_idx) > 0) {
    coords <- terra::xyFromCell(dem_on_era5,
                                seq_len(terra::ncell(dem_on_era5)))
    for (i in na_idx) {
      d2 <- (coords[good_idx, 1] - coords[i, 1])^2 +
        (coords[good_idx, 2] - coords[i, 2])^2
      vals[i] <- vals[good_idx[which.min(d2)]]
    }
    message(sprintf(
      "Elevation: filled %d water/edge cells via nearest neighbour",
      length(na_idx)
    ))
  }
  vals
}

# Build one day's data.frame (24 hours x land cells x 13 cols).
.process_day <- function(r, vidx, day_mask, coords_full, elev_full) {
  pick_idx <- function(v) vidx[[v]]$idx[day_mask]
  pick_ts  <- function(v) vidx[[v]]$ts[day_mask]

  timestamps <- as.POSIXct(pick_ts("d2m"), origin = "1970-01-01", tz = "UTC")
  n_hours    <- length(timestamps)

  m_t2m  <- terra::values(r[[pick_idx("t2m")]])
  m_d2m  <- terra::values(r[[pick_idx("d2m")]])
  m_tp   <- .tp_to_hourly_mm(terra::values(r[[pick_idx("tp")]]), timestamps)
  m_u10  <- terra::values(r[[pick_idx("u10")]])
  m_v10  <- terra::values(r[[pick_idx("v10")]])
  m_ssrd <- .ssrd_to_wm2(terra::values(r[[pick_idx("ssrd")]]), timestamps)

  if (max(m_t2m, na.rm = TRUE) > 100) m_t2m <- m_t2m - 273.15
  if (max(m_d2m, na.rm = TRUE) > 100) m_d2m <- m_d2m - 273.15

  valid <- !is.na(m_t2m[, 1]) & !is.na(m_d2m[, 1]) &
    !is.na(m_tp[,  1]) & !is.na(m_u10[, 1]) &
    !is.na(m_v10[, 1]) & !is.na(m_ssrd[, 1])
  m_t2m  <- m_t2m[valid, , drop = FALSE]
  m_d2m  <- m_d2m[valid, , drop = FALSE]
  m_tp   <- m_tp[valid, , drop = FALSE]
  m_u10  <- m_u10[valid, , drop = FALSE]
  m_v10  <- m_v10[valid, , drop = FALSE]
  m_ssrd <- m_ssrd[valid, , drop = FALSE]
  coords <- coords_full[valid, , drop = FALSE]
  v_elev <- elev_full[valid]
  n_pix  <- nrow(coords)

  m_es  <- 6.112 * exp((17.67 * m_t2m) / (m_t2m + 243.5))
  m_ea  <- 6.112 * exp((17.67 * m_d2m) / (m_d2m + 243.5))
  m_rh  <- 100 * m_ea / m_es
  m_vpd <- m_es - m_ea
  m_ws  <- sqrt(m_u10^2 + m_v10^2)

  df <- data.frame(
    timestamp             = rep(timestamps, each = n_pix),
    lon                   = rep(coords[, 1], times = n_hours),
    lat                   = rep(coords[, 2], times = n_hours),
    elevation_m           = round(rep(v_elev, times = n_hours), 1),
    t2m_celsius           = round(as.vector(m_t2m), 3),
    tp_mm                 = round(as.vector(m_tp),  3),
    wind_speed_mps        = round(as.vector(m_ws),  3),
    relative_humidity_pct = round(as.vector(m_rh),  2),
    vpd_hpa               = round(as.vector(m_vpd), 3),
    ssrd_wm2              = round(as.vector(m_ssrd), 2),
    stringsAsFactors      = FALSE
  )
  df$year  <- lubridate::year(df$timestamp)
  df$month <- lubridate::month(df$timestamp)
  df$day   <- lubridate::mday(df$timestamp)
  df$hour  <- lubridate::hour(df$timestamp)
  df[, .expected_cols]
}

.parquet_is_readable <- function(path) {
  if (!file.exists(path)) return(FALSE)
  ok <- tryCatch(
    {
      arrow::open_dataset(path)
      TRUE
    },
    error = function(e) FALSE
  )
  if (!ok) {
    message(sprintf("Removing unreadable Parquet: %s", path))
    unlink(path)
  }
  ok
}

.year_parquet_is_complete <- function(path, min_rows) {
  if (!.parquet_is_readable(path)) return(FALSE)
  n <- tryCatch(nrow(arrow::open_dataset(path)),
                error = function(e) 0)
  if (n < min_rows) {
    message(sprintf("Removing partial year Parquet (%s rows): %s",
                    format(n, big.mark = ","), path))
    unlink(path)
    return(FALSE)
  }
  TRUE
}

.process_month_to_daily <- function(yr, mo, ctx) {
  nc_path <- file.path(ctx$input_dir, yr, sprintf(ctx$nc_tmpl, yr, mo))
  if (!file.exists(nc_path)) {
    message(sprintf("SKIP %d-%02d: input NC missing (%s)", yr, mo, nc_path))
    return(invisible(NULL))
  }
  daily_dir <- file.path(ctx$output_dir, "_daily", yr)
  dir.create(daily_dir, recursive = TRUE, showWarnings = FALSE)

  n_days <- lubridate::days_in_month(
    lubridate::ymd(sprintf("%d-%02d-01", yr, mo))
  )
  expected_paths <- file.path(
    daily_dir,
    sprintf("%d%02d%02d.parquet", yr, mo, seq_len(n_days))
  )
  if (all(vapply(expected_paths, .parquet_is_readable, logical(1)))) {
    message(sprintf("Skip %d-%02d: all %d days already staged",
                    yr, mo, n_days))
    return(invisible(NULL))
  }

  r <- terra::rast(nc_path)
  if (is.null(ctx$elev$value)) {
    ctx$elev$value <- .build_elevation_vector(ctx$dem_tif, r[[1]])
    message(sprintf("Elevation vector: %d cells, range [%.1f, %.1f] m",
                    length(ctx$elev$value),
                    min(ctx$elev$value, na.rm = TRUE),
                    max(ctx$elev$value, na.rm = TRUE)))
  }
  stopifnot(length(ctx$elev$value) == terra::ncell(r))

  vars_present <- unique(sub("_valid_time=.*", "", names(r)))
  for (v in c("ssrd", "d2m", "t2m", "tp", "u10", "v10")) {
    stopifnot(v %in% vars_present)
  }
  vidx <- list(
    d2m  = .layers_for_var(r, "d2m"),
    t2m  = .layers_for_var(r, "t2m"),
    tp   = .layers_for_var(r, "tp"),
    u10  = .layers_for_var(r, "u10"),
    v10  = .layers_for_var(r, "v10"),
    ssrd = .layers_for_var(r, "ssrd")
  )
  ts_ref <- vidx$d2m$ts
  for (v in c("t2m", "tp", "u10", "v10", "ssrd")) {
    stopifnot(identical(vidx[[v]]$ts, ts_ref))
  }
  ts_dates <- as.Date(as.POSIXct(ts_ref, origin = "1970-01-01", tz = "UTC"))
  coords_full <- terra::xyFromCell(r[[1]], seq_len(terra::ncell(r)))

  message(sprintf("Month %d-%02d: %d days, %d cells",
                  yr, mo, n_days, terra::ncell(r)))
  for (d in seq_len(n_days)) {
    out_path <- expected_paths[d]
    if (.parquet_is_readable(out_path)) next

    target_date <- lubridate::ymd(sprintf("%d-%02d-%02d", yr, mo, d))
    day_mask <- ts_dates == target_date
    n_layers <- sum(day_mask)
    if (n_layers == 0) {
      message(sprintf("  day %02d: no layers match, skipping", d))
      next
    }
    if (n_layers != 24) {
      message(sprintf("  day %02d: %d layers (expected 24), skipping",
                      d, n_layers))
      next
    }

    t0 <- Sys.time()
    df <- tryCatch(
      .process_day(r, vidx, day_mask, coords_full, ctx$elev$value),
      error = function(e) {
        message(sprintf("  day %02d FAIL: %s", d, conditionMessage(e)))
        NULL
      }
    )
    if (is.null(df)) next
    stopifnot(identical(names(df), .expected_cols))

    tbl <- arrow::as_arrow_table(df, schema = .expected_schema())
    tbl$metadata <- as.list(ctx$metadata)
    arrow::write_parquet(tbl, out_path, compression = ctx$compression)
    message(sprintf("  day %02d: %s rows, %.1fs, %.2f MB",
                    d, format(nrow(df), big.mark = ","),
                    as.numeric(Sys.time() - t0, units = "secs"),
                    file.size(out_path) / 1024^2))
    rm(df); gc(verbose = FALSE)
  }
}

# Stream all daily Parquets for a year into one year-level Parquet so peak
# RAM stays at one day's worth.
.consolidate_year <- function(yr, ctx) {
  daily_dir <- file.path(ctx$output_dir, "_daily", yr)
  year_path <- file.path(
    ctx$output_dir,
    sprintf(ctx$out_tmpl, yr, ctx$version)
  )

  daily_files <- sort(list.files(daily_dir, pattern = "\\.parquet$",
                                 full.names = TRUE))
  if (length(daily_files) == 0) {
    message(sprintf("Year %d: no daily files in %s", yr, daily_dir))
    return(invisible(NULL))
  }
  expected_n <- ifelse(lubridate::leap_year(yr), 366L, 365L)
  if (length(daily_files) != expected_n) {
    message(sprintf("Year %d: %d/%d daily files present; staging dir kept.",
                    yr, length(daily_files), expected_n))
    return(invisible(NULL))
  }

  message(sprintf("Consolidating %d (%d daily files) -> %s",
                  yr, length(daily_files), basename(year_path)))
  t0 <- Sys.time()

  first_tbl <- arrow::read_parquet(daily_files[1], as_data_frame = FALSE)
  stopifnot(identical(names(first_tbl), .expected_cols))
  props <- arrow::ParquetWriterProperties$create(
    column_names = names(first_tbl),
    compression  = ctx$compression
  )
  sink   <- arrow::FileOutputStream$create(year_path)
  writer <- arrow::ParquetFileWriter$create(
    schema     = first_tbl$schema,
    sink       = sink,
    properties = props
  )
  writer$WriteTable(first_tbl, chunk_size = 65536L)
  rm(first_tbl); gc(verbose = FALSE)

  for (i in seq_along(daily_files)[-1]) {
    tbl <- arrow::read_parquet(daily_files[i], as_data_frame = FALSE)
    stopifnot(identical(names(tbl), .expected_cols))
    writer$WriteTable(tbl, chunk_size = 65536L)
    rm(tbl); gc(verbose = FALSE)
  }
  writer$Close()
  sink$close()

  if (!.parquet_is_readable(year_path)) {
    stop(sprintf("Year file %s failed readability check", year_path))
  }
  unlink(daily_dir, recursive = TRUE)
  message(sprintf("%.1fs, %.1f MB",
                  as.numeric(Sys.time() - t0, units = "secs"),
                  file.size(year_path) / 1024^2))
  invisible(year_path)
}

# ---- public entry point --------------------------------------------------

#' Transform ERA5-Land hourly NetCDFs into per-year Parquet
#'
#' Reads ERA5-Land hourly NetCDFs (one per (year, month)), de-accumulates
#' `tp` and `ssrd`, derives wind speed, relative humidity, VPD and Celsius
#' temperature, joins a DEM-derived elevation column onto the ERA5 0.1 deg
#' grid, and writes one Parquet file per year. Intermediate per-day Parquets
#' are staged under `<output_dir>/_daily/<year>/` and removed after the year
#' file passes a readability check.
#'
#' The pipeline is resume-safe: unreadable Parquets are deleted and
#' re-generated, partial year files (below `min_year_rows`) are discarded
#' before regeneration, and per-day failures are logged and skipped.
#'
#' Hour-0 of each day is forced to 0 for the de-accumulated `tp` and `ssrd`
#' columns. This is exact only where 00 UTC falls during night (e.g. central
#' Africa); for AOIs where 00 UTC is daylight, real downward shortwave flux
#' would be silently zeroed at the day boundary.
#'
#' @param input_dir       Directory holding `<year>/<nc_template>` NetCDFs
#'   (typically produced by [extract_era5land()]).
#' @param output_dir      Directory for year-level Parquet output.
#' @param dem_tif         Path to a DEM raster covering the AOI. Resampled
#'   onto the ERA5-Land grid once and reused for every month.
#' @param years           Integer vector of years to process.
#' @param nc_template     `sprintf` template for the input NetCDF basename;
#'   receives `(year, month)`.
#' @param out_template    `sprintf` template for the year-level output
#'   basename; receives `(year, version)`.
#' @param version         Version tag embedded in the output filename and
#'   the Parquet footer metadata.
#' @param compression     Parquet compression codec.
#' @param min_year_rows   Lower bound for a "complete" year file. Year files
#'   with fewer rows are deleted and regenerated. Default `1e6` suits a
#'   ~165-cell AOI for a full year; widen for larger AOIs.
#' @param metadata        Named character vector of metadata embedded in the
#'   Parquet footer. Defaults to a generic ERA5-Land dictionary.
#'
#' @return Character vector of year-level Parquet paths (invisibly).
#' @export
#'
#' @examples
#' \dontrun{
#' transform_era5land(
#'   input_dir   = "data/climate/era5land/input/nc",
#'   output_dir  = "data/climate/era5land/output/parquet",
#'   dem_tif     = "RDC_Elevation_Complete.tif",
#'   years       = 2014:2017,
#'   nc_template = "era5land_kinshasa_hourly_%d%02d.nc",
#'   out_template = "era5land_hourly_kinshasa_%d_%s.parquet"
#' )
#' }
transform_era5land <- function(input_dir,
                               output_dir,
                               dem_tif,
                               years,
                               nc_template   = "era5land_%d%02d.nc",
                               out_template  = "era5land_hourly_%d_%s.parquet",
                               version       = "v0.1.0",
                               compression   = "zstd",
                               min_year_rows = 1e6,
                               metadata      = NULL) {
  stopifnot(
    is.character(input_dir),  length(input_dir)  == 1L,
    is.character(output_dir), length(output_dir) == 1L,
    is.character(dem_tif),    length(dem_tif)    == 1L, file.exists(dem_tif),
    is.numeric(years),        length(years)      >= 1L
  )
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

  ctx <- new.env(parent = emptyenv())
  ctx$input_dir   <- input_dir
  ctx$output_dir  <- output_dir
  ctx$dem_tif     <- dem_tif
  ctx$nc_tmpl     <- nc_template
  ctx$out_tmpl    <- out_template
  ctx$version     <- version
  ctx$compression <- compression
  ctx$metadata    <- if (is.null(metadata)) .default_metadata(version) else metadata
  ctx$elev        <- new.env(parent = emptyenv())
  ctx$elev$value  <- NULL

  out_paths <- character()
  for (yr in years) {
    year_path <- file.path(output_dir, sprintf(out_template, yr, version))
    out_paths <- c(out_paths, year_path)
    if (.year_parquet_is_complete(year_path, min_year_rows)) {
      message(sprintf("Year %d already done: %s", yr, basename(year_path)))
      next
    }
    for (mo in 1:12) .process_month_to_daily(yr, mo, ctx)
    .consolidate_year(yr, ctx)
  }
  invisible(out_paths)
}
