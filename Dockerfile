ARG BUILDER_IMAGE="hexpm/elixir:1.18-erlang-27.3-debian-bookworm-20260316-slim"
ARG RUNNER_IMAGE="debian:bookworm-20260316-slim"

# Build stage
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git npm curl ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Rust, to build wallop_core's drand BLS NIF (apps/wallop_core/native/drand_bls)
# from source. rustup-init is pinned by version and checksum; the toolchain
# is pinned to the one in the crate's rust-toolchain.toml.
ARG RUSTUP_VERSION=1.28.2
ARG RUST_TOOLCHAIN=1.94.1
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) triple=x86_64-unknown-linux-gnu; \
             sha=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c ;; \
      arm64) triple=aarch64-unknown-linux-gnu; \
             sha=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}/rustup-init"; \
    echo "${sha}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN}"; \
    rm /tmp/rustup-init; \
    rustc --version; cargo --version

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

# Fetch the drand BLS NIF's crates in their own layer, from the committed
# lock file, so a code change doesn't download them again.
COPY apps/wallop_core/native/drand_bls/Cargo.toml \
     apps/wallop_core/native/drand_bls/Cargo.lock \
     apps/wallop_core/native/drand_bls/rust-toolchain.toml \
     apps/wallop_core/native/drand_bls/
RUN cd apps/wallop_core/native/drand_bls && cargo fetch --locked

# Copy config and app code
COPY config config
COPY apps apps
COPY rel rel

# Build assets
RUN cd apps/wallop_web && mix tailwind.install --no-assets && mix esbuild.install --no-assets || true
RUN mix tailwind wallop --minify
RUN mix esbuild wallop --minify

# (Static files like logo + fonts + images are already in place from
# the earlier `COPY apps apps` step. The previous `COPY
# apps/wallop_web/priv/static apps/wallop_web/priv/static` here was
# destructive — it ran AFTER the tailwind/esbuild rebuild and replaced
# the freshly-built minified app.css / app.js with the older versions
# committed to git, so production was always serving the stale
# committed bundle. Removed.)

# Compile and build release
RUN mix compile
RUN mix phx.digest
RUN mix release wallop

FROM ${RUNNER_IMAGE} AS inshape

ARG INSHAPE_VERSION=1.0.0
ARG INSHAPE_SHA256_AMD64=fdb1b2d1955bb75d720833d6b3862a7398eea56e9c5ec4d6b467defddfca4008
ARG INSHAPE_SHA256_ARM64=0696f380a19cd24e7b21ab7c21a80ebad753c6a62ca35d4f29984593569c2553
RUN set -eux; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    case "$(dpkg --print-architecture)" in \
      amd64) target=x86_64; sha=${INSHAPE_SHA256_AMD64} ;; \
      arm64) target=aarch64; sha=${INSHAPE_SHA256_ARM64} ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -sSfL -o /tmp/inshape \
      "https://github.com/electric-lump-software/inshape/releases/download/v${INSHAPE_VERSION}/inshape-${target}-unknown-linux-musl"; \
    echo "${sha}  /tmp/inshape" | sha256sum -c -; \
    install -m 0755 /tmp/inshape /usr/local/bin/inshape; \
    inshape --version

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

COPY --from=inshape /usr/local/bin/inshape /usr/local/bin/inshape
COPY rel/secrets.allow /etc/wallop/secrets.allow

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/wallop ./

USER nobody

CMD ["/app/bin/migrate_and_start"]
