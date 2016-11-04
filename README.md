# `luasocketio`

[socket.io](http://socket.io/) client implemented in pure
[Lua](https://www.lua.org/).

Depends on

- Lua 5.3
- [`copas`](https://luarocks.org/modules/tieske/copas)
- [`lua-cjson`](https://luarocks.org/modules/luarocks/lua-cjson)
- [`luasec`](https://luarocks.org/modules/brunoos/luasec) (for SSL support)
- [`luasocket`](https://luarocks.org/modules/luarocks/luasocket)

## Documentation

Code documentation can be generated thanks to
[`LDoc`](http://stevedonovan.github.io/ldoc/).

```bash
$ ldoc socketio/
output written to /luasocketio/doc
$ open doc/index.html
```

## About the current transports

For now, it only implements the `polling` protocol, which long-polls the
socket.io server to receive new events. The common protocol `websocket` should
be the next step of the development of this library.

