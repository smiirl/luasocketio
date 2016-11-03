local io = require("socketio")

io.log.set_level(io.log.INFO)

io = io("http://localhost:3000/hello")

io:on("hello", function()
    io:emit("world", {1, 2, 3})
end)

io.manager:open()

require("copas").loop()

