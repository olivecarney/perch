FROM rust:1.99-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY public ./public
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN groupadd --gid 10001 perch && useradd --uid 10001 --gid perch --no-create-home perch && mkdir /data && chown perch:perch /data
COPY --from=build /build/target/release/perch /usr/local/bin/perch
USER 10001:10001
ENV HOST=0.0.0.0 PORT=3000 PERCH_DATA=/data/apps.json
EXPOSE 3000
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/perch"]
