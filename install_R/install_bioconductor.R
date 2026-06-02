

# set repositories
setRepositories(graphics=FALSE, ind=1:6)

# set mirror
local({r <- getOption("repos")
       r["CRAN"] <- "https://cloud.r-project.org"
       options(repos=r)
})

# install the latest bioconductor version
if (!require("BiocManager", quietly = TRUE))
    install.packages("BiocManager")
BiocManager::install(update=TRUE, ask=FALSE)

# Install Tidyverse packages
install.packages("tidyverse")



