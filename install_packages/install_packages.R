# Install (or download for air-gapped transfer) R packages from a list file.
#
# Three modes, selected by the first argument:
#
#   Rscript install_packages/install_packages.R online  [list_file]   # install from CRAN (default)
#   Rscript install_packages/install_packages.R download [list_file]   # download source tarballs -> DIST
#   Rscript install_packages/install_packages.R offline [list_file]    # install from a local DIST repo
#   Rscript install_packages/install_packages.R index                  # (re)build the DIST PACKAGES index
#
# If the first argument is not one of those mode keywords it is treated as the
# list file and the mode defaults to "online", so the older form still works:
#
#   Rscript install_packages/install_packages.R [list_file]            # == online
#
# The list file defaults to installed_r_packages.txt (produced by list_packages.R).
#
# Air-gap workflow:
#   1. On an internet-connected machine:  Rscript install_packages/install_packages.R download list.txt
#      -> downloads the source tarballs for every package in the list PLUS their hard
#         dependencies (Depends/Imports/LinkingTo, recursive) into the DIST folder, and
#         writes a PACKAGES index so DIST is a self-contained local repository.
#   2. Copy the DIST folder to the air-gapped target's DIST folder.
#   3. On the target:  Rscript install_packages/install_packages.R offline list.txt
#      -> installs from DIST (file:// repo), no network access. offline reindexes DIST
#         first, so tarballs added to DIST by hand are picked up automatically.
#
# To add packages to an existing DIST later, drop the source tarballs in and either run
# 'offline' (which reindexes before installing) or 'index' to rebuild the PACKAGES index
# on its own.
#
# Environment knobs:
#   R_INSTALL_LIB     Library to install into / check against for online & offline modes
#                     (default: .libPaths()[1], R's usual target - which on the SCC is
#                     often the personal ~/R library). When set, it becomes the sole
#                     leading entry of .libPaths(), so installs go there AND the personal
#                     ~/R library is dropped from "already installed" checks - giving a
#                     self-contained library for a shared R build. Point it at the new R's
#                     own library, e.g. .../install/lib64/R/library.
#   DIST_DIR          DIST folder location (default: ./DIST)
#   CRAN_REPO         CRAN mirror for download mode (default: https://cran.r-project.org)
#   TARGET_R_VERSION  R version the downloads must be compatible with, for download
#                     mode (default: the R running the download)
#   TARGET_OS         OS the downloads must apply to, for download mode: linux | macos
#                     | windows (default: linux)
#   INCLUDE_SUGGESTS  Include Suggests, not just hard deps (Depends/Imports/LinkingTo).
#                     Affects BOTH download (what gets fetched into DIST) and offline
#                     (what install.packages asks for). Set it the SAME for both steps so
#                     the offline closure matches what was downloaded (default: off).
#   OVERWRITE         download mode only: re-fetch every resolved tarball even if it is
#                     already in DIST. Default off -> download is re-runnable and only
#                     fetches packages whose exact-version tarball is missing from DIST.

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

# Install a set of packages one at a time, logging a per-package SUCCESS/FAILED line
# (with the error/warning text on failures) to package_installation_log.txt, and
# returning the names that failed. Shared by online (CRAN) and offline modes. For
# offline, pass contriburl pointing at the flat DIST repo (file://...) so
# install.packages reads DIST/PACKAGES directly rather than expecting the src/contrib
# subtree a normal repos= would.
install_from_repo <- function(packages, repos, contriburl = NULL, type = getOption("pkgType"),
                               dependencies = TRUE) {
  installed <- rownames(installed.packages())
  missing_packages <- setdiff(packages, installed)

  if (length(missing_packages) == 0) {
    cat("All packages from the list are already installed.\n")
    return(invisible(character(0)))
  }

  # install.packages writes to (and find.package/installed.packages above read from)
  # the first entry of .libPaths(). The dispatch code below sets that from R_INSTALL_LIB
  # when given, so installs land in the chosen library; pass it explicitly here so the
  # target is unambiguous at the call site.
  target_lib <- .libPaths()[1]
  cat("Installing", length(missing_packages), "missing packages into", target_lib, "\n")
  log_file <- "package_installation_log.txt"
  cat("Installation started at", format(Sys.time()), "\n", file = log_file)

  # keep_outputs saves each build's full output (the R CMD INSTALL log, including
  # compiler errors and "dependency 'X' not available" messages) to <pkg>.out in this
  # directory. We keep these only for packages that fail, so the actual reason is
  # reviewable, without scattering an .out for every one of hundreds of successes.
  out_dir <- "install_logs"
  dir.create(out_dir, showWarnings = FALSE)

  install_one <- function(pkg) {
    if (is.null(contriburl)) {
      install.packages(pkg, lib = target_lib, repos = repos, type = type,
                       dependencies = dependencies, keep_outputs = out_dir)
    } else {
      install.packages(pkg, lib = target_lib, repos = repos, contriburl = contriburl,
                       type = type, dependencies = dependencies, keep_outputs = out_dir)
    }
  }

  is_installed <- function(pkg) length(find.package(pkg, quiet = TRUE)) > 0

  failed <- character(0)
  for (pkg in missing_packages) {
    # missing_packages was computed once, up front. Because each install.packages call
    # below uses dependencies = TRUE, installing an earlier list entry also pulls in its
    # dependencies - and those dependencies are often later entries in this same list.
    # install.packages always reinstalls a package named explicitly (it only skips
    # already-installed *dependencies*), so without this re-check we would needlessly
    # reinstall every package that an earlier entry already brought in as a dependency.
    if (is_installed(pkg)) {
      cat("Already installed (skipping):", pkg, "\n")
      cat("ALREADY INSTALLED:", pkg, "\n", file = log_file, append = TRUE)
      next
    }
    cat("Installing package:", pkg, "\n")
    before <- list.files(out_dir, pattern = "\\.out$")
    # A failed source build makes install.packages emit a *warning* ("had non-zero
    # exit status"), not an error, so tryCatch alone would miss it - and there can be
    # several warnings (the informative "dependency not available" plus the generic
    # one). Capture them all, then decide success by whether the package is actually
    # present afterwards (the authoritative check); the full build log is in <pkg>.out.
    msgs <- character(0)
    withCallingHandlers(
      tryCatch(install_one(pkg), error = function(e) msgs <<- c(msgs, conditionMessage(e))),
      warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") }
    )
    new_outs <- setdiff(list.files(out_dir, pattern = "\\.out$"), before)

    if (is_installed(pkg)) {
      cat("SUCCESS:", pkg, "\n", file = log_file, append = TRUE)
      if (length(new_outs)) file.remove(file.path(out_dir, new_outs))  # keep only failures
    } else {
      detail <- if (length(msgs)) paste(unique(trimws(msgs)), collapse = " | ") else
                "not installed (see console output above)"
      cat("FAILED:", pkg, "-", detail, "\n", file = log_file, append = TRUE)
      if (length(new_outs)) {
        cat("  build output:", paste(file.path(out_dir, new_outs), collapse = ", "),
            "\n", file = log_file, append = TRUE)
      }
      cat("  FAILED:", pkg, "-", detail, "\n")
      failed <- c(failed, pkg)
    }
  }

  cat("Installation completed at", format(Sys.time()), "\n", file = log_file, append = TRUE)
  if (length(failed) > 0) {
    cat(length(failed), "of", length(missing_packages), "failed:",
        paste(failed, collapse = ", "), "\n", file = log_file, append = TRUE)
    cat("Per-failure build logs are in", out_dir, "/.\n", file = log_file, append = TRUE)
  } else if (length(list.files(out_dir)) == 0) {
    unlink(out_dir, recursive = TRUE)   # nothing failed - no build logs to keep
  }
  cat("Installation complete. See", log_file, "for details.\n")
  invisible(failed)
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

# (Re)build the PACKAGES index for DIST so it is a self-contained local source
# repository. install.packages discovers the available tarballs from this index, so
# it must be rewritten whenever DIST's contents change - which is why download (after
# fetching), offline (before installing), and the standalone 'index' mode all call it.
# Returns the number of packages indexed.
index_dist <- function(dist_dir) {
  if (!dir.exists(dist_dir)) {
    stop("DIST folder '", dist_dir, "' does not exist.")
  }
  invisible(tools::write_PACKAGES(dist_dir, type = "source"))
}

# download: fetch source tarballs for the list + hard deps into DIST, then index it.
# Re-runnable: by default skips any package whose exact-version tarball is already in
# DIST (set OVERWRITE=1 to re-fetch everything). Writes a reviewable download_log.txt
# recording what was requested, resolved, skipped, downloaded, dropped (not on CRAN -
# e.g. Bioconductor-only packages), and any download failures.
download_packages <- function(packages, dist_dir) {
  cran    <- Sys.getenv("CRAN_REPO", "https://cran.r-project.org")
  target_R <- Sys.getenv("TARGET_R_VERSION", as.character(getRversion()))
  target_os <- Sys.getenv("TARGET_OS", "linux")
  os_type <- os_type_for(target_os)

  include_suggests <- tolower(Sys.getenv("INCLUDE_SUGGESTS", "")) %in% c("1", "true", "yes")
  overwrite        <- tolower(Sys.getenv("OVERWRITE", "")) %in% c("1", "true", "yes")

  # Build a record of this run: say() prints to the console AND logs; log_only() writes
  # to the log alone (used for the full long name lists we don't want to spam stdout).
  log_lines <- character(0)
  log_only <- function(line) log_lines[[length(log_lines) + 1L]] <<- line
  say      <- function(line) { cat(line, "\n"); log_only(line) }

  say(paste("Download started at", format(Sys.time())))
  say(paste("Download repository (CRAN):", cran))
  say(paste("Resolving packages for R", target_R, "(override via TARGET_R_VERSION)"))
  say(paste0("Resolving packages for OS ", target_os, " [OS_type=", os_type,
             "] (override via TARGET_OS)"))
  say(paste("Suggests:", if (include_suggests)
        "included for listed packages (INCLUDE_SUGGESTS set)"
      else "excluded (set INCLUDE_SUGGESTS=1 to include)"))
  say(paste("Re-download existing tarballs:", if (overwrite)
        "yes (OVERWRITE set)" else "no - skip already-present (set OVERWRITE=1 to force)"))

  ap <- available.packages(repos = cran, type = "source",
                           filters = target_filters(target_R, os_type))

  # Drop names not available as source on CRAN (base packages, Bioconductor-only pkgs,
  # typos, ...). The full list goes to the log so silently-skipped packages are visible.
  wanted  <- intersect(packages, rownames(ap))
  dropped <- setdiff(packages, wanted)
  if (length(dropped) > 0) {
    say(paste(length(dropped), "of", length(packages),
              "requested packages not available as source on CRAN for the target R/OS (skipped)."))
    log_only(paste("  dropped:", paste(sort(dropped), collapse = ", ")))
    cat("  (full list of", length(dropped), "skipped packages in download_log.txt)\n")
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
  say(paste("Resolved", length(wanted), "requested ->", length(closure),
            "packages with dependencies."))

  dir.create(dist_dir, recursive = TRUE, showWarnings = FALSE)

  # Skip packages whose exact-version tarball is already in DIST (unless OVERWRITE).
  # Version-aware: if CRAN now offers a newer version than the cached tarball the file
  # names differ, so the new version is fetched rather than treated as already present.
  expected <- paste0(closure, "_", ap[closure, "Version"], ".tar.gz")
  present  <- file.exists(file.path(dist_dir, expected))
  if (overwrite) {
    to_download <- closure
  } else {
    to_download <- closure[!present]
    skipped     <- closure[present]
    if (length(skipped) > 0) {
      say(paste("Already in DIST, skipping:", length(skipped), "package(s)."))
      log_only(paste("  skipped (cached):", paste(sort(skipped), collapse = ", ")))
    }
  }

  got_names <- character(0)
  if (length(to_download) > 0) {
    say(paste("Downloading", length(to_download), "source tarball(s) into",
              normalizePath(dist_dir), "..."))
    got <- download.packages(to_download, destdir = dist_dir, repos = cran, type = "source")
    got_names <- got[, 1]
    say(paste("Downloaded", length(got_names), "tarball(s)."))
  } else {
    say("Nothing to download - all resolved packages already present in DIST.")
  }

  # Anything we meant to fetch but did not get back is a download failure.
  failed_dl <- setdiff(to_download, got_names)
  if (length(failed_dl) > 0) {
    say(paste("WARNING:", length(failed_dl), "package(s) failed to download."))
    log_only(paste("  download failures:", paste(sort(failed_dl), collapse = ", ")))
    cat("  (list of failures in download_log.txt)\n")
  }

  n_indexed <- index_dist(dist_dir)
  say(paste0("Wrote PACKAGES index (", n_indexed, " package(s)); ", dist_dir,
             " is now a local source repository."))
  say(paste("Download finished at", format(Sys.time())))

  log_file <- "download_log.txt"
  writeLines(log_lines, log_file)
  cat("\nDownload summary written to", log_file, "\n")
  cat("Next: copy this DIST folder to the air-gapped target, then run:\n")
  cat("  DIST_DIR=", dist_dir, " Rscript ", self, " offline <list_file>\n", sep = "")
}

# offline: install from the local DIST repo (file://), no network.
install_offline <- function(packages, dist_dir) {
  if (!dir.exists(dist_dir)) {
    stop("DIST folder '", dist_dir, "' does not exist. ",
         "Run the 'download' step first and copy DIST here (or set DIST_DIR).")
  }
  # Reindex DIST before installing so any tarballs added since the last index (e.g.
  # dropped in by hand) are picked up. This also rebuilds a missing PACKAGES file - so
  # a DIST that only ever received tarballs still installs without a separate step.
  n_indexed <- index_dist(dist_dir)
  cat("Indexed", n_indexed, "package(s) in", normalizePath(dist_dir), "\n")
  # download.packages writes tarballs (and write_PACKAGES the index) flat in DIST, so
  # point contriburl straight at DIST rather than letting install.packages append
  # the usual src/contrib path.
  repo <- paste0("file://", normalizePath(dist_dir))
  cat("Installing from local repository:", repo, "\n")

  # Match the dependency set to what the 'download' step put in DIST. By default download
  # fetches hard deps only (Depends/Imports/LinkingTo), so installing with
  # dependencies = TRUE (which also pulls Suggests) would ask for tarballs that aren't in
  # DIST and fail. Restrict to hard deps here; only widen to Suggests when INCLUDE_SUGGESTS
  # is set - the same knob that made download include them. (Set it identically for both
  # steps so the offline closure matches what was downloaded.)
  include_suggests <- tolower(Sys.getenv("INCLUDE_SUGGESTS", "")) %in% c("1", "true", "yes")
  deps <- if (include_suggests) TRUE else c("Depends", "Imports", "LinkingTo")
  cat("Dependencies:", if (include_suggests)
        "Depends/Imports/LinkingTo + Suggests (INCLUDE_SUGGESTS set)"
      else
        "Depends/Imports/LinkingTo only (set INCLUDE_SUGGESTS=1 if DIST was built with it)",
      "\n")
  install_from_repo(packages, repos = repo, contriburl = repo, type = "source",
                    dependencies = deps)
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

MODES <- c("online", "download", "offline", "index")
args  <- commandArgs(trailingOnly = TRUE)

# How this script was invoked (e.g. "install_packages/install_packages.R" or a full
# path), so the retry/next-step commands we print are copy-pasteable as-is.
self <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
if (length(self) == 0 || !nzchar(self)) self <- "install_packages.R"

if (length(args) >= 1 && args[1] %in% MODES) {
  mode          <- args[1]
  pkg_list_file <- if (length(args) >= 2) args[2] else "installed_r_packages.txt"
} else {
  mode          <- "online"
  pkg_list_file <- if (length(args) >= 1) args[1] else "installed_r_packages.txt"
}

dist_dir <- Sys.getenv("DIST_DIR", "DIST")

# index: (re)build the PACKAGES index in DIST and exit. Standalone so DIST can be
# refreshed after adding tarballs by hand, without installing anything. Needs no
# package list or install library, so handle it before either is touched.
if (mode == "index") {
  cat("Mode:", mode, "\n")
  n_indexed <- index_dist(dist_dir)
  cat("Wrote PACKAGES index (", n_indexed, " package(s)); ", normalizePath(dist_dir),
      " is now a local source repository.\n", sep = "")
  quit(save = "no", status = 0)
}

# R_INSTALL_LIB: the library to install into and check against. Default is .libPaths()[1]
# (R's usual target - on the SCC that is often the user's personal ~/R library, which is
# wrong for a shared install). When set, we make it the sole leading entry of .libPaths()
# so that: (a) install.packages writes there, and (b) "already installed" is judged
# against THIS R's own library only - the personal ~/R library is dropped from the search,
# so its stray copies don't mask packages that should be (re)installed into the target,
# yielding a self-contained library for the shared R build.
install_lib <- Sys.getenv("R_INSTALL_LIB", "")
if (nzchar(install_lib)) {
  dir.create(install_lib, recursive = TRUE, showWarnings = FALSE)
  if (file.access(install_lib, mode = 2) != 0) {
    stop("R_INSTALL_LIB '", install_lib, "' is not writable (or could not be created).")
  }
  # .libPaths(x) keeps x first and re-appends only R's site/base libraries (NOT
  # R_LIBS_USER), so the personal ~/R library is excluded from the search.
  .libPaths(install_lib)
  cat("Install library (R_INSTALL_LIB):", normalizePath(install_lib), "\n")
  cat("Library search path:\n  ", paste(.libPaths(), collapse = "\n  "), "\n", sep = "")
}

packages <- read_package_list(pkg_list_file)

cat("Mode:", mode, "\n")
failed <- switch(mode,
       download = { download_packages(packages, dist_dir); character(0) },
       offline  = install_offline(packages, dist_dir),
       online   = install_online(packages))

# Report final state (offline/online only; download installs nothing).
if (mode != "download") {
  installed_after <- rownames(installed.packages())
  cat("Total packages installed:", length(installed_after), "\n")

  if (length(failed) > 0) {
    # Write the failures as a package list (same format the script reads) so they can
    # be fed straight back in, and print a ready-to-run retry command for this mode.
    failed_file <- "failed_packages.txt"
    writeLines(c("Package", failed), failed_file)
    cat("\n", length(failed), " package(s) FAILED - summary in package_installation_log.txt,",
        " full build output per failure in install_logs/; names written to ", failed_file, ".\n", sep = "")
    prefix <- if (mode == "offline") paste0("DIST_DIR=", shQuote(dist_dir), " ") else ""
    cat("To retry only the failed packages, rerun:\n")
    cat("  ", prefix, "Rscript ", self, " ", mode, " ", failed_file, "\n", sep = "")
    cat("(To retry one package, put just its name under a \"Package\" header in a",
        " file and pass that file instead.)\n", sep = "")
  }
}
