package = "luasocketio"
version = "scm-1"

source = {
    url = "git://github.com/smiirl/luasocketio.git",
}

description = {
    summary = "socket.io client implemented in pure Lua",
    homepage = "https://github.com/smiirl/luasocketio",
}

dependencies = {
    "lua >= 5.3",
    "copas",
    "lua-cjson",
    "luasocket",
}

build = {
    type = 'non',
    install = {
        lua = {
            ["socketio"] = "socketio/init.lua",
            ["socketio.backoff"] = "socketio/backoff.lua",
            ["socketio.init"] = "socketio/init.lua",
            ["socketio.log"] = "socketio/log.lua",
            ["socketio.manager"] = "socketio/manager.lua",
            ["socketio.packet"] = "socketio/packet.lua",
            ["socketio.polling"] = "socketio/polling.lua",
            ["socketio.socket"] = "socketio/socket.lua",
            ["socketio.url"] = "socketio/url.lua",
        }
    }
}
