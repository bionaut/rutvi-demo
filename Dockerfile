# Pin the official multi-arch Elixir 1.18.3 / OTP 27 image. OTP 28 fails to
# compile the vendored Synaptic prompt-security module's Regex references.
FROM elixir:1.18.3-slim@sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates git libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

# Synaptic is vendored in this repository; the build must not depend on a developer checkout.
COPY mix.exs mix.lock ./
COPY vendor/synaptic ./vendor/synaptic
RUN mix local.hex --force \
    && mix local.rebar --force \
    && mix deps.get --only prod

COPY . .
RUN mix release

FROM elixir:1.18.3-slim@sha256:fc227cb4b0c568a1f7cf6a8e40269185248cd29204c0d4e95cdefe31f5d1a873 AS app
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 rutvi \
    && useradd --uid 10001 --gid rutvi --no-create-home --shell /usr/sbin/nologin rutvi \
    && mkdir -p /data \
    && chown 10001:10001 /data

WORKDIR /app
COPY --from=build --chown=10001:10001 /app/_build/prod/rel/rutvi_exercise ./
COPY --chown=10001:10001 scripts/container-entrypoint.sh /usr/local/bin/rutvi-entrypoint
RUN chmod 0755 /usr/local/bin/rutvi-entrypoint
USER 10001:10001

ENV HTTP_PORT=4000 RUTVI_DATABASE=/data/rutvi.sqlite3 RUTVI_MODEL_PROVIDER=deterministic
EXPOSE 4000
VOLUME ["/data"]
CMD ["/app/bin/rutvi_exercise", "start"]
ENTRYPOINT ["/usr/local/bin/rutvi-entrypoint"]
