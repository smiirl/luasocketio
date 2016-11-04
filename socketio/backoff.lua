--- Exponential backoff
-- Used internally by transports when one socket.io's server does not respond to
-- calculate the duration to wait before trying back.
-- Inspired from https://www.npmjs.com/package/backo2
-- @classmod socketio.backoff

local C = {}    -- Module/Class table
local M = {}    -- Class' methods

--- Returns duration to wait and consider a new attempt is imminent.
-- Calling this method increases the count of attempt which will make the
-- function return a new value the next time it is called.
-- @param self Instance
-- @return Duration to wait in second
function M.duration(self)
    local ms = self.min * math.pow(self.factor, self.attempts)
    self.attempts = self.attempts + 1

    if self.jitter > 0 then
        local rand = math.random() * 2 - 1
        ms = ms + rand * self.jitter * ms
    end

    return math.min(ms, self.max)
end

--- Reset the attempt counter, meaning server did respond.
-- @param self Instance
function M.reset(self)
    self.attempts = 0
end

--- Class constructor
-- @param opts Table of options
-- @param opts.hello Table of options
-- @param opts.min Minimum duration in second (default: 0.1)
-- @param opts.max Maximum duration in second (defalut: 1)
-- @param opts.factor Multiplication factor to duration after each attempt
-- (default: 2)
-- @param opts.jitter Duration jitter (default: 0)
-- @return instance
function C.new(opts)
    local self = {
        min = opts.min or 0.1,
        max = opts.max or 1,
        factor = opts.factor or 2,
        jitter = opts.jitter or 0,
        attempts = 0
    }

    assert(
        0 <= self.jitter and self.jitter <= 1,
        "invalid argument 'jitter': requires to be between 0 and 1 or nil"
    )

    return setmetatable(self, {
        __index = M
    })
end

-- @table backoff_opts

return C

