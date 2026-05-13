# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`moddafricaes` is an R package (DESCRIPTION-based, roxygen2 docs, `renv` for dependencies) providing tools to collate, analyse and communicate evidence for the MoDD Africa project. Exported functions:

- `get_bbox(shp_path, crs = 4326)` — reads any shapefile (including `/vsizip/...` paths) and returns its bounding box in Copernicus CDS order `c(N, W, S, E)`.
- `extract_era5land(bbox, years, output_dir, ...)` — downloads ERA5-Land hourly NetCDFs from the Copernicus CDS for a `c(N, W, S, E)` bbox, staging one file per (year, month) under `<output_dir>/<year>/`. Requires the `CDS_API_KEY` environment variable.

The intended composition is `get_bbox()` → `extract_era5land()`: the first produces a bbox in the exact order the second consumes.

## Common commands

Run from the package root. `renv` auto-activates via `.Rprofile`.

- Restore deps: `R -e 'renv::restore()'`
- Regenerate `NAMESPACE` and `man/*.Rd` from roxygen comments: `R -e 'devtools::document()'`
- Render `README.md` from `README.Rmd`: `R -e 'devtools::build_readme()'`
- Load package for interactive use: `R -e 'devtools::load_all()'`
- Check the package: `R -e 'devtools::check()'`
- Lint (config in `.lintr`, 80-col, 2-space indent, snake_case): `R -e 'lintr::lint_package()'`
- Run `R/get_bounding_box.R` directly (the file has an `if (sys.nframe() == 0L)` block that calls `get_bbox()` against the default province26 path): `Rscript R/get_bounding_box.R`

There is no `tests/` directory yet; `.lintr` already excludes one for when it's added.

## Architecture notes

- Standard R package layout: sources in `R/`, generated docs in `man/`, exports listed in `NAMESPACE` (do not hand-edit — regenerate via `devtools::document()`).
- Imports are declared in `DESCRIPTION` (`sf`, `ecmwfr`, `lubridate`, `terra`); within `R/` code, reference functions with the `pkg::` prefix rather than `library()`. After adding/removing an import, snapshot with `renv::snapshot()`.
- Shapefile inputs are read via `sf::st_read()`, which accepts GDAL's `/vsizip/<archive.zip>/<file.shp>` virtual paths so zips can stay zipped. The example shapefile (`data-acquisition/utilities/province26.zip`) is **not** bundled — callers must supply their own path.
- **CDS bbox order is `c(N, W, S, E)`** throughout this package, not `sf::st_bbox()`'s `(xmin, ymin, xmax, ymax)`. This is what `get_bbox()` returns and what `extract_era5land()`'s `area` field expects. Preserve that convention when adding related helpers.
- `extract_era5land()` is resume-safe by design: it checks each existing NetCDF with `terra::rast()` and re-downloads only truncated files, and wraps each per-month CDS request in `tryCatch` so a single flaky response logs and continues rather than aborting a multi-year run.
- `.Rbuildignore` excludes `renv/`, `.positai`, `.claude`, `AGENTS.md`, `README.Rmd`, etc. from the built tarball — add new dev-only files there if needed.
- `renv.lock` is the source of truth for dependency versions; after `install.packages(...)` or similar, snapshot with `renv::snapshot()`.
