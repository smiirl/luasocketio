--- socket.io packet encoding/decoding methods
-- @module socketio.packet

local cjson_safe = require("cjson.safe")

--- Engine.IO protocol version constant
local ENGINEIO_PROTOCOL_VERSION = 3

local function build_packet_table(t)
    local idx = string.byte("0")

    local r = {}
    for i, name in ipairs(t) do
        r[idx+i-1] = name
        r[name] = idx+i-1
    end

    return r
end

-- Engine.IO packet types
local engineio_packet_types = build_packet_table{
    "open",
    "close",
    "ping",
    "pong",
    "message",
    "upgrade",
    "noop",
}

-- Socket.IO packet types
local socketio_packet_types = build_packet_table{
    "connect",
    "disconnect",
    "event",
    "ack",
    "error",
    "binary_event",
    "binary_ack",
}

-- Engine.IO packets whose body are encoded in JSON.
local json_body_engineio_packet_types = {
    open = true,
    message = true,
}

--- Decode a engine.io/socket.io packet.
-- @param s string encoding a packet.
-- @return a table representing the packet.
local function decode(s)
    local r = {}
    local idx = 1

    r.eio_pkt_name = engineio_packet_types[string.byte(s, idx)]

    if r.eio_pkt_name == nil then
        return false, "unknown engine.io packet type"
    end

    idx = idx + 1

    local json_body = nil

    if r.eio_pkt_name == "message" then
        r.sio_pkt_name = socketio_packet_types[string.byte(s, idx)]

        if r.sio_pkt_name == nil then
            return false, "unknown socket.io packet type"
        end

        idx = idx + 1

        if string.byte(s, idx) and string.sub(s, idx, idx) == "/" then
            local path_end_idx = string.find(s, ",", idx)

            if path_end_idx then
                r.path = string.sub(s, idx, path_end_idx - 1)
                idx = path_end_idx + 1
            else
                r.path = string.sub(s, idx)
                idx = string.len(s) + 1
            end
        else
            r.path = "/"
        end

        if string.byte(s, idx) and string.sub(s, idx, idx) ~= "[" then
            local ack_id_idx = string.find(s, "[^%d]", idx)

            if ack_id_idx then
                r.ack_id = string.sub(s, idx, ack_id_idx - 1)
                idx = ack_id_idx
            else
                r.ack_id = string.sub(s, idx)
                idx = string.len(s) + 1
            end

            r.ack_id = tonumber(r.ack_id)
        end
    end

    if string.byte(s, idx) then
        r.body = string.sub(s, idx, len)
    end

    if r.body and json_body_engineio_packet_types[r.eio_pkt_name] then
        local res, err = cjson_safe.decode(r.body)

        if not res then
            return res, string.format("%s (%q)", err, r.body)
        end

        r.raw_body = r.body
        r.body = res
    end

    return true, r
end

--- Encode a engine.io/socket.io packet.
-- @param pkt a table representing a packet.
-- @return string encoding the packet.
local function encode(pkt)
    local r = {}

    local eio_pkt_byte = engineio_packet_types[pkt.eio_pkt_name]
    if eio_pkt_byte == nil then
        return false, "unknown engine.io packet type"
    end

    table.insert(r, string.char(eio_pkt_byte))

    if pkt.eio_pkt_name == "message" then
        local sio_pkt_byte = socketio_packet_types[pkt.sio_pkt_name]
        if sio_pkt_byte == nil then
            return false, "unknown socket.io packet type"
        end

        table.insert(r, string.char(sio_pkt_byte))

        if pkt.path then
            table.insert(r, pkt.path)

            if pkt.ack_id or pkt.body then
                table.insert(r, ",")
            end
        end

        if pkt.ack_id then
            table.insert(r, tostring(pkt.ack_id))
        end
    end

    if pkt.body then
        local body
        if json_body_engineio_packet_types[pkt.eio_pkt_name] then
            local res, err = cjson_safe.encode(pkt.body)

            if not res then
                return res, err
            end

            body = res
        else
            body = pkt.body
        end

        table.insert(r, body)
    end

    return true, table.concat(r)
end

--- Returns a human representation of a packet.
-- @param pkt A packet.
-- @return A human representation of the packet.
local function tostring(pkt)
    local t = {}

    local function P(...)
        table.insert(t, string.format(...))
    end

    if pkt.eio_pkt_name == "message" then
        P("'%s'", pkt.sio_pkt_name)

        if pkt.path then
            P(", path '%s'", pkt.path)
        end

        if pkt.ack_id then
            P(", ack #%.0f", pkt.ack_id)
        end

        if pkt.body then
            P(", body '%s'", pkt.raw_body or pkt.body)
        end
    else
        P("'%s'", pkt.eio_pkt_name)

        if pkt.body then
            P(", body '%s'", pkt.raw_body or pkt.body)
        end
    end

    return table.concat(t)
end

return {
    encode = encode,
    decode = decode,
    tostring = tostring,

    ENGINEIO_PROTOCOL_VERSION = ENGINEIO_PROTOCOL_VERSION,
}

