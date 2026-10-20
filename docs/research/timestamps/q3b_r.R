suppressPackageStartupMessages(library(arrow))
x <- as.POSIXct("2024-01-01 12:00:00", tz = "UTC")
xn <- x; attr(xn, "tzone") <- ""
xl <- as.POSIXct("2024-01-01 12:00:00")  # parsed in local zone, tzone ""
cat("Sys.timezone:", Sys.timezone(), "\n")
for (nm in c("x","xn","xl")) {
  v <- get(nm); a <- Array$create(v)
  cat(nm, "tzone=", shQuote(attr(v,"tzone")), "type=", a$type$ToString(), "stored int64=", format(as.vector(a$cast(int64()))), "\n")
}
cat("POSIXct of the instant 12:00Z as epoch secs:", as.numeric(x), "\n")
ns <- Array$create(1704110400123456789, type = int64())$cast(timestamp("ns"))
r <- as.vector(ns); cat("ns -> R double frac:", sprintf("%.9f", as.numeric(r) - 1704110400), "\n")
cat("ns -> R -> Arrow type:", Array$create(r)$type$ToString(), "\n")
Sys.setenv(TZ = "America/New_York")
a <- Array$create(xl); cat("after TZ=America/New_York, local-parsed (tz '') value stored:", format(as.vector(a$cast(int64()))), a$type$ToString(), "\n")
