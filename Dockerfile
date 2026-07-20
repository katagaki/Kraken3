FROM swift:6.3.3-bookworm AS build
WORKDIR /app
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

FROM debian:bookworm-20260713-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium ca-certificates \
        fonts-liberation fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/.build/release/Kraken /usr/local/bin/kraken
COPY --from=build /app/.build/release/KrakenReaper /usr/local/bin/kraken-reaper
COPY chromium-policy.json /etc/chromium/policies/managed/kraken.json
RUN useradd --create-home kraken && mkdir -p /data/sessions && chown -R kraken /data
USER kraken
EXPOSE 8080
CMD ["kraken"]
