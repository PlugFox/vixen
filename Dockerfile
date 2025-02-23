FROM dart:stable AS build

WORKDIR /app

ARG PUB_CACHE="/var/tmp/.pub_cache"

COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart pub get --offline \
    && dart run build_runner build --delete-conflicting-outputs \
    && dart compile exe bin/vixen.dart -o vixen.run

FROM ubuntu:noble AS runtime

WORKDIR /app

COPY --from=build /app/vixen.run /app/
COPY assets/ /app/assets/

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libssl-dev sqlite3 libsqlite3-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

EXPOSE 8080
CMD ["/app/vixen.run"]
