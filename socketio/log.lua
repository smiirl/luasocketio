-- Logging management
--
-- Provides three levels of logging, WARNING, INFO and DEBUG. By default, only
-- WARNING messages are printed. This behaviour can be modified thanks to the
-- variable 'level'. The variable 'printer' is by default 'print', but can be
-- overwritten to redirect the log stream.

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

C.printer = print

local global_level = C.WARNING

function C.set_level(l)
    global_level = l
end

function C.log(level, ...)
    if global_level >= level then
        C.printer(
            "luasocketio",
            levels[level],
            string.format(...)
        )
    end
end

C.warn  = function(...) return C.log(C.WARNING, ...) end
C.info  = function(...) return C.log(C.INFO, ...) end
C.debug = function(...) return C.log(C.DEBUG, ...) end

return C

