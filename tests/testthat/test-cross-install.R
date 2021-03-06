context("cross_install")

test_that("binary cross install", {
  lib <- tempfile()
  db <- package_database(c(CRAN = "https://cran.rstudio.com"), "windows", NULL,
                         progress = FALSE)
  packages <- "zip"
  plan <- plan_installation(packages, db, lib, "upgrade")
  res <- cross_install_packages("zip", lib, db, plan, progress = FALSE)
  expect_equal(dir(lib), "zip")
  expect_true(file.exists(file.path(lib, "zip", "libs", "x64", "zip.dll")))
})

test_that("binary cross install with deps", {
  lib <- tempfile()
  db <- package_database(c(CRAN = "https://cran.rstudio.com"),
                         "windows", NULL, progress = FALSE)
  packages <- "devtools"
  plan <- plan_installation(packages, db, lib, "upgrade")
  res <- cross_install_packages(packages, lib, db, plan, progress = FALSE)
  expect_true("devtools" %in% dir(lib))
  expect_true("httr" %in% dir(lib))
  expect_true(file.exists(
    file.path(lib, "git2r", "libs", "x64", "git2r.dll")))

  dat <- check_library("devtools", lib)
  expect_equal(dat$missing, character(0))
  expect_true("httr" %in% dat$found)

  unlink(file.path(lib, "httr"), recursive = TRUE)
  unlink(file.path(lib, "curl"), recursive = TRUE)

  dat <- check_library("devtools", lib)
  expect_true("httr" %in% dat$missing)

  p1 <- plan_installation("httr", db, lib, "skip")
  expect_equal(p1$packages, c("curl", "httr"))
  p2 <- plan_installation("httr", db, lib, "upgrade")
  expect_equal(p2, p1)
  p3 <- plan_installation("httr", db, lib, "upgrade_all")
  expect_equal(p3, p1)
  p4 <- plan_installation("httr", db, lib, "replace")
  expect_gt(length(p4$packages), length(p1$packages))
  expect_true(all(p1$packages %in% p4$packages))

  ## Bit of fiddling with version numbers:
  alter_package_version(file.path(lib, "openssl"), increase = FALSE)

  q1 <- plan_installation("httr", db, lib, "skip")
  expect_equal(q1, p1)
  q2 <- plan_installation("httr", db, lib, "upgrade")
  expect_equal(q2, p2)
  q3 <- plan_installation("httr", db, lib, "upgrade_all")
  expect_equal(sort(q3$packages), sort(c(p3$packages, "openssl")))
  q4 <- plan_installation("httr", db, lib, "replace")
  expect_equal(q4, p4)

  ## And again, with the next package up:
  r1 <- plan_installation("devtools", db, lib, "skip")
  expect_equal(r1, p1)
  r2 <- plan_installation("devtools", db, lib, "upgrade")
  expect_equal(r2, p2)
  r3 <- plan_installation("devtools", db, lib, "upgrade_all")
  expect_equal(r3, q3)
  r4 <- plan_installation("devtools", db, lib, "replace")
  expect_gt(length(r4$packages), length(p4$packages))
  expect_true(all(p4$packages %in% r4$packages))
})

test_that("cross install source package", {
  lib <- tempfile()

  ## This is never going on CRAN and has no nasty dependencies:
  src <- package_sources(github = "richfitz/kitten")
  src$local_drat <- tempfile()
  src$build(progress = FALSE)
  provision_library("kitten", lib, platform = "windows", src = src,
                    progress = FALSE)
  expect_equal(dir(lib), "kitten")
})

## This deals with an issue where an `importFrom` directive in a
## NAMESPACE file causes lazyloading of source files that depend on
## binary files to fail
test_that("cross install package that triggers load", {
  skip_on_travis()
  src <- package_sources(local = "lazyproblem")
  drat <- src$build(progress = FALSE)

  lib_us <- tempfile()
  lib_other <- tempfile()
  on.exit(unlink(c(lib_us, lib_other), recursive = TRUE))

  ## Need to get a copy of a binary package that will conflict loaded
  ## for lazyloading to fail.
  provision_library("zip", lib_us, quiet = TRUE, progress = FALSE)
  expect_true("zip" %in% dir(lib_us))

  ## TODO: consider doing the target platform differently here; go with
  ##
  ##   platform_other <- if (is_windows()) "macosx/mavericks" else "windows"
  ##
  ## but I think that requires a bit more support and to make sure
  ## that the mac local cran is downloaded.
  platform_other <- "windows"
  withr::with_libpaths(
    lib_us,
    provision_library("lazyproblem", lib_other, platform = platform_other,
                      src = drat, progress = FALSE))

  pkgs <- .packages(TRUE, lib_other)
  expect_equal(sort(pkgs), sort(c("zip", "lazyproblem")))
})

test_that("installed_action", {
  lib <- tempfile()

  msgs <- capture_messages(
    provision_library("zip", lib, platform = "windows", progress = FALSE))
  expect_true(any(grepl("cross", msgs)))
  expect_true("zip" %in% dir(lib))

  ## Skip reinstallation:
  msgs <- capture_messages(
    provision_library("zip", lib, platform = "windows",
                      installed_action = "skip", progress = FALSE))
  expect_false(any(grepl("cross", msgs)))

  ## Upgrade (but don't)
  msgs <- capture_messages(
    provision_library("zip", lib, platform = "windows",
                      installed_action = "upgrade", progress = FALSE))
  expect_false(any(grepl("cross", msgs)))

  ## Upgrade (but do) -- this does not work!
  alter_package_version(file.path(lib, "zip"), FALSE)
  msgs <- capture_messages(
    provision_library("zip", lib, platform = "windows",
                      installed_action = "upgrade", progress = FALSE))
  expect_true(any(grepl("cross", msgs)))

  ## Replace:
  msgs <- capture_messages(
    provision_library("zip", lib, platform = "windows",
                      installed_action = "replace", progress = FALSE))
  expect_true(any(grepl("cross", msgs)))
})

test_that("missing compiled packages", {
  ## This is unlikely to resolve itself any time soon; not on CRAN and
  ## dependent on two other packages that are not on CRAN that require
  ## compilation (dde, ring) and one that does not require compilation
  ## (rcmdshlib).
  ##
  ## TODO: cache the calls here, possibly across sessions?
  src <- package_sources(github = "richfitz/dde")
  drat <- src$build(progress = FALSE)

  ## NOTE: This triggers the lazy loading issue that I had in context
  ## (and had solved there at some point) where lazy loading of one
  ## package triggers a failure in the package installation.
  path <- tempfile()
  expect_error(provision_library("dde", path, platform = "windows", src = drat,
                                 progress = FALSE),
               "Packages need compilation")
  ans <- provision_library("dde", path, platform = "windows", src = drat,
                           allow_missing = TRUE, progress = FALSE)
  expect_equal(sort(rownames(ans$missing)),
               sort(c("dde", "ring")))
})

test_that("prefer drat files", {
  ## TODO: this can actually point at the source file already in the
  ## same repo.
  src <- package_sources(github = "r-lib/zip@8a5496")
  drat <- src$build(progress = FALSE)
  path <- tempfile()
  ans <- provision_library("zip", path, platform = "windows", src = drat,
                           allow_missing = TRUE, progress = FALSE)
  expect_equal(rownames(ans$missing), "zip")
  expect_equal(dir(path), character(0))
})

test_that("don't cross install locally", {
  expect_error(cross_install_packages("zip", .libPaths()[[1]]),
               "Do not use cross_install_packages to install into current")
})

test_that("missing packages", {
  lib <- tempfile()
  db <- package_database(c(CRAN = "https://cran.rstudio.com"), "windows", NULL,
                         progress = FALSE)

  expect_error(plan_installation("foobar", db, lib, "skip"),
               "Can't find installation candidate for: foobar")

  ## Filter some dependencies off of my lists:
  db2 <- db
  for (i in c("bin", "src", "all")) {
    db2[[i]] <- db2[[i]][rownames(db2[[i]]) != "curl", , drop = FALSE]
  }

  expect_error(plan_installation("httr", db2, lib, "skip"),
               "Can't find installation candidate for dependencies: curl")
})

test_that("remove existing packages on upgrade", {
  packages <- "zip"
  lib <- tempfile()
  db <- package_database(getOption("repos")[[1L]], "windows", NULL,
                         progress = FALSE)
  plan <- plan_installation(packages, db, lib, "replace")
  cross_install_packages(packages, lib, db, plan, progress = FALSE)

  f <- file.path(lib, "zip", "provisionr")
  writeLines("provisionr", f)
  expect_true(file.exists(f))

  cross_install_packages(packages, lib, db, plan, progress = FALSE)
  expect_false(file.exists(f))
})
