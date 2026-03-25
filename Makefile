.PHONY: install compile test format precommit

# Full project setup (elixir deps + LSP node deps + prek)
install:
	mix deps.get
	cd lsp && npm install
	prek install

# Compile with strict warnings
compile:
	mix compile --warnings-as-errors

# Run all tests
test:
	tree-sitter test
	mix test
	cd lsp && npx vitest run

# Format all files
format:
	mix format
	biome check --write .

# Full pre-commit check (format, compile, credo, dialyzer, biome, tsc)
precommit:
	prek run --all-files
