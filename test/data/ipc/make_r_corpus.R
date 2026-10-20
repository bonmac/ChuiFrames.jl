# R arrow cases of the Arrow IPC corpus (ADR-0001 rule 10).
# Usage: Rscript make_r_corpus.R OUTDIR   (then make_corpus.py OUTDIR dumps them with pyarrow)
suppressMessages(library(arrow))
out <- commandArgs(trailingOnly = TRUE)[1]
dir.create(out, showWarnings = FALSE, recursive = TRUE)
df <- data.frame(
  s = c("alpha", NA, "a long R string over twelve"),
  i = c(1L, NA, 3L),
  f = c(1.5, NaN, NA),
  b = c(TRUE, NA, FALSE),
  d = as.Date(c("2020-01-01", NA, "1970-01-02")),
  fac = factor(c("u", "v", "u")),
  stringsAsFactors = FALSE
)
write_feather(df, file.path(out, "r_feather.arrow"))
write_ipc_stream(df, file.path(out, "r_stream.arrows"))
# POSIXct (ADR-0021): R arrow writes timestamp[us, tz = tzone]; tzone "" is a naive timestamp[us]
# (R stores the UTC moment; the pyarrow dump is the expected value). Built from numeric seconds,
# so the machine's time zone does not matter.
secs <- c(0, 1700000000.123456, NA, -1.5, 1700000000.000001)
naive <- .POSIXct(secs, tz = "")
attr(naive, "tzone") <- ""
tsdf <- data.frame(
  utc = .POSIXct(secs, tz = "UTC"),
  naive = naive,
  ny = .POSIXct(c(1711846800, NA, 0.25, -86400, 1730613600), tz = "America/New_York"),
  frac = .POSIXct(c(0.000001, 0.5, 1.999999, -0.000001, 1e9 + 0.654321), tz = "UTC")
)
write_feather(tsdf, file.path(out, "r_timestamps.arrow"))
cat("arrow", as.character(packageVersion("arrow")), "\n")
