import * as ReactNamespace from "react";
import { generateEventId, getClient, getCurrentScope, withScope } from "./index.ts";
import type { Scope } from "./scope.ts";

export interface FallbackProps {
  error: unknown;
  componentStack: string | null;
  eventId: string | null;
  resetError: () => void;
}

export type FallbackRender = (props: FallbackProps) => unknown;

export interface ErrorBoundaryProps {
  children?: unknown;
  fallback?: unknown;
  onError?: (error: unknown, componentStack: string, eventId: string) => void;
  onReset?: (error: unknown, componentStack: string | null, eventId: string | null) => void;
  beforeCapture?: (scope: Scope, error: unknown, componentStack: string) => void;
}

export interface ErrorBoundaryState {
  hasError: boolean;
  error: unknown;
  componentStack: string | null;
  eventId: string | null;
}

interface ReactComponentInstance {
  props: ErrorBoundaryProps;
  state: ErrorBoundaryState;
  setState: (partial: Partial<ErrorBoundaryState>) => void;
}

interface ReactComponentConstructor {
  new (props: ErrorBoundaryProps): ReactComponentInstance;
  prototype: Record<string, unknown>;
}

interface ReactModuleLike {
  Component: ReactComponentConstructor;
  createElement: (type: unknown, props?: Record<string, unknown> | null, ...children: unknown[]) => unknown;
  isValidElement: (object: unknown) => boolean;
  default?: ReactModuleLike;
}

const rawReact = ReactNamespace as unknown as ReactModuleLike;
const ReactApi: ReactModuleLike =
  rawReact && typeof rawReact.Component === "function"
    ? rawReact
    : rawReact && rawReact.default && typeof rawReact.default.Component === "function"
      ? rawReact.default
      : rawReact;

const BaseComponent = ReactApi.Component;

export class ErrorBoundary extends BaseComponent {
  declare state: ErrorBoundaryState;
  declare props: ErrorBoundaryProps;
  declare setState: (partial: Partial<ErrorBoundaryState>) => void;
  declare resetError: () => void;

  static getDerivedStateFromError(error: unknown): Partial<ErrorBoundaryState> {
    return {
      hasError: true,
      error: error
    };
  }

  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      componentStack: null,
      eventId: null
    };
    this.resetError = this.resetError.bind(this);
  }

  componentDidCatch(error: unknown, errorInfo?: { componentStack?: string | null }): void {
    const componentStack =
      errorInfo && typeof errorInfo.componentStack === "string" ? errorInfo.componentStack : "";

    const eventId = withScope((scope) => {
      scope.setContext("react", { componentStack: componentStack });
      if (this.props && typeof this.props.beforeCapture === "function") {
        this.props.beforeCapture(scope, error, componentStack);
      }

      const client = getClient();
      if (!client) {
        return generateEventId();
      }

      return client.captureExceptionWithMeta(error, getCurrentScope(), undefined, {
        handled: false,
        mechanismType: "react.error_boundary"
      });
    });

    this.setState({
      hasError: true,
      error: error,
      componentStack: componentStack,
      eventId: eventId
    });

    if (this.props && typeof this.props.onError === "function") {
      this.props.onError(error, componentStack, eventId);
    }
  }

  resetError(): void {
    const prevError = this.state.error;
    const prevComponentStack = this.state.componentStack;
    const prevEventId = this.state.eventId;

    if (this.props && typeof this.props.onReset === "function") {
      this.props.onReset(prevError, prevComponentStack, prevEventId);
    }

    this.setState({
      hasError: false,
      error: null,
      componentStack: null,
      eventId: null
    });
  }

  render(): unknown {
    if (this.state.hasError) {
      const fallback = this.props ? this.props.fallback : undefined;
      const fallbackProps: FallbackProps = {
        error: this.state.error,
        componentStack: this.state.componentStack,
        eventId: this.state.eventId,
        resetError: this.resetError
      };

      if (ReactApi.isValidElement(fallback)) {
        return fallback;
      }

      if (typeof fallback === "function") {
        return ReactApi.createElement(fallback, fallbackProps as unknown as Record<string, unknown>);
      }

      return null;
    }

    return this.props && this.props.children !== undefined ? this.props.children : null;
  }
}

export interface NamedComponentLike<P = Record<string, unknown>> {
  (props: P): unknown;
  displayName?: string;
  name?: string;
}

export function withErrorBoundary<P = Record<string, unknown>>(
  WrappedComponent: NamedComponentLike<P> | (new (props: P) => unknown),
  errorBoundaryOptions: ErrorBoundaryProps = {}
): NamedComponentLike<P> {
  const meta = WrappedComponent as { displayName?: string; name?: string };
  const rawName = (meta && (meta.displayName || meta.name)) || "Component";
  const componentName = rawName.trim() || "Component";

  function WrappedWithErrorBoundary(props: P): unknown {
    return ReactApi.createElement(
      ErrorBoundary,
      errorBoundaryOptions as unknown as Record<string, unknown>,
      ReactApi.createElement(WrappedComponent, props as unknown as Record<string, unknown>)
    );
  }

  WrappedWithErrorBoundary.displayName = `errorBoundary(${componentName})`;
  return WrappedWithErrorBoundary;
}

const SentraceReact = {
  ErrorBoundary,
  withErrorBoundary
};

export default SentraceReact;
