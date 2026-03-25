[
  # Dialyzer infers a more specific NotCompilable shape than the spec declares.
  # The spec `{:error, NotCompilable.t()}` is correct — this is a known false positive.
  {"lib/plazaql/sql.ex", :missing_range}
]
