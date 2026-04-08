ARG BUILDER_IMAGE="hexpm/elixir:1.18-erlang-27.3-debian-bookworm-20260316-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260316-slim"

# Build stage
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git npm \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
COPY apps/wallop_core/mix.exs apps/wallop_core/
COPY apps/wallop_web/mix.exs apps/wallop_web/
RUN mix deps.get --only prod
RUN mix deps.compile

# Install npm dependencies (daisyUI, anime.js)
COPY apps/wallop_web/assets/package.json apps/wallop_web/assets/package-lock.json apps/wallop_web/assets/
RUN cd apps/wallop_web/assets && npm ci

# Copy config and app code
COPY config config
COPY apps apps
COPY rel rel

# Build assets
RUN cd apps/wallop_web && mix tailwind.install --no-assets && mix esbuild.install --no-assets || true
RUN mix tailwind wallop --minify
RUN mix esbuild wallop --minify

# Copy static assets (logo, fonts)
COPY apps/wallop_web/priv/static apps/wallop_web/priv/static

# Compile and build release
RUN mix compile
RUN mix phx.digest
RUN mix release wallop

# Runtime stage
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates qpdf \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/wallop ./

USER nobody

CMD ["/app/bin/migrate_and_start"]
