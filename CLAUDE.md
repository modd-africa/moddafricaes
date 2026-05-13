# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`moddafricaes` is an R package (DESCRIPTION-based, roxygen2 docs, `renv` for dependencies) providing tools to collate, analyse and communicate evidence for the MoDD Africa project. Currently exports a single function, `get_province_bbox()`, that derives Copernicus CDS-ordered bounding boxes (N, W, S, E) for DRC provinces from a bundled shapefile.

## Common commands

Run from the package root. `renv` auto-activates via `.Rprofile`.

- Restore deps: `R -e 'renv::restore()'`
- Regenerate `NAMESPACE` and `man/*.Rd` from roxygen comments: `R -e 'devtools::document()'`
- Render `README.md` from `README.Rmd`: `R -e 'devtools::build_readme()'`
- Load package for interactive use: `R -e 'devtools::load_all()'`
- Check the package: `R -e 'devtools::check()'`
- Lint (config in `.lintr`, 80-col, 2-space indent, snake_case): `R -e 'lintr::lint_package()'`
- Run the `get_bounding_box.R` script directly (the file has an `if (sys.nframe() == 0L)` block that calls `get_province_bbox(verbose = TRUE)`): `Rscript R/get_bounding_box.R`

There is no `tests/` directory yet; `.lintr` already excludes one for when it's added.

## Architecture notes

- Standard R package layout: sources in `R/`, generated docs in `man/`, exports listed in `NAMESPACE` (do not hand-edit — regenerate via `devtools::document()`).
- Imports are declared in `DESCRIPTION` (`Imports: sf`); within `R/` code, reference functions with the `sf::` prefix rather than `library()`.
- Shapefile inputs are read through GDAL's `/vsizip/` virtual filesystem (see `R/get_bounding_box.R`), so the zip can stay zipped. Default expects `data-acquisition/utilities/province26.zip` relative to the working directory — this file is **not** in the package; callers must supply it or override `shp_zip`.
- `get_province_bbox()` returns coordinates in **CDS order `c(N, W, S, E)`**, not the `sf::st_bbox()` order `(xmin, ymin, xmax, ymax)`. Preserve that convention when adding related helpers.
- `.Rbuildignore` excludes `renv/`, `.positai`, `.claude`, `AGENTS.md`, `README.Rmd`, etc. from the built tarball — add new dev-only files there if needed.
- `renv.lock` is the source of truth for dependency versions; after `install.packages(...)` or similar, snapshot with `renv::snapshot()`.
