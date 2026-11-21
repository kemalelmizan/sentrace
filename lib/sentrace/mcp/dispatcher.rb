module Sentrace
  module Mcp
    class Dispatcher
      DEFAULT_REMOTE_CLIENT = Object.new.freeze
      private_constant :DEFAULT_REMOTE_CLIENT

      def initialize(config: Sentrace.configuration, remote_client: DEFAULT_REMOTE_CLIENT, router: nil, read_only: false, allowed_project_id: nil)
        @config = config
        resolved_client = remote_client.equal?(DEFAULT_REMOTE_CLIENT) ? RemoteHttpClient.new : remote_client
        @remote_client = resolved_client
        @router = router || EnvironmentRouter.new(
          config: @config,
          remote_client: @remote_client,
          allowed_project_id: allowed_project_id
        )
        @read_only = read_only
      end

      def list_environments
        @router.list_environments
      end

      def dispatch(operation, environment: nil, **kwargs)
        op_sym = operation.to_sym
        if @read_only && EnvironmentRouter::MUTATION_OPERATIONS.include?(op_sym)
          raise McpForbiddenError, "Token is read-only and cannot invoke '#{op_sym}'"
        end

        @router.route(op_sym, environment: environment, **kwargs)
      end
    end
  end
end
