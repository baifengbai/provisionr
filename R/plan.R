plan_installation <- function(packages, db, lib, installed_action) {
  if (installed_action == "skip") {
    skip <- .packages(TRUE, lib)
  } else {
    skip <- NULL
  }
  skip <- c(skip, base_packages())
  requested <- packages

  ## TODO: drop the setdiff here, which also drops the lib argument?
  msg <- setdiff(packages, c(db$all[, "Package"], skip))
  if (length(msg) > 0L) {
    stop(sprintf("Can't find installation candidate for: %s",
                 paste(msg, collapse=", ")))
  }

  packages <- setdiff(recursive_deps(packages, db$all), skip)
  msg <- setdiff(packages, db$all[, "Package"])
  if (length(msg) > 0L) {
    stop(sprintf("Can't find installation candidate for dependencies: %s",
                 paste(msg, collapse=", ")))
  }

  if (installed_action == "skip") {
    packages <- setdiff(packages, .packages(TRUE, lib))
  }

  binary <- packages %in% rownames(db$bin)

  if (installed_action == "upgrade" || installed_action == "upgrade_all") {
    if (installed_action == "upgrade") {
      check <- union(setdiff(packages, .packages(TRUE, lib)), requested)
    } else {
      check <- packages
    }
    packages <- check_version(check, lib, db)
  }

  compile <- rep_len(FALSE, length(packages))
  binary <- packages %in% rownames(db$bin)
  if (any(!binary)) {
    j <- match(packages[!binary], db$src[, "Package"])
    compile[!binary] <- db$src[j, "NeedsCompilation"] == "yes"
  }

  list(packages = packages,
       binary = binary,
       compile = compile)
}

check_installed_packages <- function(packages, lib, cols = NULL) {
  if (is.null(cols)) {
    cols <- c("Depends", "Imports")
  }
  ## TODO: this also suffers issues with upgraded "recommended"
  ## packages, version requirements, etc.  Possibly this could all be
  ## factored into it's own little thing.
  base <- base_packages()

  installed <- .packages(TRUE, lib)
  missing <- setdiff(setdiff(packages, base), installed)
  check <- setdiff(packages, c(missing, base))
  checked <- base

  while (length(check) > 0L) {
    p <- check[[1L]]
    desc <- find_description(p, lib)
    if (is.na(desc)) {
      missing <- c(missing, p)
      extra <- character(0)
    } else {
      deps <- parse_deps(na.omit(read.dcf(desc, cols)[1L, ]))
      ## add them to our package list:
      extra <- setdiff(deps, checked)
    }
    checked <- c(checked, p)
    check <- c(check[-1L], extra)
  }

  missing
}

find_description <- function(p, lib) {
  full <- file.path(lib, p, "DESCRIPTION")
  found <- file.exists(full)
  if (any(found)) {
    full[which(found)[[1L]]]
  } else {
    NA_character_
  }
}

## TODO: we need to drop recommended from here, unless I deal with the
## issue seen with Hmisc vs survival not working with R 3.3.2 unless
## survival (a recommended package) is manually updated.  So going
## through versions might fix things.
base_packages <- function() {
  rownames(installed.packages(priority = c("base", "recommended")))
}

recursive_deps <- function(x, db) {
  done <- character()
  base <- base_packages()
  cols <- c("Depends", "Imports", "LinkingTo")

  while (length(x) > 0L) {
    done <- c(done, x)
    deps <- parse_deps(na.omit(c(db[match(x, db[, "Package"]), cols])))
    x <- setdiff(deps, c(x, base))
  }

  sort(unique(done))
}

## TODO: memoise this because it's quite slow
available_packages <- function(repos, platform, version) {
  provisionr_log("download", "package database")

  if (!is.null(platform)) {
    platform <- match_value(platform, valid_platforms())
  }

  is_local <- grepl("^(/|file://)", repos)
  if (any(is_local)) {
    i <- file.exists(repos)
    if (any(i)) {
      repos[i] <- file_url(repos[i])
    }
  }

  url_src <- contrib_url(repos, "src", NULL)
  if (any(is_local)) {
    lapply(file_unurl(url_src[is_local]), drat_ensure_PACKAGES)
  }
  pkgs_src <- available.packages(contrib_url(repos, "src", NULL))
  if (is.null(platform) || platform == "linux") {
    pkgs_bin <- pkgs_src[integer(0), ]
  } else {
    version_str <- r_version_str(check_r_version(version), 2L)
    url_bin <- contrib_url(repos, platform, version_str)
    if (any(is_local)) {
      lapply(file_unurl(url_bin[is_local]), drat_ensure_PACKAGES)
    }
    pkgs_bin <- available.packages(url_bin)
  }
  extra <- setdiff(rownames(pkgs_bin), rownames(pkgs_src))
  if (length(extra) > 0L) {
    pkgs_all <- rbind(pkgs_src, pkgs_bin[extra, ])
  } else {
    pkgs_all <- pkgs_src
  }
  list(all = pkgs_all, src = pkgs_src, bin = pkgs_bin,
       platform = platform, version = version)
}

contrib_url <- function(repos, platform, version_str) {
  if (is.null(version_str)) {
    version_str <- r_version_str(check_r_version(version_str))
  }
  ## platform should be:
  ##   src
  ##   windows
  ##   macosx
  ##   macosx/mavericks
  if (platform == "src") {
    path <- "src/contrib"
  } else {
    path <- file.path("bin", platform, "contrib", version_str)
  }
  file.path(sub("/$", "", repos), path)
}

parse_deps <- function(x) {
  ## TODO: This does not support returning version numbers (so
  ## depending on particular versions of packages is not going to work
  ## here).
  ##
  ## Somewhere I had the version parsing thing; I will need that back
  ## soon.  For now this just strips version information entirely.
  ## This could be something good to push into remotes, perhaps?
  val <- unlist(strsplit(x, ","), use.names=FALSE)
  val <- gsub("(\\s|\\().*", "", trimws(val))
  val[val != "R"]
}

drat_ensure_PACKAGES <- function(path) {
  path_PACKAGES <- file.path(path, "PACKAGES")
  if (!file.exists(path_PACKAGES)) {
    dir.create(path, FALSE, TRUE)
    writeLines(character(0), path_PACKAGES)
  }
}

valid_platforms <- function() {
  c("windows", "macosx", "macosx/mavericks", "linux")
}

check_version <- function(packages, lib, db) {
  installed <- packages %in% .packages(TRUE, lib)
  if (any(installed)) {
    check <- packages[installed]
    v_installed <- setNames(numeric_version(
      vcapply(file.path(lib, check, "DESCRIPTION"), read.dcf, "Version")),
      check)
    binary <- check %in% rownames(db$bin)
    v_db <- setNames(character(length(check)), check)
    v_db[binary] <- db$bin[check[binary], "Version"]
    v_db[!binary] <- db$src[check[!binary], "Version"]
    v_db <- numeric_version(v_db)
    installed[installed] <- v_installed >= v_db
  }
  packages[!installed]
}