# Reproto

Given an input golang binary, this experimental tool can (partially) reconstruct the protobuf definitions based on certain meta information present 
in the binary itself. Proto's RPC methods are supported as well, but their parameters are unknown (let me know if you have a feasible idea
to extract them!). Digging up message definitions works much better (but with limitations, still).

## How to use?

Invoke it simply specifying the path to the golang binary and the desired destination dir.

```
# ./reproto.pl
Usage: ./reproto.pl /path/to/go.bin /path/to/destdir
```

## Dependencies

- gdb

- objdump

## Examples

Consider [this](https://raw.githubusercontent.com/grpc/grpc-go/master/examples/features/proto/echo/echo.proto) proto definition, which is part of the official
grpc-go codebase:

```

syntax = "proto3";

option go_package = "google.golang.org/grpc/examples/features/proto/echo";

package grpc.examples.echo;

// EchoRequest is the request for echo.
message EchoRequest {
  string message = 1;
}

// EchoResponse is the response for echo.
message EchoResponse {
  string message = 1;
}

// Echo is the echo service.
service Echo {
  // UnaryEcho is unary echo.
  rpc UnaryEcho(EchoRequest) returns (EchoResponse) {}
  // ServerStreamingEcho is server side streaming.
  rpc ServerStreamingEcho(EchoRequest) returns (stream EchoResponse) {}
  // ClientStreamingEcho is client side streaming.
  rpc ClientStreamingEcho(stream EchoRequest) returns (EchoResponse) {}
  // BidirectionalStreamingEcho is bidi streaming.
  rpc BidirectionalStreamingEcho(stream EchoRequest) returns (stream EchoResponse) {}
}
```

Using it in a simple client/server tool like [this](https://github.com/salrashid123/grpc_alts), the reconstruced proto will look:

```
root@f4297f8cd9e5:/data/reproto# ./reproto.pl client ../reproto-destdir/
root@f4297f8cd9e5:/data/reproto# cat ../reproto-destdir/echo.proto

// original: /root/go/pkg/mod/google.golang.org/grpc/examples@v0.0.0-20200605192255-479df5ea818c/features/proto/echo/echo.pb.go

syntax = "proto3";

option go_package = "google.golang.org/grpc/examples/features/proto/echo";

package grpc.examples.echo;

message EchoRequest {
 // TODO: Message has multiple definitions!
 string message = 8;
 string message = 1;
 string message = 2;

}

message EchoResponse {
 // TODO: Message has multiple definitions!
 string message = 8;
 string message = 1;
 string message = 2;

}

service Echo {
   rpc BidirectionalStreamingEcho(TODO) returns (TODO) {}
   rpc ClientStreamingEcho(TODO) returns (TODO) {}
   rpc ServerStreamingEcho(TODO) returns (TODO) {}
   rpc UnaryEcho(TODO) returns (TODO) {}
}
```

Another example highlighting some strength and limitations. Original:

```
syntax = "proto3";

option go_package = "github.com/irsl/sth";

message Bar {
        string m1 = 1;
        int32 m2 = 2;
        fixed32 m3 = 3;
}

message Foo {
        Bar xxx = 1;
}
```

Reconstructed:

```
// original: /root/go/src/github.com/irsl/sth/test-nested.pb.go

syntax = "proto3";

option go_package = "github.com/irsl/sth";


message Foo {
        TODO_another_proto_msg xxx = 1;

}

message Bar {
        string m1 = 1;
        int32 m2 = 2;
        fixed32 m3 = 3;

}
```


Oneof constructs are supported (at some level at least). Original:

```
syntax = "proto3";

option go_package = "github.com/irsl/sth";

message SampleMessage {
  oneof test_oneof {
    string name = 4;
    int32 foo = 9;
  }
}
```


Reconstructed:

```
// original: /root/go/src/github.com/irsl/sth/test-oneof.pb.go

syntax = "proto3";

option go_package = "github.com/irsl/sth";


message SampleMessage {
   oneof test_oneof {
        int32 foo = 9;
        string name = 4;
   }

}
```


## Limitations

- Identifying string fields works on x86_64 only (in case of another golang binaries, the type of the field is identified as bytes)
- Proto messages fields referencing another proto messages are identified as bytes
- RPC method parameters and return types are unknown
- Probably many more
