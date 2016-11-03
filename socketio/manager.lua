local copas = require("copas")
local gettime = require("socket").gettime

local log = require("socketio.log")
local packet = require("socketio.packet")
local polling = require("socketio.polling")
local socket = require("socketio.socket")

local C = {}
local M = {}

function M.on(self, name, func)
    self.handlers[name] = func
end

local function handle(self, name, ...)
    -- emit all sockets
    for _, sock in pairs(self.namespaces) do
        sock:_handle(name, ...)
    end

    local h = self.handlers[name]
    if h then
        return self.handlers[name](...)
    end
end

local function keepalive_thread(self)
    while self.opened do
        local now = gettime()
        local sleep_ts

        if self.last_unanswered_ping_ts then
            local timeout_ts = self.last_unanswered_ping_ts + self.session.ping_timeout

            if timeout_ts < now then
                log.warn("%s: timeout!", self.opts.url)

                self:reconnect()
                return
            else
                sleep_ts = timeout_ts
            end
        else
            local next_ping_ts = self.last_recv_ts + self.session.ping_interval

            if next_ping_ts < now then
                self:packet{
                    eio_pkt_name = "ping",
                }
                self.last_unanswered_ping_ts = gettime()
            else
                sleep_ts = next_ping_ts
            end
        end

        if sleep_ts then
            local duration = sleep_ts - now
            assert(duration >= 0)

            duration = math.min(duration, 5)
            copas.sleep(duration)
        end
    end
end

local H = {}

function H.open(self, pkt)
    assert(pkt.body.sid, "invalid packet 'OPEN'")

    self.session = {
        session_id = pkt.body.sid,
        ping_timeout = pkt.body.pingTimeout / 1000,
        ping_interval = pkt.body.pingInterval / 1000,
        upgrades = pkt.body.upgrades,
    }

    if self.transport then
        self.transport:set_session(self.session)
    end

    self.opened = true

    self:packet{
        eio_pkt_name = "open"
    }

    -- connect sockets in "auto_connect" mode
    for _, sock in pairs(self.namespaces) do
        if sock.opts.auto_connect then
            sock:connect()
        end
    end

    copas.addthread(keepalive_thread, self)

    handle(self, "open")
end

function H.close(self, pkt)
    self:close()
end

function H.ping(self, pkt)
    pkt.eio_pkt_name = "pong"
    self:packet(pkt)

    handle(self, "ping")
end

function H.pong(self, pkt)
    self.last_unanswered_ping_ts = nil

    handle(self, "pong")
end

function H.message(self, pkt)
    local sock = self.namespaces[pkt.path]

    if sock then
        return sock:on_packet(pkt)
    end
end

local function on_packet(self, pkt)
    self.last_recv_ts = gettime()

    local ok, pkt = packet.decode(pkt)

    if not ok then
        log.warn("received invalid packet: %s", pkt)
        return
    end

    log.info("%s >>> %s", self.opts.url, packet.tostring(pkt))

    local handler = H[pkt.eio_pkt_name]

    if handler then
        return handler(self, pkt)
    end
end

function M.packet(self, pkt)
    assert(self.transport, "no transport opened")

    log.info("%s <<< %s", self.opts.url, packet.tostring(pkt))

    local ok, pkt = assert(packet.encode(pkt))

    return self.transport:send(pkt)
end

function M.open(self)
    -- transport already allocated?
    if self.transport then
        return
    end

    log.debug("open manager '%s'.", self.opts.url)

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

    handle(self, "close")
end

function M.reconnect(self)
    self:close()
    self:open()
end

function M.socket(self, path, opts)
    path = path or "/"

    local sock = self.namespaces[path]

    if not sock then
        sock = socket.new(self, path, opts or self.opts)
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
    reconnection_attempts = nil,
    reconnection_delay = 1.0,
    reconnection_delay_max = 5.0,
    randomization_factor = 0.5,
}

function C.new(...)
    local opts
    if type(select(1, ...)) == "string" then
        opts = select(2, ...) or {}
        opts.url = select(1, ...)

    else
        opts = select(1, ...) or {}
    end

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

