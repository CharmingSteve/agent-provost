-- .luacheckrc
-- luacheck configuration for the agent-provost repository.
-- OpenResty injects these globals at runtime; declare them here so luacheck
-- does not flag them as undefined when linting test files.

globals = {
    "ngx",
    "cjson",
}

-- Relax unused-variable warnings that are common in busted describe/it blocks.
ignore = { "211", "212", "311" }

std = "min"
