# Script to list all installed R packages

# Get all installed packages
packages <- as.data.frame(installed.packages()[, c("Package", "Version", "LibPath")])

# Sort packages by name
packages <- packages[order(packages$Package), ]

# Create output file
output_file <- "installed_r_packages.txt"

# Write package information to file
write.table(
  packages[1], 
  file = output_file, 
  row.names = FALSE, 
  quote = FALSE
)

# Confirmation message
cat("Successfully listed", nrow(packages), "installed R packages in", output_file, "\n")
