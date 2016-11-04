--- Logging management.
--
-- Provides three levels of logging, WARNING, INFO and DEBUG. By default, only
-- WARNING messages are printed.
--
-- @module socketio.log

local C = {}

local levels = {
    "WARNING",
    "INFO",
    "DEBUG"
}

for value, name in ipairs(levels) do
    C[name] = value
    levels[name] = value
end

local global_printer = print

local global_level = C.WARNING

--- Set a printer function. By default, set to 'print'.
-- @param printer printer function to set
function C.set_printer(printer)
    global_printer = printer
end

--- Set logger level. By default, set to 'WARNING'.
-- @param level Level to set
function C.set_level(level)
    global_level = level
end

--- Main log function
-- @param level Log level
-- @param ... string.format() parameters
function C.log(level, ...)
    if global_level >= level then
        global_printer(
            "luasocketio",
            levels[level],
            string.format(...)
        )
    end
end

--- Log a warning log.
-- @param ... string.format parameters
function C.warn(...) return C.log(C.WARNING, ...) end

--- Log a info log.
-- @param ... string.format parameters
function C.info(...) return C.log(C.INFO, ...) end

--- Log a debug log.
-- @param ... string.format parameters
function C.debug(...) return C.log(C.DEBUG, ...) end

return C

