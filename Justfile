# Justfile
NVIM := "nvim"
INIT := "tests/minimal_init.lua"

# Clone test deps if missing (Plenary + LuaCov)
test-setup:
	@if [ ! -d tests/plenary ]; then git clone --depth=1 https://github.com/nvim-lua/plenary.nvim tests/plenary; fi

# Run all specs
test: test-setup
  {{NVIM}} --headless -u tests/minimal_init.lua -c "lua dofile('tests/run_busted.lua')" -c "qa!"

# Run single spec: just test-file tests/spec/filter_spec.lua
test-file FILE: test-setup
	{{NVIM}} --headless -u {{INIT}} -c "lua require('plenary.busted').run('{{FILE}}')" -c "qa!"

