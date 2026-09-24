-- The loader the Lua gate runs:
--
--   nvim -u NONE -l tests/luagate.lua <file.lua>...
--
-- loadfile compiles each argument without running it, so no module is required
-- and nothing it parses runs; a file that does not parse is reported with the
-- parser's own message and the exit code is 1 at the first one. nvim rather
-- than luajit, because nvim is the interpreter that loads these files and is in
-- the manifest for every target; -u NONE keeps it from loading the
-- configuration it is parsing.

if #arg == 0 then
  io.stderr:write("usage: nvim -u NONE -l tests/luagate.lua <file.lua>...\n")
  os.exit(2)
end

for index = 1, #arg do
  local chunk, err = loadfile(arg[index])
  if not chunk then
    io.stderr:write(err, "\n")
    os.exit(1)
  end
end
