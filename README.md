# Vixen

## How to run

Get dependencies:

```bash
dart pub get
```

Code generation:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Create environment file and fill it with your credentials:

```bash
cp .env.example .env
```

Run the program:

```bash
dart run bin/vixen.dart --help
```

## How to build

```bash
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart compile exe bin/vixen.dart -o vixen.run
```
