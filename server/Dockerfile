FROM dart:stable

WORKDIR /app

COPY pubspec.yaml ./
COPY pubspec.lock ./
RUN dart pub get

COPY . .

ENV PORT=10000
EXPOSE 10000

CMD ["dart", "run", "bin/server.dart"]
