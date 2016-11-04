-- socket.io client, written in Lua
-- For Smiirl (http://smiirl.com/)

local log = require("socketio.log")
local manager = require("socketio.manager")
local socket = require("socketio.socket")
local socket_url = require("socket.url")

-- Cache of opened managers
local manager_cache = {}

--- Lookup/connect for a given URL, and returns a socket for this URL. A manager
-- is automatically instantiated if it did not exist or forced.
-- @param url URL to connect to.
-- @param opts Options. See @{socketio.manager.new}.
-- @return An instance of @{socketio.socket}.
local function lookup(url, opts)
    opts = opts or {}

    local parsed_url = socket_url.parse(url)
    local authority = parsed_url.authority
    local path = parsed_url.path

    local new_conn = (
        opts.force_new or
        opts.multiplex == false
    )

    local m
    if new_conn then
        log.debug("force new manager for %s.", url)
        m = manager.new(url, opts)
    else
        m = manager_cache[authority]
        if not m then
            log.debug("new manager for %s.", url)
            m = assert(manager.new(url, opts))
            manager_cache[authority] = m
        end
    end

    return m:socket(path, opts)
end

return setmetatable({
        log = log,
        manager = manager,
        socket = socket,
    }, {
        __call = function(self, ...) return lookup(...) end,
    }
)

