local log = require("socketio.log")

local C = {}
local M = {}

local H = {}

local function packet(self, name, arg, cb)
    local ack_id

    if cb then
        ack_id = self.ack_id_counter
        self.ack_id_counter = self.ack_id_counter + 1

        self.acks[ack_id] = cb
    end

    local pkt = {
        eio_pkt_name = "message",
        sio_pkt_name = name,
        path = self.path,
        body = arg,
        ack_id = ack_id,
    }

    return self.manager:packet(pkt)
end

function H.ack(self, pkt)
    if not pkt.ack_id then
        return
    end

    local ack_cb = self.acks[pkt.ack_id]
    self.acks[pkt.ack_id] = nil

    if ack_cb then
        return ack_cb()
    end
end

function H.connect(self, pkt)
    if not self.connected then
        packet(self, "connect")

        self:_handle("connected")
        self.connected = true
    end
end

function H.disconnect(self, pkt)
    if self.connected then
        self:_handle("disconnected")
        self.connected = false
    end
end

function H.event(self, pkt)
    -- acknowledge
    if pkt.ack_id then
        self.manager:packet{
            eio_pkt_name = "message",
            sio_pkt_name = "ack",
            ack_id = pkt.ack_id,
            path = pkt.path,
        }
    end

    return (function(name, ...)
        return self:_handle(name, ...)
    end)(table.unpack(pkt.body))
end

function H.error(self, pkt)
    log.warn("error path=%q: %q", pkt.path, pkt.body)
    self:_handle("error", pkt.body)
end

function M.on_packet(self, pkt)
    local handler = H[pkt.sio_pkt_name]

    if handler then
        return handler(self, pkt)
    end
end

function M.connect(self)
    return packet(self, "connect")
end

function M.disconnect(self)
    return packet(self, "disconnect")
end

function M.on(self, name, func)
    self.handlers[name] = func
end

function M.once(self, name, func)
    self.handlers[name] = function(...)
        self.handlers[name] = nil
        return func(...)
    end
end

function M.emit(self, name, ...)
    local args = {name }
    local cb

    -- iterate over arguments and extract arguments and callback, if any.
    for i = 1, select("#", ...) do
        local v = select(i, ...)

        if type(v) == "function" then
            assert(not cb, "callback already defined")
            cb = v
        else
            table.insert(args, v)
        end
    end

    return packet(self, "event", args, cb)
end

function M.send(self, ...)
    return self:emit("message", ...)
end

function M._handle(self, name, ...)
    local h = self.handlers[name]
    if h then
        return h(...)
    end
end

local opts_default = {
    auto_connect = true,
}

function C.new(manager, path, opts)
    assert(manager, "argument 'manager' is required")
    assert(path, "argument 'path' is required")
    opts = opts or {}

    -- set default values to opts
    for opt_key, opt_val in pairs(opts_default) do
        if not opts[opt_key] then
            opts[opt_key] = opt_val
        end
    end

    local self = {
        manager = manager,
        path = path,
        opts = opts,
        acks = {},
        ack_id_counter = 1,
        handlers = {},
        connected = false,
    }

    return setmetatable(self, {
        __index = M
    })
end

return C

