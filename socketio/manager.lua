--- socket.io manager class, handling an active connection with a server.
-- Handlers of the engine.io protocol - being the transport protocol, the layer
-- under the socket.io protocol - is defined here. The manager is responsible of
-- the negotiation with the server of the transport to use, and making sure the
-- connection is still active. Sockets for given paths/namespaces can be
-- instantiated here thanks to the method @{socketio.manager.socket} to actually
-- interact with the server.
-- @classmod socketio.manager

local copas = require("copas")
local gettime = require("socket").gettime

local log = require("socketio.log")
local packet = require("socketio.packet")
local polling = require("socketio.polling")
local socket = require("socketio.socket")

local C = {}
local M = {}

--- Registers or unregisters an callback to a given event
-- @param self instance of @{socketio.manager}.
-- @param name An event name
-- @param func The function to link to the event if defined. 'nil' would mean to
-- unregister a previous registered function.
function M.on(self, name, func)
    self.handlers[name] = func
end

--- Fire an event for the manager and every sockets.
-- @param self instance of @{socketio.manager}.
-- @param name Event's name.
-- @param ... Event's arguments.
local function fire(self, name, ...)
    -- emit all sockets
    for _, sock in pairs(self.namespaces) do
        sock:_fire(name, ...)
    end

    local h = self.handlers[name]
    if h then
        return self.handlers[name](...)
    end
end

--- Keep alive thread. Deals with making sure the connection with the server is
-- still alive by sending PING to the server and waiting it to answer back. In
-- the event the server would not respond fast enough, the thread will close the
-- connection for reason of timeout and attempt a new connection.
-- @param self instance of @{socketio.manager}.
local function keepalive_thread(self)
    while self.opened do
        local now = gettime()

        -- if not nil, timestamp until when the thread will have to sleep
        local sleep_ts

        -- was a PING sent but still no PONG received?
        if self.last_unanswered_ping_ts then
            -- calculate the timestamp when the connection timeout would occur
            -- if no PONG would be received
            local timeout_ts = self.last_unanswered_ping_ts + self.session.ping_timeout

            -- is this timeout passed?
            if timeout_ts < now then
                log.warn("%s: timeout!", self.opts.url)
                self:reconnect()
                return
            else
                sleep_ts = timeout_ts
            end
        else
            -- calculate the timestamp when the next PING would be sent if no
            -- activity happened since then.
            local next_ping_ts = self.last_recv_ts + self.session.ping_interval

            -- is this time passed?
            if next_ping_ts < now then
                self:packet{
                    eio_pkt_name = "ping",
                }
                self.last_unanswered_ping_ts = gettime()
            else
                sleep_ts = next_ping_ts
            end
        end

        -- In the event nothing had to be done, sleep a little
        if sleep_ts then
            local duration = sleep_ts - now
            assert(duration >= 0)

            -- maximum of sleep is 5s to check back if the situation changed.
            -- XXX this should be improved.
            duration = math.min(duration, 5)
            copas.sleep(duration)
        end
    end
end

-- List of engine.io handlers.
local H = {}

--- Called when a packet 'OPEN' is received
-- @param self instance of @{socketio.manager}.
-- @param pkt Packet 'OPEN'.
function H.open(self, pkt)
    assert(pkt.body.sid, "invalid packet 'OPEN'")

    -- set new session
    self.session = {
        session_id = pkt.body.sid,
        ping_timeout = pkt.body.pingTimeout / 1000,
        ping_interval = pkt.body.pingInterval / 1000,
        upgrades = pkt.body.upgrades,
    }

    -- notify transport of new session
    if self.transport then
        self.transport:set_session(self.session)
    end

    -- the manager is now opened
    self.opened = true

    -- acknowledge
    self:packet{
        eio_pkt_name = "open"
    }

    -- if sockets were already registered to some namespaces/paths, connect the
    -- ones in "auto_connect" mode.
    for _, sock in pairs(self.namespaces) do
        if sock.opts.auto_connect then
            sock:connect()
        end
    end

    -- start the keep-alive thread
    copas.addthread(keepalive_thread, self)

    -- notify user the manager is opened
    fire(self, "open")
end

--- Called when a packet 'CLOSE' is received
-- @param self instance of @{socketio.manager}.
-- @param pkt Packet 'CLOSE'
function H.close(self, pkt)
    -- close session
    self:close()
end

--- Called when a packet 'PING' is received
-- @param self instance of @{socketio.manager}.
-- @param pkt Packet 'PING'
function H.ping(self, pkt)
    -- reply with a 'PONG', returning the same body
    self:packet{
        eio_pkt_name = "pong",
        body = pkt.body,
    }

    -- notify user the manager received a 'ping'
    fire(self, "ping")
end

--- Called when a packet 'PONG' is received
-- @param self instance of @{socketio.manager}.
-- @param pkt Packet 'PONG'
function H.pong(self, pkt)
    -- previous PING was answered
    self.last_unanswered_ping_ts = nil

    -- notify user the manager received a 'pong'
    fire(self, "pong")
end

--- Called when a packet 'MESSAGE' is received
-- @param self instance of @{socketio.manager}.
-- @param pkt Packet 'MESSAGE'
function H.message(self, pkt)
    -- redirect packet to the given socket, if instantied.
    local sock = self.namespaces[pkt.path]
    if sock then
        return sock:on_packet(pkt)
    end
end

--- Called when a new packet is received from the current transport.
-- @param self instance of @{socketio.manager}.
-- @param pkt Still-encoded packet
local function on_packet(self, pkt)
    -- update last time the last received packet had been made with the server
    -- as now.
    self.last_recv_ts = gettime()

    -- decode the packet, and ignore it if malformed.
    local ok, pkt = packet.decode(pkt)
    if not ok then
        log.warn("received invalid packet: %s", pkt)
        return
    end

    log.info("%s >>> %s", self.opts.url, packet.tostring(pkt))

    -- Redirects packet to its handler, if defined.
    local handler = H[pkt.eio_pkt_name]
    if handler then
        return handler(self, pkt)
    end
end

--- Send a packet to the server.
-- @param self instance of @{socketio.manager}.
-- @param pkt The packet to be sent.
function M.packet(self, pkt)
    assert(self.transport, "no transport opened")

    log.info("%s <<< %s", self.opts.url, packet.tostring(pkt))

    local ok, pkt = assert(packet.encode(pkt))

    return self.transport:send(pkt)
end

--- Open the transport. A connection will be opened to the server. When the
-- manager is effectively opened, the event 'open' will be fired.
-- @param self instance of @{socketio.manager}.
function M.open(self)
    -- transport already allocated?
    if self.transport then
        return
    end

    log.debug("open manager '%s'.", self.opts.url)

    -- instance and open the transport by default, being polling
    self.transport = polling.new{
        url = self.opts.url,
        reconnection_delay = self.opts.reconnection_delay,
        reconnection_delay_max = self.opts.reconnection_delay_max,
        randomization_factor = self.opts.randomization_factor,

        on_packet = function(pkt)
            return on_packet(self, pkt)
        end,

        on_error = function(...)
            log.warn("transport error!", ...)
            self:close()
            self:open()
        end
    }

    self.transport:open()
end

--- Close the manager. This closes the current session, if defined, and the
-- connection with the server, if existed.
-- @param self instance of @{socketio.manager}.
function M.close(self)
    log.debug("close manager '%s'.", self.opts.url)

    self.session = nil
    self.opened = false
    self.packet_buffer = {}
    self.last_unanswered_ping_ts = nil
    self.last_recv_ts = 0

    if self.transport then
        self.transport:close()
        self.transport = nil
    end

    fire(self, "close")
end

--- Reconnect to the server (close and open back).
-- @param self instance of @{socketio.manager}.
function M.reconnect(self)
    self:close()
    self:open()
end

--- Returns a socket instance for a given path. If no socket for a given path
-- exists, one socket is instantiated, registered and returned. Socket is
-- automatically connected to the path if the option 'auto_connect' is true.
-- @param self instance of @{socketio.manager}.
-- @param path Path of the socket to get.
-- @return Instance of @{socketio.socket}.
function M.socket(self, path)
    path = path or "/"

    local sock = self.namespaces[path]

    if not sock then
        sock = socket.new(self, path, self.opts)
        self.namespaces[path] = sock
    end

    -- auto-connect
    if self.opened and sock.opts.auto_connect then
        sock:connect()
    end

    return sock
end

local opts_default = {
    --reconnection = true,  -- XXX TODO
    reconnection_attempts = nil,    -- XXX TODO
    reconnection_delay = 1.0,
    reconnection_delay_max = 5.0,
    randomization_factor = 0.5,
    proxy = nil,
    auto_connect = true,
}

--- Class constructor.
-- @param url socket.io URL.
-- @param opts Global options, that sockets and transports will inherit.
-- @param opts.reconnection_delay Time in seconds to wait before attempting a
-- reonnection to the server. Default value is 1s.
-- @param opts.reconnection_delay_max Maximum time in seconds to wait before
-- attempting a reconnection to the server. Default value is 5s.
-- @param opts.randomization_factor Random factor to apply to time to wait
-- before reconnection (jitter). Default value is 50%.
-- @param opts.proxy If defined, URL to HTTP proxy to use. Default value is nil.
-- @param opts.auto_connect If true, automatically connect a socket when
-- instantiated. Default value is true.
-- @return An instance of @{socketio.manager}.
function C.new(url, opts)
    opts = opts or {}

    opts.url = url

    -- set default values to opts
    for opt_key, opt_val in pairs(opts_default) do
        if not opts[opt_key] then
            opts[opt_key] = opt_val
        end
    end

    assert(opts.url, "argument 'url' missing")

    local self = {
        opts = opts,
        namespaces = {},
        handlers = {},
        opened = false,
        --last_unanswered_ping_ts = nil,
        last_recv_ts = 0,
    }

    return setmetatable(self, {
        __index = M
    })
end

return C

