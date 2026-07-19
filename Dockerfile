FROM swift:6.3-bookworm AS build
WORKDIR /app
COPY Package.swift ./
COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium ca-certificates \
        fonts-liberation fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/.build/release/Kraken /usr/local/bin/kraken
RUN useradd --create-home kraken && mkdir /downloads && chown kraken /downloads
USER kraken
ENV KRAKEN_DOWNLOADS=/downloads
EXPOSE 8080 8081
CMD ["kraken"]
