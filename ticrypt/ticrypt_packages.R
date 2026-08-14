# ticrypt_packages.R - move R packages into the air-gapped TICrypt environment.
#
# Researcher workflow (two steps, both run from the R console):
#
#   1. On an INTERNET-connected machine (your laptop, an SCC node, ...):
#        source("ticrypt_packages.R")
#        ticrypt_download(c("dplyr", "DESeq2"))
#      -> downloads the source tarballs for those packages PLUS every dependency,
#         and a copy of THIS script, into a folder (default ./ticrypt_packages).
#
#   2. Copy that one folder into TICrypt, then in TICrypt's R console:
#        source("ticrypt_packages/ticrypt_packages.R")
#        ticrypt_install()
#      -> compiles and installs the packages into your personal library. No network.
#
# Packages are downloaded as SOURCE and compiled inside TICrypt, so they work across
# small R differences but TICrypt must have a build toolchain (it does). Both CRAN and
# Bioconductor packages are supported - you do not need to say which is which.
#
# Run ticrypt_help() for a reminder of the steps.

# --- TICrypt target (RCS maintains these to match TICrypt's current R) -------
# The download usually runs on a different machine/R than TICrypt, so it cannot detect
# TICrypt's R itself. These constants tell ticrypt_download() which R/Bioconductor
# release to resolve packages for. Update them when TICrypt's R is upgraded.
TICRYPT_R_VERSION    <- "4.5.2"   # R version inside TICrypt
TICRYPT_BIOC_VERSION <- "3.22"    # Bioconductor release tied to that R
TICRYPT_OS           <- "linux"   # TICrypt operating system (linux | macos | windows)

DEFAULT_DIR <- "ticrypt_packages" # folder the download writes to / the install reads from
DEFAULT_CRAN <- "https://cran.r-project.org"

# Capture this script's own path AT SOURCE TIME (source() sets `ofile` on its frame).
# Done here, not inside a function, because the source frame is gone by the time the
# functions are called later. Used to copy the script into the download folder so the
# transferred folder is self-contained. NULL if the file was pasted, not source()d.
.TICRYPT_SELF <- local({
  path <- NULL
  for (i in seq_len(sys.nframe())) {
    of <- sys.frame(i)$ofile
    if (!is.null(of)) path <- of
  }
  if (!is.null(path)) normalizePath(path, mustWork = FALSE) else NULL
})

# --- internal helpers (adapted from install_packages/install_packages.R) -----

# Map an OS name to R's OS_type field ("unix" or "windows").
.ticrypt_os_type <- function(target_os) {
  switch(tolower(target_os),
         linux = "unix", macos = "unix", unix = "unix",
         windows = "windows", win = "windows",
         stop("Unsupported OS '", target_os, "' (use linux, macos, or windows)."))
}

# available.packages() filters that resolve the index against the TARGET R version and
# OS rather than whatever machine is running the download.
.ticrypt_filters <- function(target_R, os_type) {
  target_R <- as.package_version(target_R)
  r_version_filter <- function(db) {
    keep <- vapply(db[, "Depends"], function(d) {
      if (is.na(d) || !nzchar(d)) return(TRUE)
      m <- regmatches(d, regexpr("R *\\([^)]*\\)", d))
      if (length(m) == 0) return(TRUE)
      spec <- sub("R *\\(([^)]*)\\).*", "\\1", m)
      op  <- trimws(sub("^([<>=!]+).*", "\\1", spec))
      ver <- trimws(sub("^[<>=!]+", "", spec))
      ver <- tryCatch(as.package_version(ver), error = function(e) return(NA))
      if (is.na(ver)) return(TRUE)
      switch(op, ">=" = target_R >= ver, ">" = target_R > ver,
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

# CRAN + Bioconductor repository URLs for the target Bioconductor release. BiocManager is
# a CRAN package; bootstrap it (network) if absent, since we only need it for the repo URLs.
.ticrypt_repos <- function(cran, bioc_version) {
  if (!requireNamespace("BiocManager", quietly = TRUE)) {
    cat("Installing BiocManager (needed to locate the Bioconductor repositories) ...\n")
    install.packages("BiocManager", repos = c(CRAN = cran))
  }
  bioc <- BiocManager::repositories(version = bioc_version)
  # Use the requested CRAN mirror for CRAN; take the BioC* URLs from BiocManager.
  c(CRAN = cran, bioc[setdiff(names(bioc), "CRAN")])
}

# (Re)build the PACKAGES index so the folder is a self-contained local source repo.
.ticrypt_index <- function(dir) {
  n <- length(list.files(dir, pattern = "\\.tar\\.gz$"))
  cat("Indexing", n, "tarball(s) in", normalizePath(dir), "...\n")
  utils::flush.console()
  invisible(tools::write_PACKAGES(dir, type = "source"))
}

# Install named packages one at a time from a local file:// repo into `lib`, compiling
# from source. Version-aware: (re)install when missing or the repo is strictly newer;
# skip when already up to date. Success is judged by the installed version AFTERWARDS
# (a failed source build only warns, and never installs), not by tryCatch alone. Failed
# builds keep their full log as <dir>/install_logs/<pkg>.out. Returns the failed names.
.ticrypt_install_from_repo <- function(packages, repo, lib, dependencies, dir) {
  avail <- available.packages(contriburl = repo, type = "source")
  avail_ver <- stats::setNames(avail[, "Version"], rownames(avail))
  cur <- function(pkg)
    tryCatch(as.character(utils::packageVersion(pkg, lib.loc = lib)),
             error = function(e) NA_character_)
  needs <- function(pkg) {
    c <- cur(pkg)
    if (is.na(c)) return(TRUE)
    a <- avail_ver[pkg]
    if (is.na(a)) return(FALSE)
    package_version(a) > package_version(c)
  }

  out_dir <- file.path(dir, "install_logs")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  failed <- character(0)
  for (pkg in packages) {
    if (!needs(pkg)) { cat("  up to date, skipping:", pkg, "\n"); next }
    cat("Installing:", pkg, "\n"); utils::flush.console()
    before <- list.files(out_dir, pattern = "\\.out$")
    msgs <- character(0)
    withCallingHandlers(
      tryCatch(install.packages(pkg, lib = lib, repos = repo, contriburl = repo,
                                type = "source", dependencies = dependencies,
                                keep_outputs = out_dir),
               error = function(e) msgs <<- c(msgs, conditionMessage(e))),
      warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") }
    )
    new_outs <- setdiff(list.files(out_dir, pattern = "\\.out$"), before)
    after <- cur(pkg)
    av <- avail_ver[pkg]
    ok <- !is.na(after) && (is.na(av) || package_version(after) >= package_version(av))
    if (ok) {
      if (length(new_outs)) file.remove(file.path(out_dir, new_outs))  # keep only failures
    } else {
      failed <- c(failed, pkg)
      detail <- if (length(msgs)) paste(unique(trimws(msgs)), collapse = " | ")
                else "see build log"
      cat("  FAILED:", pkg, "-", detail, "\n")
    }
  }
  if (length(list.files(out_dir)) == 0) unlink(out_dir, recursive = TRUE)
  invisible(failed)
}

# Major.minor of a version ("4.5.2" -> "4.5"); Bioconductor and compiled-package
# compatibility track the R minor version, so that is the granularity we compare at.
.ticrypt_rmm <- function(v) paste(unclass(as.numeric_version(v))[[1]][1:2], collapse = ".")

# This system's Bioconductor release, determined WITHOUT the internet (TICrypt is
# air-gapped). BiocManager::version() derives the release from the running R via its
# bundled map, but it also tries to validate that online and warns/fails when it can't
# reach the network. So suppress that noise and, if it can't yield a clean "x.y" release,
# return NA - the caller then SKIPS the Bioconductor check rather than reporting a bogus
# "unknown version" mismatch. Returns NA when BiocManager is absent too.
.ticrypt_bioc_version <- function() {
  if (!requireNamespace("BiocManager", quietly = TRUE)) return(NA_character_)
  v <- suppressWarnings(suppressMessages(tryCatch(
    as.character(BiocManager::version()), error = function(e) NA_character_)))
  if (length(v) != 1L || is.na(v) || !grepl("^[0-9]+\\.[0-9]+$", v)) return(NA_character_)
  v
}

# This system's OS as a ticrypt_download() target_os value ("linux"/"macos"/"windows").
.ticrypt_os <- function() {
  sysname <- tryCatch(tolower(Sys.info()[["sysname"]]), error = function(e) "")
  switch(sysname, linux = "linux", darwin = "macos", windows = "windows",
         if (.Platform$OS.type == "windows") "windows" else "linux")
}

# Build a ready-to-copy ticrypt_download() call targeting THIS system - its R version and
# OS, its Bioconductor release when that can be determined offline, and pre-filled with the
# packages this folder requested (from REQUESTED.txt). Printed on a version mismatch so the
# researcher can copy it verbatim to the internet machine and re-download a compatible set.
# Laid out one argument per line so it is easy to select and paste.
.ticrypt_download_command <- function(dir) {
  req  <- file.path(dir, "REQUESTED.txt")
  pkgs <- if (file.exists(req)) readLines(req) else character(0)
  pkgs <- pkgs[nzchar(pkgs)]
  pkg_arg <- if (length(pkgs))
    paste0("c(", paste0('"', pkgs, '"', collapse = ", "), ")") else 'c("<your packages>")'
  bioc <- .ticrypt_bioc_version()
  args <- c(pkg_arg,
            sprintf('target_r = "%s"', as.character(getRversion())),
            sprintf('target_os = "%s"', .ticrypt_os()))
  if (!is.na(bioc)) args <- c(args, sprintf('bioc_version = "%s"', bioc))
  body <- paste0("      ", args, c(rep(",", length(args) - 1L), ""), collapse = "\n")
  paste0("    ticrypt_download(\n", body, "\n    )")
}

# Verify (inside TICrypt) that the R/Bioconductor being installed into matches what the
# download was resolved for, using the TICRYPT_TARGET.dcf the download wrote. Stops on a
# mismatch unless force = TRUE. R (the hard gate) is compared at major.minor. Bioconductor
# is best-effort: it's only compared when this system's release can be determined offline
# (see .ticrypt_bioc_version); otherwise it's skipped with a note, since the R match already
# implies the Bioc release (they are locked together).
.ticrypt_check_target <- function(dir, force) {
  meta_file <- file.path(dir, "TICRYPT_TARGET.dcf")
  if (!file.exists(meta_file)) {
    cat("NOTE: target versions not recorded in this folder (older download);",
        "skipping compatibility check.\n")
    return(invisible())
  }
  meta <- as.list(read.dcf(meta_file)[1, ])
  mism <- list()   # each: c(label, expected, actual)

  if (!is.null(meta$RVersion) && !is.na(meta$RVersion)) {
    want <- .ticrypt_rmm(meta$RVersion); have <- .ticrypt_rmm(getRversion())
    if (!identical(want, have)) mism[[length(mism) + 1]] <- c("R", want, have)
  }
  if (!is.null(meta$BiocVersion) && !is.na(meta$BiocVersion) && nzchar(meta$BiocVersion)) {
    have_bioc <- .ticrypt_bioc_version()
    if (is.na(have_bioc)) {
      cat("NOTE: could not determine this system's Bioconductor release (BiocManager",
          "absent, or it needs the internet to validate - unavailable in TICrypt);",
          "skipping the Bioconductor check and relying on the R version match.",
          "Recorded target:", meta$BiocVersion, "\n")
    } else if (!identical(as.character(meta$BiocVersion), have_bioc)) {
      mism[[length(mism) + 1]] <- c("Bioconductor", as.character(meta$BiocVersion), have_bioc)
    }
  }

  if (length(mism) == 0) {
    have_bioc <- .ticrypt_bioc_version()
    cat("Environment matches download target (R ", .ticrypt_rmm(getRversion()),
        if (!is.na(have_bioc)) paste0(", Bioconductor ", have_bioc) else "",
        ").\n", sep = "")
    return(invisible())
  }

  lines <- vapply(mism, function(m) sprintf("  - %s: downloaded for %s, but this system is %s",
                                            m[1], m[2], m[3]), character(1))
  if (force) {
    cat("WARNING: proceeding despite an environment mismatch (force = TRUE):\n",
        paste(lines, collapse = "\n"), "\n", sep = "")
    return(invisible())
  }
  # Print the full guidance (including a copy-pasteable command) via cat so the command
  # block stays clean, then stop() with a short one-line error.
  cat("\nThis folder was downloaded for a different environment than this system:\n",
      paste(lines, collapse = "\n"), "\n\n",
      "The packages may fail to build or be incompatible.\n\n",
      "To download a matching set, run this on an internet-connected machine (where\n",
      "ticrypt_packages.R lives), then copy the folder back here and re-run ticrypt_install():\n\n",
      .ticrypt_download_command(dir), "\n\n",
      "Or, to install these packages anyway despite the mismatch:\n\n",
      "    ticrypt_install(force = TRUE)\n\n", sep = "")
  stop("environment does not match the download target (see the command shown above).",
       call. = FALSE)
}

# --- researcher-facing functions -------------------------------------------

#' Download packages (+ dependencies) for transfer into TICrypt.
#'
#' @param packages character vector of package names (CRAN or Bioconductor).
#' @param dir      output folder (default ./ticrypt_packages); created if missing.
#' @param suggests also fetch the named packages' Suggests (default FALSE = hard deps only).
#' @param target_r,bioc_version,target_os  the TICrypt target (default the TICRYPT_* constants).
#' @param cran     CRAN mirror (default https://cran.r-project.org).
#' @param self     path to this script to copy into `dir` (default: auto-detected).
ticrypt_download <- function(packages, dir = DEFAULT_DIR, suggests = FALSE,
                             target_r = TICRYPT_R_VERSION,
                             bioc_version = TICRYPT_BIOC_VERSION,
                             target_os = TICRYPT_OS, cran = DEFAULT_CRAN,
                             self = .TICRYPT_SELF) {
  stopifnot(is.character(packages), length(packages) > 0)
  os_type <- .ticrypt_os_type(target_os)
  cat("Resolving", length(packages), "package(s) for TICrypt R", target_r,
      "/ Bioconductor", bioc_version, "/", target_os, "\n")

  repos <- .ticrypt_repos(cran, bioc_version)
  ap <- available.packages(repos = repos, type = "source",
                           filters = .ticrypt_filters(target_r, os_type))

  wanted  <- intersect(packages, rownames(ap))
  dropped <- setdiff(packages, rownames(ap))
  if (length(dropped) > 0) {
    cat("\n  WARNING: not found for TICrypt R", target_r,
        "(skipped - check spelling, or that the package exists on CRAN/Bioconductor",
        bioc_version, "):\n    ", paste(sort(dropped), collapse = ", "), "\n\n", sep = " ")
  }
  if (length(wanted) == 0) stop("None of the requested packages are available - nothing to download.")

  hard <- c("Depends", "Imports", "LinkingTo")
  deps <- unlist(tools::package_dependencies(wanted, db = ap, recursive = TRUE, which = hard),
                 use.names = FALSE)
  closure <- unique(c(wanted, deps))
  if (suggests) {
    sug <- unlist(tools::package_dependencies(wanted, db = ap, recursive = FALSE, which = "Suggests"),
                  use.names = FALSE)
    sug <- intersect(sug, rownames(ap))
    sug_deps <- unlist(tools::package_dependencies(sug, db = ap, recursive = TRUE, which = hard),
                       use.names = FALSE)
    closure <- unique(c(closure, sug, sug_deps))
  }
  closure <- intersect(closure, rownames(ap))
  cat("Resolved", length(wanted), "requested ->", length(closure),
      "package(s) including dependencies.\n")

  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  # Re-runnable: skip tarballs whose exact version is already present.
  expected <- paste0(closure, "_", ap[closure, "Version"], ".tar.gz")
  to_get <- closure[!file.exists(file.path(dir, expected))]
  if (length(to_get) > 0) {
    cat("Downloading", length(to_get), "tarball(s) into", normalizePath(dir), "...\n")
    got <- download.packages(to_get, destdir = dir, repos = repos, type = "source")
    miss <- setdiff(to_get, got[, 1])
    if (length(miss) > 0)
      cat("  WARNING: failed to download:", paste(sort(miss), collapse = ", "), "\n")
  } else {
    cat("All needed tarballs already present in", normalizePath(dir), "\n")
  }

  # Record the requested (resolved) names so the install step knows what to install.
  writeLines(sort(wanted), file.path(dir, "REQUESTED.txt"))

  # Record the target these tarballs were resolved for, so ticrypt_install() can verify
  # (on the TICrypt side) that the R/Bioconductor it is installing into actually matches.
  write.dcf(data.frame(
    RVersion = target_r, BiocVersion = bioc_version, OS = target_os,
    DownloadedUnderR = as.character(getRversion()), Date = format(Sys.Date()),
    stringsAsFactors = FALSE
  ), file.path(dir, "TICRYPT_TARGET.dcf"))
  cat("Recorded download target (R", target_r, "/ Bioconductor", bioc_version, ") in",
      file.path(dir, "TICRYPT_TARGET.dcf"), "\n")

  .ticrypt_index(dir)

  # Copy this script into the folder so the transferred folder is self-contained.
  if (!is.null(self) && file.exists(self)) {
    file.copy(self, file.path(dir, "ticrypt_packages.R"), overwrite = TRUE)
  } else {
    cat("  NOTE: could not auto-locate ticrypt_packages.R to copy into the folder.\n",
        "       Copy it in by hand so TICrypt has the installer.\n", sep = "")
  }

  cat("\nDone. Next steps:\n",
      "  1. Copy the folder '", dir, "' into TICrypt.\n",
      "  2. In TICrypt's R console:\n",
      "       source(\"", dir, "/ticrypt_packages.R\")\n",
      "       ticrypt_install()\n", sep = "")
  invisible(wanted)
}

#' Install the downloaded packages inside TICrypt (no network).
#'
#' @param dir folder produced by ticrypt_download and copied into TICrypt.
#' @param lib library to install into (default: your personal library, .libPaths()[1]).
#' @param suggests set TRUE only if you ran ticrypt_download(..., suggests = TRUE).
#' @param force install even if this TICrypt R / Bioconductor does not match the versions
#'   the folder was downloaded for (default FALSE = stop on a mismatch).
ticrypt_install <- function(dir = DEFAULT_DIR, lib = .libPaths()[1], suggests = FALSE,
                            force = FALSE) {
  if (!dir.exists(dir)) stop("Folder '", dir, "' not found. Copy it in from the download step.")
  req_file <- file.path(dir, "REQUESTED.txt")
  if (!file.exists(req_file))
    stop("'", req_file, "' missing - is this a folder produced by ticrypt_download()?")
  requested <- readLines(req_file)

  # Fail fast on an R/Bioconductor mismatch before creating or installing anything.
  .ticrypt_check_target(dir, force)

  dir.create(lib, recursive = TRUE, showWarnings = FALSE)
  if (file.access(lib, mode = 2) != 0) stop("Library '", lib, "' is not writable.")
  .libPaths(c(lib, .libPaths()))   # install into, and check against, this library first

  .ticrypt_index(dir)              # pick up any tarballs added by hand
  repo <- paste0("file://", normalizePath(dir))

  # Only attempt packages that are actually in the folder (a dropped/undownloaded one
  # would otherwise fail noisily). filters = none -> pure presence, no R/OS filter.
  in_dir <- rownames(available.packages(contriburl = repo, type = "source", filters = character(0)))
  install_set <- intersect(requested, in_dir)
  missing <- setdiff(requested, in_dir)
  if (length(missing) > 0)
    cat("Skipping (not in folder):", paste(sort(missing), collapse = ", "), "\n")

  cat("Installing", length(install_set), "package(s) into", lib, "(compiling from source) ...\n")
  deps <- if (suggests) TRUE else c("Depends", "Imports", "LinkingTo")
  failed <- .ticrypt_install_from_repo(install_set, repo = repo, lib = lib,
                                       dependencies = deps, dir = dir)

  if (length(failed) > 0) {
    cat("\n", length(failed), "package(s) FAILED to install:\n    ",
        paste(sort(failed), collapse = ", "), "\n",
        "  Build logs: ", file.path(dir, "install_logs"), "/<pkg>.out\n", sep = "")
  } else {
    cat("\nAll requested packages installed successfully into", lib, "\n")
  }
  invisible(failed)
}

#' Print the two-step workflow.
ticrypt_help <- function() {
  cat(
    "ticrypt_packages - move R packages into TICrypt\n\n",
    "On an INTERNET-connected machine:\n",
    "  source(\"ticrypt_packages.R\")\n",
    "  ticrypt_download(c(\"dplyr\", \"DESeq2\"))\n\n",
    "Then copy the 'ticrypt_packages' folder into TICrypt and run there:\n",
    "  source(\"ticrypt_packages/ticrypt_packages.R\")\n",
    "  ticrypt_install()\n\n",
    "Both CRAN and Bioconductor packages are supported; dependencies come along\n",
    "automatically. Use ticrypt_download(..., suggests = TRUE) to also include\n",
    "Suggests (and ticrypt_install(suggests = TRUE) to match).\n", sep = "")
  invisible(NULL)
}

if (identical(environment(), globalenv())) {
  cat("ticrypt_packages loaded. Run ticrypt_help() for usage.\n")
}
