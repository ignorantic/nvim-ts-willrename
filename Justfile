# No need for top-level if/shell switching

NVIM := env("NVIM", "nvim")
MIN  := "tests/minimal_init.lua"

# Run all tests (PlenaryBustedDirectory doesn't need extra options
# if Neovim is already started with -u tests/minimal_init.lua)
test:
    {{NVIM}} --headless -u {{MIN}} -c "PlenaryBustedDirectory tests/" -c "qa!"

# Run a single test file
# usage: just test-file tests/ts_willrename_rename_paths_spec.lua
test-file FILE:
    {{NVIM}} --headless -u {{MIN}} -c "PlenaryBustedFile {{FILE}}" -c "qa!"

