FROM rustlang/rust@sha256:b62c21120fa9ef720e76f75fcdb53926ddace89feb2e21a1b5944554499aee86

RUN apt-get update

RUN apt-get install musl-tools -y

RUN rustup target add x86_64-unknown-linux-musl

WORKDIR /usr/src/rust-web-demo

COPY Cargo.toml Cargo.toml

RUN mkdir src/

RUN echo "extern crate rocket;\nfn main() {println!(\"if you see this, the build broke\")}" > src/main.rs

RUN RUSTFLAGS=-Clinker=musl-gcc cargo build --release --target=x86_64-unknown-linux-musl

RUN rm -rf src/

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo*

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/deps/rust_web_demo*

RUN rm -f /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo.d

COPY src/* src/

RUN RUSTFLAGS=-Clinker=musl-gcc cargo build --release --target=x86_64-unknown-linux-musl

FROM alpine:latest

RUN apk add --no-cache libpq

WORKDIR /root/

COPY --from=0 /usr/src/rust-web-demo/target/x86_64-unknown-linux-musl/release/rust-web-demo .

CMD ["./rust-web-demo"]
