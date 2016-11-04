--- socket.io class
-- @classmod socketio.socket

local log = require("socketio.log")

local C = {}
local M = {}

--- Send a packet from the given socket. This will configure the packet with the
-- right namespace, and eventual acknowledgement if required.
-- @param self instance
-- @param name event's name.
-- @param args event's arguments.
-- @param cb If defined, function to be called back when packet will be received
-- by the other peer (therefore adding an acknowlegment ID to the packet to be
-- sent). Else 'nil'.
local function packet(self, name, args, cb)
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
        body = args,
        ack_id = ack_id,
    }

    return self.manager:packet(pkt)
end


-- List of socket.io handlers.
local H = {}

--- Called when a packet 'ACK' is received
-- @param self instance
-- @param pkt Packet 'ACK'.
function H.ack(self, pkt)
    -- ignore if malformed
    if not pkt.ack_id then
        return
    end

    -- Calls the acknowlegement callback if (still) defined.
    local ack_cb = self.acks[pkt.ack_id]
    self.acks[pkt.ack_id] = nil
    if ack_cb then
        return ack_cb()
    end
end

--- Called when a packet 'CONNECT' is received
-- @param self instance
-- @param pkt Packet 'CONNECT'.
function H.connect(self, pkt)
    -- if not connected, acknowledge the server of the connection and notify the
    -- user the socket is connected.
    if not self.connected then
        packet(self, "connect")

        self:_fire("connected")
        self.connected = true
    end
end

--- Called when a packet 'DISCONNECT' is received
-- @param self instance
-- @param pkt Packet 'DISCONNECT'.
function H.disconnect(self, pkt)
    if self.connected then
        self:_fire("disconnected")
        self.connected = false
    end
end

--- Called when a packet 'EVENT' is received
-- @param self instance
-- @param pkt Packet 'EVENT'.
function H.event(self, pkt)
    -- if an acknowlegment was asked, send an 'ACK' packet with the the ack id.
    if pkt.ack_id then
        self.manager:packet{
            eio_pkt_name = "message",
            sio_pkt_name = "ack",
            ack_id = pkt.ack_id,
            path = pkt.path,
        }
    end

    -- Fire the event's name with the packet's arguments.
    return (function(name, ...)
        return self:_fire(name, ...)
    end)(table.unpack(pkt.body))
end

--- Called when a packet 'ERROR' is received
-- @param self instance
-- @param pkt Packet 'ERROR'.
function H.error(self, pkt)
    log.warn("error path=%q: %q", pkt.path, pkt.body)
    self:_fire("error", pkt.body)
end

--- Called when a packet is received for the given path/namespace.
-- @param self instance
-- @param pkt Packet for the given socket.
function M.on_packet(self, pkt)
    local handler = H[pkt.sio_pkt_name]

    if handler then
        return handler(self, pkt)
    end
end

--- Connect to the socket path. This will notify the server events from this
-- namespace should be sent to the given socket.
-- @param self instance
function M.connect(self)
    return packet(self, "connect")
end

--- Disconnect to the socket path.
-- @param self instance
function M.disconnect(self)
    return packet(self, "disconnect")
end

--- Registers or unregisters an event.
-- @param self instance
-- @param name Event's name
-- @param func Event's function if defined. 'nil' will unregister a previous
-- registered function.
function M.on(self, name, func)
    self.handlers[name] = func
end

--- Registers an event once. Behaves will @{socketio.socket.on} but will
-- unregisters the event automatically before being called, therefore only
-- fireable once.
-- @param self instance
-- @param name Event's name
-- @param func Event's function to be called once.
function M.once(self, name, func)
    self.handlers[name] = function(...)
        self.handlers[name] = nil
        return func(...)
    end
end

--- Emit an event to the socket.io server.
-- @param self instance
-- @param name Event's name.
-- @param ... Arguments of event. If one callback (and only one) is defined in
-- this arguments, the server will be asked to acknowledge the reception of the
-- message, acknowledgement which will call the given function.
function M.emit(self, name, ...)
    local args = {name}
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

--- Send a message. This is strictly equivalent to 'emit("message", ...)'. This
--is commonly used as an emulation of a websocket.
-- @param self instance
-- @param ... Message's arguments.
function M.send(self, ...)
    return self:emit("message", ...)
end

--- Fire an event for the socket.
-- @param self instance
-- @param name Event's name.
-- @param ... Event's arguments.
function M._fire(self, name, ...)
    local h = self.handlers[name]
    if h then
        return h(...)
    end
end

--- Class constructor.
-- @param manager Socket's manager. See @{socketio.manager}.
-- @param path Socket's path/namespace.
-- @param opts Socket's options. See @{socketio.manager.new}.
-- @return An instance of @{socketio.socket}.
function C.new(manager, path, opts)
    assert(manager, "argument 'manager' is required")
    assert(path, "argument 'path' is required")
    assert(opts, "argument 'opts' is required")

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

