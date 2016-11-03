local C = {}
local M = {}

function M.duration(self)
    local ms = self.min * math.pow(self.factor, self.attempts)
    self.attempts = self.attempts + 1

    if self.jitter > 0 then
        local rand = math.random() * 2 - 1
        ms = ms + rand * self.jitter * ms
    end

    return math.min(ms, self.max)
end

function M.reset(self)
    self.attempts = 0
end

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

return C

