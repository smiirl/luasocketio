var app = require('express')();
var http = require('http').Server(app);
var io = require('socket.io')(http).of("/hello");

app.get('/', function(req, res){
  res.sendFile(__dirname + '/index.html');
});

io.on('connection', function (socket) {
  socket.emit('hello', 'hi', function() {
    console.log("received");
  });

    socket.on('world', function(arg) {
      console.log("world", arg);
    });
});



http.listen(3000, function(){
  console.log('listening on *:3000');
});

