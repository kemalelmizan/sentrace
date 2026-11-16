# sentrace

Official frontend browser error capturing SDK for [**Sentrace**](https://github.com/kemalelmizan/sentrace) — self-hosted, PostgreSQL-backed Sentry-compatible error tracking for Ruby on Rails with a federated Model Context Protocol (MCP) interface.

> **Early Preview (`0.0.1`)**: Version `0.0.1` reserves the `sentrace` package name with zero-dependency ESM, CommonJS, and TypeScript definitions (`init`, `captureException`, `captureMessage`, `addBreadcrumb`). Full browser error, unhandled rejection, breadcrumb, and Rails Turbo/Hotwire integration is under active development.

## Installation

```bash
npm install sentrace
```

Pair with the [`sentrace` RubyGem](https://rubygems.org/gems/sentrace) in your Ruby on Rails host application:

```bash
bundle add sentrace
bin/rails generate sentrace:install
```

## Usage

```ts
import { init, captureException } from "sentrace";

init({
  dsn: "https://<public_key>@example.com/sentrace/1",
  environment: "production",
  release: "2026.11.0"
});

try {
  // application logic
} catch (error) {
  captureException(error);
}
```

## License

Released under the [MIT License](LICENSE.txt).
