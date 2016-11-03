-- Polling transport

local copas = require("copas")
local copas_http = require("copas.http")
local socket = require("socket")
local socket_url = require("socket.url")
local socketio_url = require("socketio.url")
local socketio_backoff = require("socketio.backoff")
local ltn12 = require("ltn12")
local log = require("socketio.log")

local C = {}
local M = {}

-- copied from https://github.com/keplerproject/copas/blob/92c344/src/copas/http.lua#L344-L376
local function tcp(params)
    params = params or {}
    -- Default settings
    params.protocol = params.protocol or copas_http.SSLPROTOCOL
    params.options = params.options or copas_http.SSLOPTIONS
    params.verify = params.verify or copas_http.SSLVERIFY
    params.mode = "client"   -- Force client mode
    -- upvalue to track https -> http redirection
    local washttps = false
    -- 'create' function for LuaSocket
    return function (reqt)
        local u = socket_url.parse(reqt.url)
        if (reqt.scheme or u.scheme) == "https" then
            -- https, provide an ssl wrapped socket
            local conn = copas_wrap(socket.tcp(), params)
            -- insert https default port, overriding http port inserted by LuaSocket
            if not u.port then
                u.port = copas_http.SSLPORT
                reqt.url = url.build(u)
                reqt.port = copas_http.SSLPORT
            end
            washttps = true
            return conn
        else
            -- regular http, needs just a socket...
            if washttps and params.redirect ~= "all" then
                try(nil, "Unallowed insecure redirect https to http")
            end
            return copas.wrap(socket.tcp())
        end
    end
end

local function parse(self, body)
    local idx = 1

    -- iterate over received packets
    while true do
        -- skip bytes 0
        while true do
            local b = string.byte(body, idx)

            if b == nil then
                return
            end

            if b == 0 then
                break
            end

            idx = idx + 1
        end

        -- read packet length
        local packet_length = 0
        while true do
            local b = string.byte(body, idx)

            if b == nil then
                return
            end

            if b == 0xff then
                break
            end

            packet_length = packet_length * 10 + b

            idx = idx + 1
        end

        idx = idx + 1

        -- read packet
        local packet_body = string.sub(body, idx, idx + packet_length - 1)
        self.opts.on_packet(packet_body)

        idx = idx + packet_length - 1
    end
end

local function handle_http_response(self, ok, code)
    if ok then
        self.backoff:reset()
        if code ~= 200 then
            log.warn("request error: %s %s", code, body)
            self.opts.on_error()
        end
    else
        local duration = self.backoff:duration()
        log.info("server down. back off, wait %.1fs...", duration)
        copas.sleep(duration)
    end
end

local function thread_recv(self)
    local create_cb = tcp()

    while self.opened do
        -- XXX timeout
        local url = socketio_url.build(self.opts.url, "polling", self.opts.session_id)
        local recv_body = {}

        local req_args = {
            url = url,
            method = "GET",
            headers =  {
                ["Content-Type"] = "application/octet-stream",
            },
            sink = ltn12.sink.table(recv_body),
            redirect = true,
            proxy = self.opts.proxy,
            create = function(req)
                local sock = create_cb(req)

                -- keep reference to socket to close it when polling transport
                -- is closed
                self.recv_sock = sock

                return sock
            end,
        }

        log.debug("GET %s", url)
        local ok, code, headers, status = copas_http.request(req_args)
        self.recv_sock = nil

        -- transport might have been closed while request was being performed.
        -- Before processing anything, check if transport is still opened. If
        -- not, break
        if not self.opened then
            break
        end

        recv_body = table.concat(recv_body)

        handle_http_response(self, ok, code)

        if ok and code == 200 then
            parse(self, recv_body)
        end
    end
end

local function thread_send(self)
    local create_cb = tcp()

    while self.opened and #self.buffer > 0 do
        -- get buffer send
        local buffer = table.concat(self.buffer)
        self.buffer = {}

        local url = socketio_url.build(self.opts.url, "polling", self.opts.session_id)

        local req_args = {
            url = url,
            method = "POST",
            headers =  {
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = string.len(buffer),
            },
            source = ltn12.source.string(buffer),
            redirect = true,
            proxy = self.opts.proxy,
            create = function(req)
                local sock = create_cb(req)

                -- keep reference to socket to close it when polling transport
                -- is closed
                self.send_sock = sock

                return sock
            end,
        }

        log.debug("POST (%.0fB) %s", string.len(buffer), url)
        local ok, code, headers, status = copas_http.request(req_args)
        self.send_sock = nil

        -- transport might have been closed while request was being performed.
        -- Before processing anything, check if transport is still opened. If
        -- not, break
        if not self.opened then
            break
        end

        handle_http_response(self, ok, code)
    end

    self.thread_send = nil
end

function M.send(self, pkt)
    table.insert(self.buffer, "\x00")

    -- encode packet length
    local l = tostring(string.len(pkt))
    for i = 1, string.len(l) do
        -- 48 == string.byte('0')
        table.insert(self.buffer, string.char(string.byte(string.sub(l, i)) - 48))
    end

    table.insert(self.buffer, "\xff")
    table.insert(self.buffer, pkt)

    -- start send thread if does not exist
    if self.thread_send == nil then
        self.thread_send = copas.addthread(thread_send, self)
    end
end

function M.open(self)
    assert(not self.opened, "already polling")
    self.opened = true

    self.thread_recv = copas.addthread(thread_recv, self)
end

function M.close(self)
    assert(self.opened, "already not polling")
    self.opened = false

    -- close recv or send sockets if currently opened
    if self.recv_sock then
        self.recv_sock:close()
        self.recv_sock = nil
    end

    if self.send_sock then
        self.send_sock:close()
        self.send_sock = nil
    end

    self.thread_recv = nil
    self.thread_send = nil
end

function M.set_session(self, session)
    self.opts.session_id = session.session_id or session.sid
    self.opts.ping_timeout = session.ping_timeout or session.pingTimeout
    self.opts.ping_interval = session.ping_interval or session.pingInterval
    self.opts.upgrades = session.upgrades
end

function M.clear_session(self)
    self.opts.session_id = nil
    self.opts.ping_timeout = nil
    self.opts.ping_interval = nil
    self.opts.upgrades = nil
end

function C.new(opts)
    opts = opts or {}

    assert(opts.on_packet, "required argument 'on_packet'")
    assert(opts.on_error, "requires argument 'on_error'")

    local self = {
        opts = opts,
        buffer = {},
        backoff = socketio_backoff.new{
            min = opts.reconnection_delay,
            max = opts.reconnection_delay_max,
            jitter = opts.randomization_factor,
        },
    }

    return setmetatable(self, {
        __index = M,
    })
end

return C

