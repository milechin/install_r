# Script to install R packages from a list file

# Function to install missing packages
install_packages_from_file <- function(file_path = "installed_r_packages.txt") {
  # Check if file exists
  if (!file.exists(file_path)) {
    stop("Error: Package list file '", file_path, "' not found.")
  }
  
  # Read the package file
  cat("Reading package list from", file_path, "\n")
  pkg_data <- read.table(file_path, header = TRUE, sep = "\t", stringsAsFactors = FALSE)
  
  # Extract package names
  packages_to_install <- pkg_data$Package
  cat("Found", length(packages_to_install), "packages in the list.\n")
  
  # Get currently installed packages
  installed <- rownames(installed.packages())
  
  # Find packages that need to be installed
  missing_packages <- setdiff(packages_to_install, installed)
 
  # Katia: November 2025: For some reason the Matrix package that is installed by this time
  # comes from a wrong place and is significantly different from the Matrix package that comes
  # from the CRAN
  # Force to install the correct version of Matrix package
  install.packages("Matrix")


  # Install missing packages
  if (length(missing_packages) > 0) {
    cat("Installing", length(missing_packages), "missing packages...\n")
    
    # Create a log file for installation results
    log_file <- "package_installation_log.txt"
    cat("Installation started at", format(Sys.time()), "\n", file = log_file)
    
    # Install packages one by one and log results
    for (pkg in missing_packages) {
      cat("Installing package:", pkg, "\n")
      tryCatch({
        install.packages(pkg, dependencies = TRUE)
        cat("SUCCESS:", pkg, "\n", file = log_file, append = TRUE)
      }, error = function(e) {
        cat("FAILED:", pkg, "- Error:", conditionMessage(e), "\n", file = log_file, append = TRUE)
        cat("  Error installing", pkg, ":", conditionMessage(e), "\n")
      })
    }
    
    cat("Installation completed at", format(Sys.time()), "\n", file = log_file, append = TRUE)
    cat("Installation complete. See", log_file, "for details.\n")
  } else {
    cat("All packages from the list are already installed.\n")
  }
}

# Execute the function. An optional first command-line argument overrides the
# default package-list file:  Rscript install_packages.R [path/to/list.txt]
args <- commandArgs(trailingOnly = TRUE)
pkg_list_file <- if (length(args) >= 1) args[1] else "installed_r_packages.txt"
install_packages_from_file(pkg_list_file)

# Verify installation
installed_after <- rownames(installed.packages())
cat("Total packages installed:", length(installed_after), "\n")
