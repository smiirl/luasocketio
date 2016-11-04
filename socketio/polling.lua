--- socket.io polling transport
-- Most basic transport, HTTP GET long-polling the socket.io's server to receive
-- events and perfoming HTTP POSTs to send.
-- Used by @{socketio.manager}
-- @classmod socketio.polling

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
-- originally named 'tcp'
local function create_builder(params)
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

--- Parse a body received after a GET from the server
local function parse_get_body(self, body)
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

        -- read packet length.
        -- The packet length is encoded in base 10 with digits being byte 0 to
        -- 9. For example, length 42 will be encoded "\x04\x02".
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

        -- Read the entire packet body
        local packet_body = string.sub(body, idx, idx + packet_length - 1)
        copas.addthread(self.opts.on_packet, packet_body)

        idx = idx + packet_length - 1
    end
end

--- Handle a HTTP response to a GET or POST request
-- @param self instance
-- @param ok True if HTTP request was responded, else false
-- @param code HTTP code
-- @param body Received body
local function handle_http_response(self, ok, code, body)
    if ok then
        -- contact had been made: reset backoff
        self.backoff:reset()

        -- if HTTP code is different than 200, for example 400, notify an error
        -- occured
        if code ~= 200 then
            log.warn("request error: %s %s", code, body)
            copas.addthread(self.opts.on_error)
        end
    else
        -- server did not respond, wait for some time
        local duration = self.backoff:duration()
        log.info("server down. back off, wait %.1fs...", duration)
        copas.sleep(duration)
    end
end

--- copas thread, started when transport is opened, which will long-poll the
-- socket.io server. Automatically dies when the transport is closes.
local function thread_recv(self)
    local create_cb = create_builder()

    while self.opened do
        -- XXX timeout

        -- build URL for the request
        local url = socketio_url.build(self.opts.url, "polling", self.opts.session_id)

        -- table to contain chunks of received data
        local recv_body = {}

        -- HTTP GET request
        log.debug("GET %s", url)
        local ok, code, headers, status = copas_http.request{
            url = url,
            method = "GET",
            headers =  {
                ["Content-Type"] = "application/octet-stream",
            },
            sink = ltn12.sink.table(recv_body), -- sink received data to table recv_body
            redirect = true,    -- follow redirection silently
            proxy = self.opts.proxy,    -- configure proxy
            create = function(req)
                local sock = create_cb(req)

                -- keep reference to socket to close it when polling transport
                -- is closed
                self.recv_sock = sock

                return sock
            end,
        }

        -- socket has been closed since
        self.recv_sock = nil

        -- transport might have been closed while request was being performed.
        -- Before processing anything, check if transport is still opened. If
        -- not, break
        if not self.opened then
            break
        end

        -- concat received data in a string
        recv_body = table.concat(recv_body)

        -- process returned data
        handle_http_response(self, ok, code, recv_body)

        -- if everything was OK, parse the body
        if ok and code == 200 then
            parse_get_body(self, recv_body)
        end
    end
end

--- copas.thread started when packet has to be sent. It automatically dies when
-- no packet has to be sent anymore or the transport is closed.
local function thread_send(self)
    local create_cb = create_builder()

    -- while packet to be sent are pending and transport is opened
    while self.opened and #self.buffer > 0 do
        -- get buffer to send, concat it to a string and reset the instance's
        -- buffer for future new packets.
        local buffer = table.concat(self.buffer)
        self.buffer = {}

        -- build URL for the request
        local url = socketio_url.build(self.opts.url, "polling", self.opts.session_id)

        -- table to contain chunks of received data
        local recv_body = {}

        -- HTTP POST request
        log.debug("POST (%.0fB) %s", string.len(buffer), url)
        local ok, code, headers, status = copas_http.request{
            url = url,
            method = "POST",
            headers =  {
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = string.len(buffer),
            },
            source = ltn12.source.string(buffer),   -- source data to send from string buffer
            sink = ltn12.sink.table(recv_body), -- sink received data to table recv_body
            redirect = true,    -- follow redirection silently
            proxy = self.opts.proxy,    -- configure proxy
            create = function(req)
                local sock = create_cb(req)

                -- keep reference to socket to close it when polling transport
                -- is closed
                self.send_sock = sock

                return sock
            end,
        }

        self.send_sock = nil

        -- transport might have been closed while request was being performed.
        -- Before processing anything, check if transport is still opened. If
        -- not, break
        if not self.opened then
            break
        end

        recv_body = table.concat(recv_body)
        handle_http_response(self, ok, code, recv_body)
    end

    self.thread_send = nil
end

--- Queue a packet to send to the socket.io server.
-- @param self instance
-- @param pkt Already-encoded packet.
function M.send(self, pkt)
    table.insert(self.buffer, "\x00")

    -- encode packet length
    -- The packet length is encoded in base 10 with digits being byte 0 to 9.
    -- For example, length 42 will be encoded "\x04\x02".
    local l = tostring(string.len(pkt))
    for i = 1, string.len(l) do
        -- 48 == string.byte('0')
        table.insert(self.buffer, string.char(string.byte(string.sub(l, i)) - 48))
    end

    table.insert(self.buffer, "\xff")
    table.insert(self.buffer, pkt)

    -- start send thread if not started yet
    if self.thread_send == nil then
        self.thread_send = copas.addthread(thread_send, self)
    end
end

--- Open the transport. Start long-polling the server.
-- @param self instance
function M.open(self)
    assert(not self.opened, "already polling")
    self.opened = true

    self.thread_recv = copas.addthread(thread_recv, self)
end

--- Close the transport. Stop every communication with the server.
-- @param self instance
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
    self.buffer = {}
    self.backoff:reset()
end

--- Set a current session.
-- @param self instance
-- @param session Session information.
-- @param session.session_id Session ID defined by the server.
-- @param session.ping_timeout Timeout after a unanswered PING, in second,
-- defined by the server.
-- @param session.ping_interval Interval between every PINGs, in second, defined
-- by the server.
-- @param session.upgrades Table of transport upgrade proposed by the server.
function M.set_session(self, session)
    self.opts.session_id = session.session_id or session.sid
    self.opts.ping_timeout = session.ping_timeout or session.pingTimeout
    self.opts.ping_interval = session.ping_interval or session.pingInterval
    self.opts.upgrades = session.upgrades
end

--- Clear/Forget the current session.
-- @param self instance
function M.clear_session(self)
    self.opts.session_id = nil
    self.opts.ping_timeout = nil
    self.opts.ping_interval = nil
    self.opts.upgrades = nil
end

--- Class constructor.
-- @param opts Options given to @{socketio.manager}
-- @param opts.on_packet Function called when a new packet is received. First
-- and unique argument is the still encoded packet. Function will run in its own
-- copas thread.
-- @param opts.on_error Function called when an error occurs on the transport
-- level. Function will run in its own copas thread.
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

