suppressPackageStartupMessages({library(arrow); library(dplyr)})
out <- file.path(dirname(normalizePath(sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)))), "out")
cat("R", R.version.string, "| arrow", as.character(packageVersion("arrow")),
    "| dplyr", as.character(packageVersion("dplyr")), "| Sys.timezone()", Sys.timezone(),
    "| TZ env", shQuote(Sys.getenv("TZ")), "\n")
tryit <- function(label, expr) {
  r <- tryCatch(expr, error = function(e) paste("ERROR:", conditionMessage(e)))
  cat(label, ": ", paste(capture.output(print(r)), collapse = "\n  "), "\n", sep = "")
}

x <- as.POSIXct("2024-01-01 12:00:00", tz = "UTC")
x_none <- x; attr(x_none, "tzone") <- ""
x_null <- x; attr(x_null, "tzone") <- NULL
x_ny <- x; attr(x_ny, "tzone") <- "America/New_York"
x_frac <- as.POSIXct("2024-01-01 12:00:00.123456", tz = "UTC")
df <- data.frame(utc = x, none = x_none, nullattr = x_null, ny = x_ny, frac = x_frac)
cat("\n## arrow schema from data.frame\n"); print(arrow_table(df)$schema)
p <- file.path(out, "r.arrow"); write_feather(df, p)
cat("\n## read_feather(as_data_frame=FALSE) schema\n"); print(read_feather(p, as_data_frame = FALSE)$schema)
back <- read_feather(p)
cat("\n## read back tzone attrs\n"); print(lapply(back, function(c) attr(c, "tzone")))
tryit("frac digits preserved", format(back$frac, "%H:%M:%OS6"))

cat("\n## read pyarrow/polars-written timestamps\n")
at <- arrow_table(
  ns = Array$create(c(1704110400123456789), type = int64())$cast(timestamp("ns")),
  us_tz = Array$create(c(1704110400000000), type = int64())$cast(timestamp("us", "Europe/Berlin")),
  ns_plus = Array$create(c(1704110400000000000), type = int64())$cast(timestamp("ns", "+01:00"))
)
print(at$schema)
rd <- as.data.frame(at)
print(lapply(rd, class)); print(lapply(rd, function(c) attr(c, "tzone")))
tryit("ns value printed %OS9 (POSIXct is double seconds)", format(rd$ns, "%Y-%m-%d %H:%M:%OS9", tz = "UTC"))
tryit("us_tz printed", format(rd$us_tz, usetz = TRUE))
tryit("ns_plus printed", format(rd$ns_plus, usetz = TRUE))
# polars file from q1, if present
pp <- file.path(out, "polars.arrow")
if (file.exists(pp)) {
  pr <- read_ipc_file(pp); cat("polars.arrow in R:\n"); print(lapply(pr, function(c) attr(c, "tzone")))
  tryit("polars ns_utc %OS9", format(pr$ns_utc, "%H:%M:%OS9"))
}

cat("\n## base R / dplyr comparison across tzone attrs\n")
tryit("x_utc == x_ny (same instant)", x == x_ny)
tryit("x_utc == x_none", x == x_none)
tryit("identical(x, x_ny)", identical(x, x_ny))
tryit("c(x, x_ny) tzone", attr(c(x, x_ny), "tzone"))
d <- tibble(a = x, b = x_ny)
tryit("dplyr filter(a == b) nrow", nrow(filter(d, a == b)))
tryit("dplyr mutate(eq = a == b)", mutate(d, eq = a == b)$eq)
tryit("dplyr bind_rows tzone", attr(bind_rows(tibble(t = x), tibble(t = x_ny))$t, "tzone"))
tryit("dplyr inner_join across tz nrow", nrow(inner_join(tibble(k = x), tibble(k = x_ny), by = "k")))
tryit("dplyr if_else tz", attr(if_else(TRUE, x, x_ny), "tzone"))
cat("\n## arrow dplyr (Acero) comparison across zones\n")
at2 <- arrow_table(a = x, b = x_ny, n = x_none)
print(at2$schema)
tryit("arrow filter(a == b)", collect(filter(at2, a == b)) |> nrow())
tryit("arrow mutate(a == n) zoned vs local", collect(mutate(at2, eq = a == n))$eq)

cat("\n## zone strings in R\n")
for (z in c("+01:00", "Etc/GMT-1", "Z", "Not/AZone")) {
  tryit(paste0("format with tz=", z), format(x, tz = z, usetz = TRUE))
  tryit(paste0("arrow timestamp(us, '", z, "') to R"), {
    a <- Array$create(1704110400000000, type = int64())$cast(timestamp("us", z)); format(as.vector(a), usetz = TRUE)
  })
}
