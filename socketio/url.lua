local packet = require("socketio.packet")
local gettime = require("socket").gettime
local socket_url = require("socket.url")

local C = {}

local counter = 1

function C.build(url, transport, session_id)
    local parsed_url = socket_url.parse(url)

    if not parsed_url then
        return nil
    end

    parsed_url.path = "/socket.io/"

    local query = {}
    table.insert(query, "EIO=" .. tostring(packet.ENGINEIO_PROTOCOL_VERSION))

    local now = gettime()
    table.insert(query, string.format("t=%.0f-%.0f", now, counter))
    counter = counter + 1

    table.insert(query, "transport=" .. transport)

    if session_id then
        table.insert(query, "sid=" .. session_id)
    end

    parsed_url.query = table.concat(query, "&")

    return socket_url.build(parsed_url)
end

return C

