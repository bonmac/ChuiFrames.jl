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
cat("arrow", as.character(packageVersion("arrow")), "\n")
