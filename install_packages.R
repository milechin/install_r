# Install (or download for air-gapped transfer) R packages from a list file.
#
# Three modes, selected by the first argument:
#
#   Rscript install_packages.R online  [list_file]   # install from CRAN (default)
#   Rscript install_packages.R download [list_file]   # download source tarballs -> DIST
#   Rscript install_packages.R offline [list_file]    # install from a local DIST repo
#
# If the first argument is not one of those mode keywords it is treated as the
# list file and the mode defaults to "online", so the older form still works:
#
#   Rscript install_packages.R [list_file]            # == online
#
# The list file defaults to installed_r_packages.txt (produced by list_packages.R).
#
# Air-gap workflow:
#   1. On an internet-connected machine:  Rscript install_packages.R download list.txt
#      -> downloads the source tarballs for every package in the list PLUS their hard
#         dependencies (Depends/Imports/LinkingTo, recursive) into the DIST folder, and
#         writes a PACKAGES index so DIST is a self-contained local repository.
#   2. Copy the DIST folder to the air-gapped target's DIST folder.
#   3. On the target:  Rscript install_packages.R offline list.txt
#      -> installs from DIST (file:// repo), no network access.
#
# Environment knobs:
#   DIST_DIR          DIST folder location (default: ./DIST)
#   CRAN_REPO         CRAN mirror for download mode (default: https://cran.r-project.org)
#   TARGET_R_VERSION  R version the downloads must be compatible with, for download
#                     mode (default: the R running the download)
#   TARGET_OS         OS the downloads must apply to, for download mode: linux | macos
#                     | windows (default: linux)

# --- helpers ---------------------------------------------------------------

# Read the package list (one name per line, with a "Package" header column).
read_package_list <- function(file_path) {
  if (!file.exists(file_path)) {
    stop("Error: Package list file '", file_path, "' not found.")
  }
  cat("Reading package list from", file_path, "\n")
  pkg_data <- read.table(file_path, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
  packages <- pkg_data$Package
  cat("Found", length(packages), "packages in the list.\n")
  packages
}

# Install a set of packages one at a time, logging a per-package SUCCESS/FAILED line.
# Shared by online (CRAN) and offline modes. For offline, pass contriburl pointing at
# the flat DIST repo (file://...) so install.packages reads DIST/PACKAGES directly
# rather than expecting the src/contrib subtree a normal repos= would.
install_from_repo <- function(packages, repos, contriburl = NULL, type = getOption("pkgType")) {
  installed <- rownames(installed.packages())
  missing_packages <- setdiff(packages, installed)

  if (length(missing_packages) == 0) {
    cat("All packages from the list are already installed.\n")
    return(invisible())
  }

  cat("Installing", length(missing_packages), "missing packages...\n")
  log_file <- "package_installation_log.txt"
  cat("Installation started at", format(Sys.time()), "\n", file = log_file)

  install_one <- function(pkg) {
    if (is.null(contriburl)) {
      install.packages(pkg, repos = repos, type = type, dependencies = TRUE)
    } else {
      install.packages(pkg, repos = repos, contriburl = contriburl,
                       type = type, dependencies = TRUE)
    }
  }

  for (pkg in missing_packages) {
    cat("Installing package:", pkg, "\n")
    tryCatch({
      install_one(pkg)
      cat("SUCCESS:", pkg, "\n", file = log_file, append = TRUE)
    }, error = function(e) {
      cat("FAILED:", pkg, "- Error:", conditionMessage(e), "\n", file = log_file, append = TRUE)
      cat("  Error installing", pkg, ":", conditionMessage(e), "\n")
    })
  }

  cat("Installation completed at", format(Sys.time()), "\n", file = log_file, append = TRUE)
  cat("Installation complete. See", log_file, "for details.\n")
}

# Map a TARGET_OS value to R's OS_type field ("unix" or "windows").
os_type_for <- function(target_os) {
  switch(tolower(target_os),
         linux = "unix", macos = "unix", unix = "unix",
         windows = "windows", win = "windows",
         stop("Unsupported TARGET_OS '", target_os, "' (use linux, macos, or windows)."))
}

# Build an available.packages() filter list that resolves the package index against
# a TARGET R version and OS rather than the R/OS actually running the download.
target_filters <- function(target_R, os_type) {
  target_R <- as.package_version(target_R)

  r_version_filter <- function(db) {
    depends <- db[, "Depends"]
    keep <- vapply(depends, function(d) {
      if (is.na(d) || !nzchar(d)) return(TRUE)
      m <- regmatches(d, regexpr("R *\\([^)]*\\)", d))
      if (length(m) == 0) return(TRUE)                       # no R constraint
      spec <- sub("R *\\(([^)]*)\\).*", "\\1", m)            # e.g. ">= 4.1.0"
      op  <- trimws(sub("^([<>=!]+).*", "\\1", spec))
      ver <- trimws(sub("^[<>=!]+", "", spec))
      ver <- tryCatch(as.package_version(ver), error = function(e) return(NA))
      if (is.na(ver)) return(TRUE)
      switch(op,
             ">=" = target_R >= ver, ">" = target_R > ver,
             "<=" = target_R <= ver, "<" = target_R < ver,
             "==" = target_R == ver, TRUE)
    }, logical(1))
    db[keep, , drop = FALSE]
  }

  os_filter <- function(db) {
    ot <- db[, "OS_type"]
    db[is.na(ot) | !nzchar(ot) | ot == os_type, , drop = FALSE]
  }

  list(R_version = r_version_filter, OS_type = os_filter, "duplicates")
}

# --- modes -----------------------------------------------------------------

# download: fetch source tarballs for the list + hard deps into DIST, then index it.
download_packages <- function(packages, dist_dir) {
  cran    <- Sys.getenv("CRAN_REPO", "https://cran.r-project.org")
  target_R <- Sys.getenv("TARGET_R_VERSION", as.character(getRversion()))
  target_os <- Sys.getenv("TARGET_OS", "linux")
  os_type <- os_type_for(target_os)

  include_suggests <- tolower(Sys.getenv("INCLUDE_SUGGESTS", "")) %in% c("1", "true", "yes")

  cat("Download repository (CRAN):", cran, "\n")
  cat("Resolving packages for R", target_R, "(override via TARGET_R_VERSION)\n")
  cat("Resolving packages for OS", target_os,
      paste0("[OS_type=", os_type, "]"), "(override via TARGET_OS)\n")
  cat("Suggests:", if (include_suggests)
        "included for listed packages (INCLUDE_SUGGESTS set)"
      else
        "excluded (set INCLUDE_SUGGESTS=1 to include)", "\n")

  ap <- available.packages(repos = cran, type = "source",
                           filters = target_filters(target_R, os_type))

  # Drop names not available as source on CRAN (base packages, typos, ...).
  wanted  <- intersect(packages, rownames(ap))
  dropped <- setdiff(packages, wanted)
  if (length(dropped) > 0) {
    cat("Note: not available as source on CRAN for the target R/OS (skipped):\n  ",
        paste(dropped, collapse = ", "), "\n")
  }

  hard_which <- c("Depends", "Imports", "LinkingTo")

  # Recursive hard-dependency closure of the listed packages.
  deps <- unlist(tools::package_dependencies(wanted, db = ap, recursive = TRUE,
                                             which = hard_which), use.names = FALSE)
  closure_pkgs <- unique(c(wanted, deps))

  # Optionally mirror what offline install.packages(dependencies = TRUE) would also
  # pull: the Suggests of the *listed* packages, plus those packages' recursive hard
  # deps (Suggests are not taken recursively - that matches install.packages, and
  # avoids an unbounded closure).
  if (include_suggests) {
    sug <- unlist(tools::package_dependencies(wanted, db = ap, recursive = FALSE,
                                              which = "Suggests"), use.names = FALSE)
    sug <- intersect(sug, rownames(ap))
    sug_deps <- unlist(tools::package_dependencies(sug, db = ap, recursive = TRUE,
                                                   which = hard_which), use.names = FALSE)
    closure_pkgs <- unique(c(closure_pkgs, sug, sug_deps))
  }

  closure <- intersect(closure_pkgs, rownames(ap))
  cat("Resolved", length(wanted), "requested ->", length(closure),
      "packages with dependencies.\n")

  dir.create(dist_dir, recursive = TRUE, showWarnings = FALSE)
  cat("Downloading source tarballs into", normalizePath(dist_dir), "...\n")
  got <- download.packages(closure, destdir = dist_dir, repos = cran, type = "source")
  cat("Downloaded", nrow(got), "tarballs.\n")

  tools::write_PACKAGES(dist_dir, type = "source")
  cat("Wrote PACKAGES index;", dist_dir, "is now a local source repository.\n\n")
  cat("Next: copy this DIST folder to the air-gapped target, then run:\n")
  cat("  DIST_DIR=", dist_dir, " Rscript install_packages.R offline <list_file>\n", sep = "")
}

# offline: install from the local DIST repo (file://), no network.
install_offline <- function(packages, dist_dir) {
  if (!dir.exists(dist_dir) || !file.exists(file.path(dist_dir, "PACKAGES"))) {
    stop("DIST folder '", dist_dir, "' is missing or has no PACKAGES index. ",
         "Run the 'download' step first and copy DIST here (or set DIST_DIR).")
  }
  # download.packages writes tarballs (and write_PACKAGES the index) flat in DIST, so
  # point contriburl straight at DIST rather than letting install.packages append
  # the usual src/contrib path.
  repo <- paste0("file://", normalizePath(dist_dir))
  cat("Installing from local repository:", repo, "\n")
  install_from_repo(packages, repos = repo, contriburl = repo, type = "source")
}

# online: install from CRAN (the original behavior).
install_online <- function(packages) {
  # In a non-interactive Rscript getOption("repos") is the unresolved "@CRAN@"
  # placeholder, which makes install.packages fail with "trying to use CRAN without
  # setting a mirror". Honor a real mirror if one is already configured (e.g. via
  # ~/.Rprofile), otherwise fall back to CRAN_REPO (default https://cran.r-project.org),
  # the same source download mode uses.
  repos <- getOption("repos")
  cran  <- if (!is.null(repos)) repos[["CRAN"]] else NULL
  if (is.null(cran) || is.na(cran) || !nzchar(cran) || cran == "@CRAN@") {
    repos <- c(CRAN = Sys.getenv("CRAN_REPO", "https://cran.r-project.org"))
  }
  cat("Installing from CRAN:", repos[["CRAN"]], "\n")
  install_from_repo(packages, repos = repos)
}

# --- dispatch --------------------------------------------------------------

MODES <- c("online", "download", "offline")
args  <- commandArgs(trailingOnly = TRUE)

if (length(args) >= 1 && args[1] %in% MODES) {
  mode          <- args[1]
  pkg_list_file <- if (length(args) >= 2) args[2] else "installed_r_packages.txt"
} else {
  mode          <- "online"
  pkg_list_file <- if (length(args) >= 1) args[1] else "installed_r_packages.txt"
}

dist_dir <- Sys.getenv("DIST_DIR", "DIST")
packages <- read_package_list(pkg_list_file)

cat("Mode:", mode, "\n")
switch(mode,
       download = download_packages(packages, dist_dir),
       offline  = install_offline(packages, dist_dir),
       online   = install_online(packages))

# Report final state (offline/online only; download installs nothing).
if (mode != "download") {
  installed_after <- rownames(installed.packages())
  cat("Total packages installed:", length(installed_after), "\n")
}
