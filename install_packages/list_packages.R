# Script to list all installed R packages, tagging each with the repository it came
# from (CRAN vs Bioconductor) so the migration step (install_packages.R) can fetch
# Bioconductor packages from the right repositories.
#
# Classification is done OFFLINE from the installed package metadata: Bioconductor
# packages carry a non-empty "biocViews" field in their DESCRIPTION, CRAN packages do
# not. This needs no network access and no BiocManager on this (old) R. Packages
# installed from GitHub / local sources / r-universe generally carry no biocViews and
# so read as "CRAN"; if they are not actually on CRAN the migration will report them
# as dropped (acceptable - their source of truth is manual).

# Pull biocViews alongside the base fields. installed.packages() returns one row per
# (package, libpath), so a package present in more than one .libPaths() appears more
# than once - de-duplicated below.
ip <- as.data.frame(installed.packages(fields = "biocViews"), stringsAsFactors = FALSE)

repository <- ifelse(!is.na(ip$biocViews) & nzchar(trimws(ip$biocViews)),
                     "Bioconductor", "CRAN")

packages <- data.frame(Package = ip$Package, Repository = repository,
                       stringsAsFactors = FALSE)

# Keep one row per package name, then sort by name.
packages <- packages[!duplicated(packages$Package), ]
packages <- packages[order(packages$Package), ]

# Create output file
output_file <- "installed_r_packages.txt"

# Write package information to file: tab-separated, header "Package<TAB>Repository".
# install_packages.R reads this with read.table(header=TRUE, sep="\t").
write.table(
  packages,
  file = output_file,
  sep = "\t",
  row.names = FALSE,
  quote = FALSE
)

# Confirmation message
n_bioc <- sum(packages$Repository == "Bioconductor")
cat("Successfully listed", nrow(packages), "installed R packages in", output_file,
    "(", n_bioc, "Bioconductor,", nrow(packages) - n_bioc, "CRAN).\n")
