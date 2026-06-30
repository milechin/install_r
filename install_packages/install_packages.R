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
#   LOG_DIR           Directory for log/output files - package_installation_log.txt,
#                     install_logs/, failed_packages.txt, download_log.txt (default:
#                     build/package_install, created if missing).
#   CRAN_REPO         CRAN mirror for download/online modes (default: https://cran.r-project.org)
#   TARGET_R_VERSION  R version the downloads must be compatible with, for download
#                     mode (default: the R running the download)
#   TARGET_BIOC_VERSION  Bioconductor release the downloads must target, e.g. 3.20 (default:
#                     the running R's Bioc release; required for download when the download
#                     machine's R differs from the target R and the list has Bioc packages).
#   TARGET_OS         OS the downloads must apply to, for download mode: linux | macos
#                     | windows (default: linux)
#   INCLUDE_SUGGESTS  Include Suggests, not just hard deps (Depends/Imports/LinkingTo).
#                     Affects BOTH download (what gets fetched into DIST) and offline
#                     (what install.packages asks for). Set it the SAME for both steps so
#                     the offline closure matches what was downloaded (default: off).
#   OVERWRITE         download mode only: re-fetch every resolved tarball even if it is
#                     already in DIST. Default off -> download is re-runnable and only
#                     fetches packages whose exact-version tarball is missing from DIST.
#   SKIP_REINDEX      offline mode only: skip rebuilding the DIST PACKAGES index before
#                     installing (default: off). Use when DIST is unchanged since the
#                     download step, which already wrote the index - reindexing a large
#                     DIST takes minutes. Requires an existing PACKAGES index.

# --- helpers ---------------------------------------------------------------

# Read the package list written by list_packages.R: tab-separated, with a "Package"
# column and a "Repository" column (CRAN | Bioconductor). Back-compatible with the
# older single-column ("Package" only) format - those lists, and the test harness's
# inline lists, carry no Repository column, so every package defaults to CRAN (exactly
# today's behavior). Returns a data.frame(Package, Repository).
read_package_list <- function(file_path) {
  if (!file.exists(file_path)) {
    stop("Error: Package list file '", file_path, "' not found.")
  }
  cat("Reading package list from", file_path, "\n")
  pkg_data <- read.table(file_path, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
  if ("Repository" %in% names(pkg_data)) {
    # Defensive: anything not clearly "Bioconductor" is treated as CRAN.
    repo <- ifelse(toupper(trimws(pkg_data$Repository)) == "BIOCONDUCTOR",
                   "Bioconductor", "CRAN")
  } else {
    cat("  No 'Repository' column found - treating all packages as CRAN.\n")
    repo <- rep("CRAN", nrow(pkg_data))
  }
  pkg_df <- data.frame(Package = pkg_data$Package, Repository = repo,
                       stringsAsFactors = FALSE)
  n_bioc <- sum(pkg_df$Repository == "Bioconductor")
  cat("Found", nrow(pkg_df), "packages in the list (", n_bioc, "Bioconductor).\n")
  pkg_df
}

# Install a set of packages one at a time, logging a per-package SUCCESS/FAILED line
# (with the error/warning text on failures) to package_installation_log.txt, and
# returning the names that failed. Shared by online (CRAN) and offline modes. For
# offline, pass contriburl pointing at the flat DIST repo (file://...) so
# install.packages reads DIST/PACKAGES directly rather than expecting the src/contrib
# subtree a normal repos= would.
#
# Version-aware: a package is (re)installed when it is missing OR the repo offers a
# strictly newer version (an upgrade); a package already at >= the repo version is
# skipped. This mirrors how `install.packages` treats an explicitly-named package
# (always installs the repo's version) but avoids needlessly recompiling packages that
# are already current - important because we install per-package with dependencies=TRUE,
# so an early entry often pulls later entries in as deps; by the time their turn comes
# they are current and are skipped rather than rebuilt.
install_from_repo <- function(packages, repos, contriburl = NULL, type = getOption("pkgType"),
                               dependencies = TRUE, log_dir = "build/package_install") {
  # Versions the repo can actually install on THIS R (default filters = R-version/OS
  # aware), so the upgrade comparison uses the version install.packages would pick here.
  # NB: pass contriburl ONLY when we have one (offline/file:// repo). available.packages
  # defaults contriburl to contrib.url(repos, type); passing contriburl = NULL explicitly
  # overrides that default with nothing to read and yields an EMPTY index - which would
  # make every avail_ver NA, so online never upgrades and the success check below silently
  # degrades to mere presence. Let the default stand in the online (repos-only) case.
  avail <- if (is.null(contriburl))
    available.packages(repos = repos, type = type)
  else
    available.packages(contriburl = contriburl, type = type)
  avail_ver <- stats::setNames(avail[, "Version"], rownames(avail))

  # Current installed version of a package, or NA if not installed.
  cur_version <- function(pkg) {
    v <- tryCatch(as.character(utils::packageVersion(pkg)), error = function(e) NA_character_)
    v
  }
  # TRUE if pkg should be (re)installed: missing, or the repo has a strictly newer version.
  # A package not in the repo (avail NA) but already installed is left as-is.
  needs_action <- function(pkg, cur) {
    if (is.na(cur)) return(TRUE)                       # not installed
    av <- avail_ver[pkg]
    if (is.na(av)) return(FALSE)                       # not in repo -> can't upgrade
    package_version(av) > package_version(cur)
  }

  to_process <- packages[vapply(packages, function(p) needs_action(p, cur_version(p)),
                                logical(1))]

  if (length(to_process) == 0) {
    cat("All requested packages are already installed and up to date.\n")
    return(invisible(character(0)))
  }

  # install.packages writes to (and packageVersion/find.package above read from) the first
  # entry of .libPaths(). The dispatch code below sets that from R_INSTALL_LIB when given,
  # so installs land in the chosen library; pass it explicitly here so the target is
  # unambiguous at the call site.
  target_lib <- .libPaths()[1]
  cat("Installing/upgrading", length(to_process), "package(s) into", target_lib, "\n")
  dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
  log_file <- file.path(log_dir, "package_installation_log.txt")
  cat("Installation started at", format(Sys.time()), "\n", file = log_file)

  # keep_outputs saves each build's full output (the R CMD INSTALL log, including
  # compiler errors and "dependency 'X' not available" messages) to <pkg>.out in this
  # directory. We keep these only for packages that fail, so the actual reason is
  # reviewable, without scattering an .out for every one of hundreds of successes.
  out_dir <- file.path(log_dir, "install_logs")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  install_one <- function(pkg) {
    if (is.null(contriburl)) {
      install.packages(pkg, lib = target_lib, repos = repos, type = type,
                       dependencies = dependencies, keep_outputs = out_dir)
    } else {
      install.packages(pkg, lib = target_lib, repos = repos, contriburl = contriburl,
                       type = type, dependencies = dependencies, keep_outputs = out_dir)
    }
  }

  failed <- character(0)
  for (pkg in to_process) {
    # Re-check at loop time against the CURRENT installed version: because each
    # install.packages call uses dependencies=TRUE, an earlier entry may have already
    # brought this package in (at the repo version) as a dependency - in which case it is
    # now current and is skipped rather than needlessly rebuilt.
    cur <- cur_version(pkg)
    if (!needs_action(pkg, cur)) {
      cat("Already up to date (skipping):", pkg, "\n")
      cat("ALREADY INSTALLED:", pkg, "\n", file = log_file, append = TRUE)
      next
    }
    cat("Installing package:", pkg, "\n")
    before <- list.files(out_dir, pattern = "\\.out$")
    # A failed source build makes install.packages emit a *warning* ("had non-zero
    # exit status"), not an error, so tryCatch alone would miss it - and there can be
    # several warnings (the informative "dependency not available" plus the generic
    # one). Capture them all, then decide success by the installed version afterwards
    # (the authoritative check); the full build log is in <pkg>.out.
    msgs <- character(0)
    withCallingHandlers(
      tryCatch(install_one(pkg), error = function(e) msgs <<- c(msgs, conditionMessage(e))),
      warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") }
    )
    new_outs <- setdiff(list.files(out_dir, pattern = "\\.out$"), before)

    # Success = present afterwards AND, when the repo lists it, at >= the repo version -
    # so a failed *upgrade* that leaves the older version in place is not a false SUCCESS.
    after <- cur_version(pkg)
    av <- avail_ver[pkg]
    ok <- !is.na(after) && (is.na(av) || package_version(after) >= package_version(av))
    if (ok) {
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
    cat(length(failed), "of", length(to_process), "failed:",
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

# Resolve the Bioconductor repository URLs (BioCsoft/BioCann/BioCexp/BioCworkflows +
# CRAN) for the TARGET R version, using BiocManager. The Bioconductor release is tied
# to the R version, so the tarballs must come from the release matching the *target* R
# (the air-gapped/new R), not necessarily the machine running the download. Resolution:
#   1. explicit bioc_version (TARGET_BIOC_VERSION) always wins;
#   2. else, if the running R == target R, let BiocManager pick the running R's release;
#   3. else stop and ask for TARGET_BIOC_VERSION (we cannot guess another R's release).
# (A future enhancement could auto-map target R -> Bioc via BiocManager:::.version_map().)
bioc_repositories <- function(target_R, bioc_version = "") {
  if (!requireNamespace("BiocManager", quietly = TRUE)) {
    stop("BiocManager is required to resolve Bioconductor packages, but is not installed.\n",
         "  Install it (install.packages(\"BiocManager\")), or remove the Bioconductor\n",
         "  packages from the list / set their Repository to CRAN.")
  }
  same_R <- identical(as.character(target_R), as.character(getRversion()))
  if (nzchar(bioc_version)) {
    BiocManager::repositories(version = bioc_version)
  } else if (same_R) {
    BiocManager::repositories()                       # running R's Bioconductor release
  } else {
    stop("Download R (", as.character(getRversion()), ") differs from TARGET_R_VERSION (",
         target_R, "), so the matching Bioconductor release is unknown.\n",
         "  Set TARGET_BIOC_VERSION to the Bioconductor release for the target R ",
         "(e.g. 3.20).")
  }
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
  # write_PACKAGES opens every .tar.gz in DIST to read its DESCRIPTION, so for a large
  # repository (hundreds/thousands of tarballs) this step runs for a while with no output.
  # Announce it up front so a long, silent index build doesn't look like a hang.
  n_tarballs <- length(list.files(dist_dir, pattern = "\\.tar\\.gz$"))
  cat("Indexing DIST at", normalizePath(dist_dir), "-", n_tarballs,
      "tarball(s) to scan; this can take a few minutes for a large repository ...\n")
  utils::flush.console()
  invisible(tools::write_PACKAGES(dist_dir, type = "source"))
}

# download: fetch source tarballs for the list + hard deps into DIST, then index it.
# Resolves against CRAN, and - when the list contains Bioconductor packages (Repository
# column) - the matching Bioconductor repositories too, so the cross-repo dependency
# closure (Bioc deps on CRAN and vice versa) lands in one flat DIST. Re-runnable: by
# default skips any package whose exact-version tarball is already in DIST (set
# OVERWRITE=1 to re-fetch everything). Writes a reviewable download_log.txt recording
# what was requested, resolved, skipped, downloaded, dropped (CRAN vs Bioconductor), and
# any download failures. Takes pkg_df = data.frame(Package, Repository).
download_packages <- function(pkg_df, dist_dir, log_dir = "build/package_install") {
  packages <- pkg_df$Package
  bioc_requested <- pkg_df$Package[pkg_df$Repository == "Bioconductor"]
  use_bioc       <- length(bioc_requested) > 0

  cran    <- Sys.getenv("CRAN_REPO", "https://cran.r-project.org")
  target_R <- Sys.getenv("TARGET_R_VERSION", as.character(getRversion()))
  target_os <- Sys.getenv("TARGET_OS", "linux")
  os_type <- os_type_for(target_os)
  bioc_version <- Sys.getenv("TARGET_BIOC_VERSION", "")

  include_suggests <- tolower(Sys.getenv("INCLUDE_SUGGESTS", "")) %in% c("1", "true", "yes")
  overwrite        <- tolower(Sys.getenv("OVERWRITE", "")) %in% c("1", "true", "yes")

  # Build a record of this run: say() prints to the console AND logs; log_only() writes
  # to the log alone (used for the full long name lists we don't want to spam stdout).
  log_lines <- character(0)
  log_only <- function(line) log_lines[[length(log_lines) + 1L]] <<- line
  say      <- function(line) { cat(line, "\n"); log_only(line) }

  # Combined repository set: CRAN always; Bioconductor repos only when the list contains
  # Bioconductor packages (so all-CRAN / legacy single-column lists never need BiocManager).
  repos <- c(CRAN = cran)
  if (use_bioc) {
    bioc_repos <- bioc_repositories(target_R, bioc_version)
    # Honor the operator's CRAN_REPO for CRAN; take the BioC* URLs from BiocManager.
    repos <- c(repos, bioc_repos[setdiff(names(bioc_repos), "CRAN")])
  }

  say(paste("Download started at", format(Sys.time())))
  say(paste("Download repository (CRAN):", cran))
  if (use_bioc) {
    say(paste(length(bioc_requested), "Bioconductor package(s) requested."))
    say(paste("Bioconductor repositories:",
              paste(repos[setdiff(names(repos), "CRAN")], collapse = ", ")))
  } else {
    say("Bioconductor: none requested (CRAN-only resolution).")
  }
  say(paste("Resolving packages for R", target_R, "(override via TARGET_R_VERSION)"))
  say(paste0("Resolving packages for OS ", target_os, " [OS_type=", os_type,
             "] (override via TARGET_OS)"))
  say(paste("Suggests:", if (include_suggests)
        "included for listed packages (INCLUDE_SUGGESTS set)"
      else "excluded (set INCLUDE_SUGGESTS=1 to include)"))
  say(paste("Re-download existing tarballs:", if (overwrite)
        "yes (OVERWRITE set)" else "no - skip already-present (set OVERWRITE=1 to force)"))

  ap <- available.packages(repos = repos, type = "source",
                           filters = target_filters(target_R, os_type))

  # Drop names not available as source in the resolved repos (base packages, typos,
  # GitHub/local-only packages, or - for a Bioc name - the wrong Bioc release). The full
  # list goes to the log, split by declared repository so a genuine Bioconductor miss is
  # distinguishable from a CRAN one.
  wanted  <- intersect(packages, rownames(ap))
  dropped <- setdiff(packages, wanted)
  if (length(dropped) > 0) {
    dropped_bioc <- intersect(dropped, bioc_requested)
    dropped_cran <- setdiff(dropped, dropped_bioc)
    say(paste(length(dropped), "of", length(packages),
              "requested packages not available as source for the target R/OS (skipped)."))
    if (length(dropped_cran) > 0)
      log_only(paste("  dropped (CRAN, not in index):",
                     paste(sort(dropped_cran), collapse = ", ")))
    if (length(dropped_bioc) > 0) {
      log_only(paste("  dropped (Bioconductor, not in index - check TARGET_BIOC_VERSION):",
                     paste(sort(dropped_bioc), collapse = ", ")))
      cat("  WARNING:", length(dropped_bioc), "Bioconductor package(s) not found in the",
          "resolved Bioc release - check TARGET_BIOC_VERSION (see download_log.txt)\n")
    }
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
    got <- download.packages(to_download, destdir = dist_dir, repos = repos, type = "source")
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

  dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
  log_file <- file.path(log_dir, "download_log.txt")
  writeLines(log_lines, log_file)
  cat("\nDownload summary written to", log_file, "\n")
  cat("Next: copy this DIST folder to the air-gapped target, then run:\n")
  cat("  DIST_DIR=", dist_dir, " Rscript ", self, " offline <list_file>\n", sep = "")
}

# offline: install from the local DIST repo (file://), no network. Bioconductor packages
# need no special handling here: once their source tarballs are in DIST (put there by the
# download step) and indexed, they install like any other source package by name. Takes a
# character vector of package names.
install_offline <- function(packages, dist_dir, log_dir = "build/package_install") {
  if (!dir.exists(dist_dir)) {
    stop("DIST folder '", dist_dir, "' does not exist. ",
         "Run the 'download' step first and copy DIST here (or set DIST_DIR).")
  }
  # Reindex DIST before installing so any tarballs added since the last index (e.g.
  # dropped in by hand) are picked up. This also rebuilds a missing PACKAGES file - so
  # a DIST that only ever received tarballs still installs without a separate step.
  # SKIP_REINDEX bypasses it when DIST is known unchanged since the download step (which
  # already wrote the index) - useful because reindexing a large DIST takes minutes. When
  # skipping, the PACKAGES index must already exist (we won't be creating it).
  skip_reindex <- tolower(Sys.getenv("SKIP_REINDEX", "")) %in% c("1", "true", "yes")
  if (skip_reindex) {
    if (!file.exists(file.path(dist_dir, "PACKAGES"))) {
      stop("SKIP_REINDEX is set but '", dist_dir, "' has no PACKAGES index. ",
           "Unset SKIP_REINDEX to build it (or run the 'index' mode first).")
    }
    cat("Skipping reindex (SKIP_REINDEX set); using the existing PACKAGES index in",
        normalizePath(dist_dir), "\n")
  } else {
    n_indexed <- index_dist(dist_dir)
    cat("Indexed", n_indexed, "package(s) in", normalizePath(dist_dir), "\n")
  }
  # download.packages writes tarballs (and write_PACKAGES the index) flat in DIST, so
  # point contriburl straight at DIST rather than letting install.packages append
  # the usual src/contrib path.
  repo <- paste0("file://", normalizePath(dist_dir))
  cat("Installing from local repository:", repo, "\n")

  # Skip requested packages that aren't in DIST. The 'download' step drops packages it
  # can't fetch (archived/removed from CRAN, GitHub/local-only, or a Bioc-release miss)
  # and only records them in download_log.txt - so without this filter, offline would
  # attempt each one, fail to find it in the local repo, and log it as FAILED, cluttering
  # failed_packages.txt with packages that were never installable offline. Filter them
  # out against the DIST index and report them as skipped instead. filters=character(0)
  # so a package that IS in DIST isn't hidden by an R-version/OS filter (a genuine
  # version mismatch surfaces as a clear install failure, not a phantom "missing").
  avail <- rownames(available.packages(contriburl = repo, type = "source",
                                       filters = character(0)))
  not_in_dist <- setdiff(packages, avail)
  in_dist     <- intersect(packages, avail)
  if (length(not_in_dist) > 0) {
    cat("Skipping ", length(not_in_dist),
        " requested package(s) not present in DIST (unavailable at download time):\n  ",
        paste(sort(not_in_dist), collapse = ", "), "\n", sep = "")
  }

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
  failed <- install_from_repo(in_dist, repos = repo, contriburl = repo, type = "source",
                              dependencies = deps, log_dir = log_dir)

  # Record the skipped packages in the run log too, as SKIPPED (distinct from build
  # FAILUREs), so the log is a complete account of what happened to every requested name.
  if (length(not_in_dist) > 0) {
    dir.create(log_dir, recursive = TRUE, showWarnings = FALSE)
    log_file <- file.path(log_dir, "package_installation_log.txt")
    cat("\n", length(not_in_dist), " package(s) SKIPPED (not present in DIST):\n",
        sep = "", file = log_file, append = TRUE)
    for (pkg in sort(not_in_dist))
      cat("SKIPPED (not in DIST):", pkg, "\n", file = log_file, append = TRUE)
  }
  failed
}

# online: install from CRAN, plus Bioconductor when the list contains Bioc packages.
# Takes pkg_df = data.frame(Package, Repository).
install_online <- function(pkg_df, log_dir = "build/package_install") {
  # In a non-interactive Rscript getOption("repos") is the unresolved "@CRAN@"
  # placeholder, which makes install.packages fail with "trying to use CRAN without
  # setting a mirror". Honor a real mirror if one is already configured (e.g. via
  # ~/.Rprofile), otherwise fall back to CRAN_REPO (default https://cran.r-project.org),
  # the same source download mode uses.
  repos <- getOption("repos")
  cran  <- if (!is.null(repos)) repos[["CRAN"]] else NULL
  if (is.null(cran) || is.na(cran) || !nzchar(cran) || cran == "@CRAN@") {
    cran  <- Sys.getenv("CRAN_REPO", "https://cran.r-project.org")
    repos <- c(CRAN = cran)
  }

  # When the list has Bioconductor packages, add the Bioc repositories for the running
  # (target) R. BiocManager is itself a CRAN package, so bootstrap it if absent - it may
  # be in the list but not installed yet when we get here.
  if (any(pkg_df$Repository == "Bioconductor")) {
    if (!requireNamespace("BiocManager", quietly = TRUE)) {
      cat("Bootstrapping BiocManager from CRAN ...\n")
      install.packages("BiocManager", repos = c(CRAN = cran))
    }
    bioc_repos <- BiocManager::repositories()        # running R's Bioconductor release
    repos <- c(repos, bioc_repos[setdiff(names(bioc_repos), "CRAN")])
    cat("Installing from CRAN + Bioconductor:\n  ",
        paste(repos, collapse = "\n  "), "\n", sep = "")
  } else {
    cat("Installing from CRAN:", repos[["CRAN"]], "\n")
  }
  install_from_repo(pkg_df$Package, repos = repos, log_dir = log_dir)
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

# LOG_DIR: where the log/output artifacts go (package_installation_log.txt, install_logs/,
# failed_packages.txt, download_log.txt). Default "build/package_install" - relative to CWD,
# so running the migration from a version directory lands logs in that R's
# build/package_install/ (kept separate from the R-build logs in build/r_install/); set
# LOG_DIR to override. DIST is unrelated and stays under DIST_DIR.
log_dir <- Sys.getenv("LOG_DIR", "build/package_install")

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

pkg_df <- read_package_list(pkg_list_file)

cat("Mode:", mode, "\n")
failed <- switch(mode,
       download = { download_packages(pkg_df, dist_dir, log_dir); character(0) },
       offline  = install_offline(pkg_df$Package, dist_dir, log_dir),
       online   = install_online(pkg_df, log_dir))

# Report final state (offline/online only; download installs nothing).
if (mode != "download") {
  installed_after <- rownames(installed.packages())
  cat("Total packages installed:", length(installed_after), "\n")

  if (length(failed) > 0) {
    # Write the failures as a package list in the SAME 2-column format the script reads
    # (Package<TAB>Repository), so they can be fed straight back in - keeping the
    # Repository tag means a failed Bioconductor package retried via this file is still
    # resolved against Bioconductor rather than silently dropped as CRAN.
    failed_file <- file.path(log_dir, "failed_packages.txt")
    failed_df <- pkg_df[match(failed, pkg_df$Package), c("Package", "Repository")]
    write.table(failed_df, failed_file, sep = "\t", row.names = FALSE, quote = FALSE)
    cat("\n", length(failed), " package(s) FAILED - summary in ",
        file.path(log_dir, "package_installation_log.txt"), ",",
        " full build output per failure in ", file.path(log_dir, "install_logs"),
        "/; names written to ", failed_file, ".\n", sep = "")
    prefix <- if (mode == "offline") paste0("DIST_DIR=", shQuote(dist_dir), " ") else ""
    cat("To retry only the failed packages, rerun:\n")
    cat("  ", prefix, "Rscript ", self, " ", mode, " ", failed_file, "\n", sep = "")
    cat("(To retry one package, put just its name under a \"Package\" header in a",
        " file and pass that file instead.)\n", sep = "")
  }
}
