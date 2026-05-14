
<!-- README.md is generated from README.Rmd. Please edit that file -->

# moddafricaes : MoDD Africa Evidence Synthesis

<!-- badges: start -->

<!-- badges: end -->

Tools to collate, analyse and communicate evidence for the **MoDD
Africa** project. The package currently focuses on a single end-to-end
pipeline for **ERA5-Land** climate reanalysis: derive a study-area
bounding box from a shapefile, download hourly NetCDFs from the
Copernicus Climate Data Store (CDS), and transform them into
analysis-ready Parquet (hourly or monthly) or GeoTIFF (monthly min / max
temperature).

## Installation

`moddafricaes` is not on CRAN. Pick whichever GitHub-install path
matches your tooling:

``` r
# 1. pak (recommended; resolves system deps too)
# install.packages("pak")
pak::pak("modd-africa/moddafricaes")

# 2. remotes
# install.packages("remotes")
remotes::install_github("modd-africa/moddafricaes")

# 3. devtools
# install.packages("devtools")
devtools::install_github("modd-africa/moddafricaes")

# 4. A specific branch, tag, or commit
pak::pak("modd-africa/moddafricaes@main")
pak::pak("modd-africa/moddafricaes@v0.1.0")

# 5. From a local clone (e.g. for development)
# git clone https://github.com/modd-africa/moddafricaes.git
# cd moddafricaes
# R -e 'devtools::install()'        # or: pak::local_install(".")
```

You will also need a Copernicus CDS account and an API key exported as
`CDS_API_KEY` (see <https://cds.climate.copernicus.eu/>).

## Functions

| Function | Stage | Output |
|----|----|----|
| `get_bbox()` | Setup | `c(N, W, S, E)` numeric vector (CDS) |
| `extract_era5land()` | Download | One NetCDF per (year, month) |
| `transform_era5land()` | Transform | One Parquet per year (hourly) |
| `transform_era5land_monthly()` | Transform | One Parquet (monthly means) |
| `transform_era5land_minmax()` | Transform | GeoTIFF stacks of monthly T2m min/max |

All bounding boxes throughout the package are in Copernicus CDS order
**`c(N, W, S, E)`**, not `sf::st_bbox()`’s `(xmin, ymin, xmax, ymax)`.

## End-to-end example

``` r
library(moddafricaes)

# 1. Derive a bbox from any shapefile (zipped shapefiles work via /vsizip/).
bbox <- get_bbox(
  "/vsizip/data-acquisition/utilities/province26.zip/provinces26/Province26.shp"
)
bbox
#>         N         W         S         E
#> -3.92763  15.12846 -5.02540  16.53245

# 2. Download hourly ERA5-Land NetCDFs for the bbox (requires CDS_API_KEY).
extract_era5land(
  bbox       = bbox,
  years      = 2020:2021,
  output_dir = "data/era5land/nc"
)

# 3a. Transform hourly NetCDFs to one Parquet per year (with DEM elevation).
transform_era5land(
  input_dir    = "data/era5land/nc",
  output_dir   = "data/era5land/parquet",
  dem_tif      = "RDC_Elevation_Complete.tif",
  years        = 2020:2021,
  nc_template  = "era5land_%d%02d.nc",
  out_template = "era5land_hourly_%d_%s.parquet"
)

# 3b. Or reduce the same NCs to monthly min / max 2m temperature GeoTIFFs.
transform_era5land_minmax(
  input_dir  = "data/era5land/nc",
  output_dir = "data/era5land/minmax",
  years      = 2020:2021
)

# 3c. Or transform a CDS monthly-means NetCDF (different product) to Parquet.
transform_era5land_monthly(
  input_nc    = "data/era5land/era5land-kinshasa-monthly-2020-2021.nc",
  output_path = "data/era5land/parquet/era5land_monthly_kinshasa.parquet",
  dem_tif     = "RDC_Elevation_Complete.tif"
)
```

## Notes on the transforms

- **Hourly transform** (`transform_era5land()`) de-accumulates `tp` and
  `ssrd` per day, derives wind speed, relative humidity, VPD and Celsius
  temperature, and joins a DEM-derived `elevation_m` onto the ERA5-Land
  0.1° grid. Intermediate per-day Parquets are staged under
  `<output_dir>/_daily/<year>/` and removed after the year file passes a
  readability check, so re-runs resume cleanly.
- **Monthly-means transform** (`transform_era5land_monthly()`) does
  **not** de-accumulate `tp` / `ssrd` — the CDS monthly product stores
  per-day means, so monthly totals are `value × days_in_month`. A sanity
  check errors out if the wrong CDS product is fed in.
- **Min/max transform** (`transform_era5land_minmax()`) consumes the
  multi-variable NetCDFs from `extract_era5land()`, selecting only the
  `t2m` layers, then reduces to daily min/max and then to monthly
  min/max via `terra::tapp()`.
- All write steps are idempotent: an existing readable output
  short-circuits the work; a corrupt one is deleted and regenerated.

## Caveat

The hour-0-forced-to-0 rule for the de-accumulated `tp` and `ssrd`
columns in `transform_era5land()` is exact only where 00 UTC falls
during night (e.g. central Africa). For AOIs where 00 UTC is daylight,
real downward shortwave flux would be silently zeroed at the day
boundary — revisit before using elsewhere.
